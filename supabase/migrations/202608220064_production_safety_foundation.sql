-- Production safety foundation: durable abuse reports, inexpensive per-account
-- write throttles, and an APNs registration/preferences substrate. This is
-- additive: existing client RPC signatures and read policies are unchanged.

do $$ begin
  create type public.abuse_report_target_kind as enum (
    'profile', 'review', 'music_list', 'review_comment', 'music_list_comment'
  );
exception when duplicate_object then null;
end $$;

do $$ begin
  create type public.abuse_report_reason as enum (
    'spam', 'harassment', 'hate', 'sexual_content', 'violence',
    'impersonation', 'self_harm', 'copyright', 'other'
  );
exception when duplicate_object then null;
end $$;

do $$ begin
  create type public.abuse_report_status as enum (
    'open', 'reviewing', 'actioned', 'dismissed'
  );
exception when duplicate_object then null;
end $$;

create table public.abuse_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  target_kind public.abuse_report_target_kind not null,
  target_id uuid not null,
  target_owner_id uuid not null references public.profiles(id) on delete restrict,
  reason public.abuse_report_reason not null,
  details text not null default '' check (char_length(details) <= 1000),
  target_snapshot jsonb not null default '{}'::jsonb,
  status public.abuse_report_status not null default 'open',
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references public.profiles(id) on delete set null,
  resolution_note text not null default '' check (char_length(resolution_note) <= 2000),
  check (reporter_id <> target_owner_id),
  check ((status in ('open', 'reviewing') and reviewed_at is null)
    or (status in ('actioned', 'dismissed') and reviewed_at is not null))
);

create unique index abuse_reports_one_open_target_idx
  on public.abuse_reports(reporter_id, target_kind, target_id)
  where status in ('open', 'reviewing');
create index abuse_reports_moderation_queue_idx
  on public.abuse_reports(status, created_at, id);
create index abuse_reports_target_owner_idx
  on public.abuse_reports(target_owner_id, created_at desc);

alter table public.abuse_reports enable row level security;
create policy "reporters view their submitted reports"
on public.abuse_reports for select to authenticated
using (reporter_id = auth.uid());
revoke insert, update, delete on public.abuse_reports from authenticated;
grant select on public.abuse_reports to authenticated;

-- Windowed counters avoid retaining request logs or personal request content.
-- Callers receive SQLSTATE 42900 and a stable detail token on exhaustion.
create table public.account_rate_limits (
  actor_id uuid not null references public.profiles(id) on delete cascade,
  action text not null check (action ~ '^[a-z0-9_]{1,64}$'),
  window_started_at timestamptz not null,
  request_count integer not null check (request_count > 0),
  primary key (actor_id, action, window_started_at)
);
create index account_rate_limits_cleanup_idx
  on public.account_rate_limits(window_started_at);
alter table public.account_rate_limits enable row level security;
revoke all on public.account_rate_limits from authenticated, anon;

create function public.consume_account_rate_limit(
  p_action text,
  p_limit integer,
  p_window interval
)
returns integer
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_window timestamptz;
  v_count integer;
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if p_action is null or p_action !~ '^[a-z0-9_]{1,64}$'
     or p_limit is null or p_limit < 1 or p_limit > 10000
     or p_window is null or p_window < interval '1 second' or p_window > interval '1 day' then
    raise exception 'invalid rate limit configuration' using errcode = '22023';
  end if;

  -- Epoch alignment gives every node the same bucket without per-request rows.
  v_window := to_timestamp(
    floor(extract(epoch from clock_timestamp()) / extract(epoch from p_window))
    * extract(epoch from p_window)
  );
  insert into public.account_rate_limits(actor_id, action, window_started_at, request_count)
  values (v_actor_id, p_action, v_window, 1)
  on conflict (actor_id, action, window_started_at) do update
    set request_count = public.account_rate_limits.request_count + 1
  returning request_count into v_count;

  if v_count > p_limit then
    raise exception 'too many requests'
      using errcode = '42900', detail = 'harmony_rate_limit_exceeded';
  end if;
  return v_count;
