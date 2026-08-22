-- Durable APNs outbox. Tokens and delivery operations are service-role-only.
-- A worker claims a small leased batch, then completes or reschedules each row.

create table public.notification_deliveries (
  id uuid primary key default gen_random_uuid(),
  notification_id uuid not null references public.social_notifications(id) on delete cascade,
  device_id uuid not null references public.notification_devices(id) on delete cascade,
  status text not null default 'pending'
    check (status in ('pending', 'processing', 'retry', 'sent', 'dead')),
  attempt_count integer not null default 0 check (attempt_count between 0 and 12),
  next_attempt_at timestamptz not null default now(),
  claimed_at timestamptz,
  claim_token uuid,
  delivered_at timestamptz,
  last_http_status integer,
  last_error_code text check (
    last_error_code is null or last_error_code ~ '^[A-Za-z0-9_.-]{1,100}$'
  ),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (notification_id, device_id),
  check ((status = 'processing') = (claim_token is not null)),
  check ((status = 'processing') = (claimed_at is not null)),
  check ((status = 'sent') = (delivered_at is not null))
);

create index notification_deliveries_claim_idx
  on public.notification_deliveries(next_attempt_at, created_at, id)
  where status in ('pending', 'retry', 'processing');
create index notification_deliveries_device_idx
  on public.notification_deliveries(device_id, created_at desc);

alter table public.notification_deliveries enable row level security;
revoke all on public.notification_deliveries from public, authenticated, anon;

create trigger notification_deliveries_updated_at
before update on public.notification_deliveries
for each row execute function public.set_updated_at();

-- Materialize only currently eligible notification/device pairs. Preference
-- absence means the product defaults from migration 064 (all social kinds on).
create function public.claim_notification_deliveries(
  p_batch_size integer default 50,
  p_lease_seconds integer default 120
)
returns table (
  delivery_id uuid,
  claim_token uuid,
  device_token text,
  apns_environment text,
  app_bundle_id text,
  notification_kind text,
  actor_id uuid,
  actor_display_name text,
  review_id uuid,
  music_list_id uuid,
  listening_broadcast_id uuid,
  attempt_count integer
)
language plpgsql
volatile
security definer
set search_path = public
as $$
begin
  if auth.role() <> 'service_role' then
    raise exception 'service role required' using errcode = '42501';
  end if;
  if p_batch_size is null or p_batch_size < 1 or p_batch_size > 100
     or p_lease_seconds is null or p_lease_seconds < 30 or p_lease_seconds > 600 then
    raise exception 'invalid delivery claim bounds' using errcode = '22023';
  end if;

  insert into public.notification_deliveries(notification_id, device_id)
  select notification.id, device.id
  from public.social_notifications notification
  join public.notification_devices device
    on device.profile_id = notification.recipient_id
   and device.enabled and device.invalidated_at is null
  left join public.notification_preferences preference
    on preference.profile_id = notification.recipient_id
  where not public.social_accounts_are_blocked(notification.recipient_id, notification.actor_id)
    and notification.created_at >= now() - interval '7 days'
    and case
      when notification.kind in ('follow_request', 'follow_accepted')
        then coalesce(preference.follows_enabled, true)
      when notification.kind in ('review_comment', 'music_list_comment', 'listening_broadcast_comment')
        then coalesce(preference.comments_enabled, true)
      when notification.kind in ('review_reaction', 'music_list_like', 'listening_broadcast_reaction')
        then coalesce(preference.reactions_enabled, true)
      when notification.kind like 'session_%'
        then coalesce(preference.sessions_enabled, true)
      when notification.kind like 'eavesdrop_%'
        then coalesce(preference.eavesdrop_enabled, true)
      else false
    end
  on conflict (notification_id, device_id) do nothing;

  -- Re-check mutable consent and relationship state immediately before claim.
  -- Work made ineligible is terminal so re-enabling does not release stale push.
  update public.notification_deliveries delivery
  set status = 'dead', last_error_code = 'NoLongerEligible'
  from public.social_notifications notification, public.notification_devices device
  left join public.notification_preferences preference
    on preference.profile_id = device.profile_id
  where delivery.notification_id = notification.id
    and delivery.device_id = device.id
    and device.profile_id = notification.recipient_id
    and delivery.status in ('pending', 'retry')
    and (
      not device.enabled or device.invalidated_at is not null
      or public.social_accounts_are_blocked(notification.recipient_id, notification.actor_id)
      or not case
        when notification.kind in ('follow_request', 'follow_accepted') then coalesce(preference.follows_enabled, true)
        when notification.kind in ('review_comment', 'music_list_comment', 'listening_broadcast_comment') then coalesce(preference.comments_enabled, true)
        when notification.kind in ('review_reaction', 'music_list_like', 'listening_broadcast_reaction') then coalesce(preference.reactions_enabled, true)
        when notification.kind like 'session_%' then coalesce(preference.sessions_enabled, true)
        when notification.kind like 'eavesdrop_%' then coalesce(preference.eavesdrop_enabled, true)
        else false
      end
    );

  -- A crashed worker's expired processing lease becomes claimable again.
  return query
  with candidates as (
    select delivery.id
    from public.notification_deliveries delivery
    join public.notification_devices device on device.id = delivery.device_id
    where device.enabled and device.invalidated_at is null
      and (
        (delivery.status in ('pending', 'retry') and delivery.next_attempt_at <= now())
        or (delivery.status = 'processing'
          and delivery.claimed_at <= now() - make_interval(secs => p_lease_seconds))
      )
    order by delivery.next_attempt_at, delivery.created_at, delivery.id
    for update of delivery skip locked
    limit p_batch_size
  ), claimed as (
    update public.notification_deliveries delivery
    set status = 'processing', claimed_at = now(), claim_token = gen_random_uuid(),
        attempt_count = delivery.attempt_count + 1
    from candidates
    where delivery.id = candidates.id
    returning delivery.*
  )
  select claimed.id, claimed.claim_token, device.device_token,
    device.apns_environment, device.app_bundle_id, notification.kind,
    notification.actor_id,
    coalesce(nullif(btrim(actor.display_name), ''), 'Someone'),
    notification.review_id, notification.music_list_id,
    notification.listening_broadcast_id, claimed.attempt_count
  from claimed
  join public.notification_devices device on device.id = claimed.device_id
  join public.social_notifications notification on notification.id = claimed.notification_id
  join public.profiles actor on actor.id = notification.actor_id;