end;
$$;
revoke all on function public.consume_account_rate_limit(text, integer, interval) from public;

create function public.enforce_high_risk_write_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then return new; end if;
  case tg_table_name
    when 'social_follows' then perform public.consume_account_rate_limit('follow_write', 40, interval '1 hour');
    when 'review_comments' then perform public.consume_account_rate_limit('review_comment', 30, interval '10 minutes');
    when 'music_list_comments' then perform public.consume_account_rate_limit('list_comment', 30, interval '10 minutes');
    when 'music_reviews' then perform public.consume_account_rate_limit('review_publish', 12, interval '1 hour');
    when 'music_lists' then perform public.consume_account_rate_limit('list_create', 12, interval '1 hour');
    when 'sessions' then perform public.consume_account_rate_limit('session_create', 20, interval '1 hour');
    when 'session_members' then perform public.consume_account_rate_limit('session_join', 40, interval '1 hour');
  end case;
  return new;
end;
$$;
revoke all on function public.enforce_high_risk_write_rate_limit() from public;

create trigger social_follows_rate_limit before insert or update on public.social_follows
for each row execute function public.enforce_high_risk_write_rate_limit();
create trigger review_comments_rate_limit before insert on public.review_comments
for each row execute function public.enforce_high_risk_write_rate_limit();
create trigger music_list_comments_rate_limit before insert on public.music_list_comments
for each row execute function public.enforce_high_risk_write_rate_limit();
create trigger music_reviews_rate_limit before insert on public.music_reviews
for each row execute function public.enforce_high_risk_write_rate_limit();
create trigger music_lists_rate_limit before insert on public.music_lists
for each row execute function public.enforce_high_risk_write_rate_limit();
create trigger sessions_rate_limit before insert on public.sessions
for each row execute function public.enforce_high_risk_write_rate_limit();
create trigger session_members_rate_limit before insert on public.session_members
for each row execute function public.enforce_high_risk_write_rate_limit();

create function public.submit_abuse_report(
  p_target_kind public.abuse_report_target_kind,
  p_target_id uuid,
  p_reason public.abuse_report_reason,
  p_details text default ''
)
returns public.abuse_reports
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_owner_id uuid;
  v_snapshot jsonb;
  v_report public.abuse_reports%rowtype;
begin
  if v_actor_id is null then raise exception 'authentication required' using errcode = '28000'; end if;
  if p_target_id is null or p_reason is null then raise exception 'report target and reason are required' using errcode = '22004'; end if;
  if char_length(btrim(coalesce(p_details, ''))) > 1000 then raise exception 'report details must not exceed 1000 characters' using errcode = '22023'; end if;
  perform public.consume_account_rate_limit('abuse_report', 10, interval '1 hour');

  case p_target_kind
    when 'profile' then
      select id, jsonb_build_object('display_name', display_name, 'avatar_url', avatar_url)
      into v_owner_id, v_snapshot from public.profiles where id = p_target_id;
    when 'review' then
      select profile_id, jsonb_build_object('subject_kind', subject_kind, 'body', left(body, 4000), 'contains_spoilers', contains_spoilers)
      into v_owner_id, v_snapshot from public.music_reviews
      where id = p_target_id and deleted_at is null and public.can_view_music_review(id);
    when 'music_list' then
      select owner_id, jsonb_build_object('title', title, 'description', left(description, 5000))
      into v_owner_id, v_snapshot from public.music_lists
      where id = p_target_id and deleted_at is null and public.can_view_music_list(id);
    when 'review_comment' then
      select comment.author_id, jsonb_build_object('review_id', comment.review_id, 'body', left(comment.body, 2000))
      into v_owner_id, v_snapshot from public.review_comments comment
      where comment.id = p_target_id and comment.deleted_at is null and public.can_view_music_review(comment.review_id);
    when 'music_list_comment' then
      select comment.author_id, jsonb_build_object('list_id', comment.list_id, 'body', left(comment.body, 2000))
      into v_owner_id, v_snapshot from public.music_list_comments comment
      where comment.id = p_target_id and comment.deleted_at is null and public.can_view_music_list(comment.list_id);
  end case;
  if v_owner_id is null then raise exception 'report target unavailable' using errcode = 'P0002'; end if;
  if v_owner_id = v_actor_id then raise exception 'members cannot report their own content' using errcode = '22023'; end if;

  insert into public.abuse_reports(reporter_id, target_kind, target_id, target_owner_id, reason, details, target_snapshot)
  values (v_actor_id, p_target_kind, p_target_id, v_owner_id, p_reason, btrim(coalesce(p_details, '')), coalesce(v_snapshot, '{}'::jsonb))
  returning * into v_report;
  return v_report;
exception when unique_violation then
  raise exception 'an open report already exists for this target'
    using errcode = '23505', detail = 'duplicate_open_abuse_report';
end;
$$;
revoke all on function public.submit_abuse_report(public.abuse_report_target_kind, uuid, public.abuse_report_reason, text) from public;
grant execute on function public.submit_abuse_report(public.abuse_report_target_kind, uuid, public.abuse_report_reason, text) to authenticated;

create table public.notification_preferences (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  follows_enabled boolean not null default true,
  comments_enabled boolean not null default true,
  reactions_enabled boolean not null default true,
  sessions_enabled boolean not null default true,
  eavesdrop_enabled boolean not null default true,
  marketing_enabled boolean not null default false,
  updated_at timestamptz not null default now()
);
create trigger notification_preferences_updated_at before update on public.notification_preferences
for each row execute function public.set_updated_at();
alter table public.notification_preferences enable row level security;
create policy "members view notification preferences" on public.notification_preferences
for select to authenticated using (profile_id = auth.uid());
revoke insert, update, delete on public.notification_preferences from authenticated;
grant select on public.notification_preferences to authenticated;

create table public.notification_devices (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  apns_environment text not null check (apns_environment in ('sandbox', 'production')),
  device_token text not null check (device_token ~ '^[0-9A-Fa-f]{64,200}$'),
  app_bundle_id text not null check (char_length(app_bundle_id) between 3 and 255),
  device_label text not null default '' check (char_length(device_label) <= 120),
  enabled boolean not null default true,
  last_registered_at timestamptz not null default now(),
  last_delivery_at timestamptz,
  invalidated_at timestamptz,
  created_at timestamptz not null default now(),
  unique (apns_environment, app_bundle_id, device_token)
);
create index notification_devices_profile_idx on public.notification_devices(profile_id, enabled);
create index notification_devices_cleanup_idx on public.notification_devices(last_registered_at);
alter table public.notification_devices enable row level security;
revoke all on public.notification_devices from authenticated, anon;

create function public.set_my_notification_preferences(
  p_follows_enabled boolean,
  p_comments_enabled boolean,
  p_reactions_enabled boolean,
  p_sessions_enabled boolean,
  p_eavesdrop_enabled boolean,
  p_marketing_enabled boolean default false
)
returns public.notification_preferences
language plpgsql security definer set search_path = public as $$
declare v_result public.notification_preferences%rowtype;
begin
  if auth.uid() is null then raise exception 'authentication required' using errcode = '28000'; end if;
  if p_follows_enabled is null or p_comments_enabled is null or p_reactions_enabled is null
    or p_sessions_enabled is null or p_eavesdrop_enabled is null or p_marketing_enabled is null then
    raise exception 'all notification preferences are required' using errcode = '22004';
  end if;
  insert into public.notification_preferences values (
    auth.uid(), p_follows_enabled, p_comments_enabled, p_reactions_enabled,
    p_sessions_enabled, p_eavesdrop_enabled, p_marketing_enabled, now()
  ) on conflict (profile_id) do update set
    follows_enabled = excluded.follows_enabled, comments_enabled = excluded.comments_enabled,
    reactions_enabled = excluded.reactions_enabled, sessions_enabled = excluded.sessions_enabled,
    eavesdrop_enabled = excluded.eavesdrop_enabled, marketing_enabled = excluded.marketing_enabled
  returning * into v_result;
  return v_result;
end; $$;