end;
$$;

create function public.complete_notification_delivery(
  p_delivery_id uuid,
  p_claim_token uuid,
  p_http_status integer
)
returns boolean
language plpgsql
volatile
security definer
set search_path = public
as $$
declare v_device_id uuid;
begin
  if auth.role() <> 'service_role' then raise exception 'service role required' using errcode = '42501'; end if;
  if p_delivery_id is null or p_claim_token is null or p_http_status not between 200 and 299 then
    raise exception 'invalid delivery completion' using errcode = '22023';
  end if;
  update public.notification_deliveries
  set status = 'sent', delivered_at = now(), last_http_status = p_http_status,
      last_error_code = null, claim_token = null, claimed_at = null
  where id = p_delivery_id and claim_token = p_claim_token and status = 'processing'
  returning device_id into v_device_id;
  if v_device_id is null then return false; end if;
  update public.notification_devices set last_delivery_at = now() where id = v_device_id;
  return true;
end;
$$;

create function public.fail_notification_delivery(
  p_delivery_id uuid,
  p_claim_token uuid,
  p_http_status integer,
  p_error_code text,
  p_retry_after_seconds integer default null,
  p_invalidate_device boolean default false,
  p_retryable boolean default true
)
returns boolean
language plpgsql
volatile
security definer
set search_path = public
as $$
declare v_attempt integer; v_device_id uuid; v_delay integer;
begin
  if auth.role() <> 'service_role' then raise exception 'service role required' using errcode = '42501'; end if;
  if p_delivery_id is null or p_claim_token is null
     or p_http_status is not null and p_http_status not between 100 and 599
     or coalesce(p_error_code, '') !~ '^[A-Za-z0-9_.-]{1,100}$'
     or p_retry_after_seconds is not null and p_retry_after_seconds not between 1 and 86400
     or p_invalidate_device is null or p_retryable is null then
    raise exception 'invalid delivery failure' using errcode = '22023';
  end if;
  select attempt_count, device_id into v_attempt, v_device_id
  from public.notification_deliveries
  where id = p_delivery_id and claim_token = p_claim_token and status = 'processing'
  for update;
  if v_device_id is null then return false; end if;

  -- Exponential backoff capped at one hour; Retry-After may request a longer
  -- bounded delay. Invalid devices and exhausted/non-retryable work go dead.
  v_delay := greatest(
    least(3600, (15 * power(2, greatest(0, v_attempt - 1)))::integer),
    coalesce(p_retry_after_seconds, 0)
  );
  update public.notification_deliveries
  set status = case when p_invalidate_device or not p_retryable or v_attempt >= 8 then 'dead' else 'retry' end,
      next_attempt_at = now() + make_interval(secs => v_delay),
      last_http_status = p_http_status, last_error_code = p_error_code,
      claim_token = null, claimed_at = null
  where id = p_delivery_id;

  if p_invalidate_device then
    update public.notification_devices
    set enabled = false, invalidated_at = now()
    where id = v_device_id;
  end if;
  return true;
end;
$$;

revoke all on function public.claim_notification_deliveries(integer, integer) from public, authenticated, anon;
revoke all on function public.complete_notification_delivery(uuid, uuid, integer) from public, authenticated, anon;
revoke all on function public.fail_notification_delivery(uuid, uuid, integer, text, integer, boolean, boolean) from public, authenticated, anon;
grant execute on function public.claim_notification_deliveries(integer, integer) to service_role;
grant execute on function public.complete_notification_delivery(uuid, uuid, integer) to service_role;
grant execute on function public.fail_notification_delivery(uuid, uuid, integer, text, integer, boolean, boolean) to service_role;

comment on table public.notification_deliveries is
  'Service-only, idempotent APNs outbox. No device token is copied into this table.';