create function public.register_notification_device(
  p_device_token text,
  p_apns_environment text,
  p_app_bundle_id text,
  p_device_label text default ''
)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'authentication required' using errcode = '28000'; end if;
  perform public.consume_account_rate_limit('device_registration', 20, interval '1 hour');
  if p_device_token is null or p_device_token !~ '^[0-9A-Fa-f]{64,200}$'
    or p_apns_environment not in ('sandbox', 'production')
    or char_length(btrim(coalesce(p_app_bundle_id, ''))) not between 3 and 255
    or char_length(btrim(coalesce(p_device_label, ''))) > 120 then
    raise exception 'invalid notification device registration' using errcode = '22023';
  end if;
  insert into public.notification_devices(profile_id, apns_environment, device_token, app_bundle_id, device_label)
  values (auth.uid(), p_apns_environment, lower(p_device_token), btrim(p_app_bundle_id), btrim(coalesce(p_device_label, '')))
  on conflict (apns_environment, app_bundle_id, device_token) do update set
    profile_id = auth.uid(), device_label = excluded.device_label, enabled = true,
    invalidated_at = null, last_registered_at = now()
  returning id into v_id;
  return v_id;
end; $$;

create function public.unregister_notification_device(p_device_id uuid)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'authentication required' using errcode = '28000'; end if;
  update public.notification_devices set enabled = false, invalidated_at = now()
  where id = p_device_id and profile_id = auth.uid();
  return found;
end; $$;

revoke all on function public.set_my_notification_preferences(boolean, boolean, boolean, boolean, boolean, boolean) from public;
revoke all on function public.register_notification_device(text, text, text, text) from public;
revoke all on function public.unregister_notification_device(uuid) from public;
grant execute on function public.set_my_notification_preferences(boolean, boolean, boolean, boolean, boolean, boolean) to authenticated;
grant execute on function public.register_notification_device(text, text, text, text) to authenticated;
grant execute on function public.unregister_notification_device(uuid) to authenticated;

-- Intentionally not scheduled here: hosted projects differ in pg_cron access.
-- A trusted daily job may invoke this bounded, service-role-only cleanup RPC.
create function public.perform_production_cleanup(p_batch_size integer default 1000)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_rate integer; v_devices integer; v_notifications integer; v_presence integer;
begin
  if auth.role() <> 'service_role' then raise exception 'service role required' using errcode = '42501'; end if;
  if p_batch_size is null or p_batch_size < 1 or p_batch_size > 10000 then raise exception 'cleanup batch size must be between 1 and 10000' using errcode = '22023'; end if;
  with doomed as (select ctid from public.account_rate_limits where window_started_at < now() - interval '2 days' limit p_batch_size)
    delete from public.account_rate_limits where ctid in (select ctid from doomed); get diagnostics v_rate = row_count;
  with doomed as (select id from public.notification_devices where (invalidated_at < now() - interval '7 days') or (last_registered_at < now() - interval '180 days') limit p_batch_size)
    delete from public.notification_devices where id in (select id from doomed); get diagnostics v_devices = row_count;
  with doomed as (select id from public.social_notifications where read_at < now() - interval '180 days' limit p_batch_size)
    delete from public.social_notifications where id in (select id from doomed); get diagnostics v_notifications = row_count;
  with doomed as (select profile_id from public.listening_presence where expires_at < now() - interval '1 day' limit p_batch_size)
    delete from public.listening_presence where profile_id in (select profile_id from doomed); get diagnostics v_presence = row_count;
  return jsonb_build_object('rate_limits', v_rate, 'devices', v_devices, 'notifications', v_notifications, 'presence', v_presence);
end; $$;
revoke all on function public.perform_production_cleanup(integer) from public, authenticated, anon;
grant execute on function public.perform_production_cleanup(integer) to service_role;

comment on table public.abuse_reports is 'Durable, immutable-at-submission moderation evidence. Only reporters can read their own rows; service_role operates the moderation queue.';
comment on table public.notification_devices is 'Private APNs tokens. App clients can only register/unregister through owner-bound RPCs; workers use service_role.';
