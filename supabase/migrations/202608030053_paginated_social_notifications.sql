-- Notifications are a durable recipient inbox. Page them with the same stable
-- two-part keyset used by social activity, and compute the badge from every
-- currently visible unread row rather than the loaded page.

create index social_notifications_recipient_page_idx
  on public.social_notifications(recipient_id, created_at desc, id desc);

create index social_notifications_recipient_unread_idx
  on public.social_notifications(recipient_id, created_at desc, id desc)
  where read_at is null;

create function public.list_social_notifications(
  p_before_created_at timestamptz default null,
  p_before_id uuid default null,
  p_limit integer default 50
)
returns setof public.social_notifications
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'notification page size must be between 1 and 100'
      using errcode = '22023';
  end if;
  if (p_before_created_at is null) <> (p_before_id is null) then
    raise exception 'notification cursor timestamp and id must be provided together'
      using errcode = '22023';
  end if;

  return query
  select notification.*
  from public.social_notifications notification
  where notification.recipient_id = v_actor_id
    and (
      p_before_created_at is null
      or notification.created_at < p_before_created_at
      or (
        notification.created_at = p_before_created_at
        and notification.id < p_before_id
      )
    )
  order by notification.created_at desc, notification.id desc
  limit p_limit;
end;
$$;

create function public.count_unread_social_notifications()
returns bigint
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_count bigint;
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;

  select count(*) into v_count
  from public.social_notifications notification
  where notification.recipient_id = v_actor_id
    and notification.read_at is null;
  return v_count;
end;
$$;

-- Marking all should affect the same block-filtered inbox the caller can see.
-- A blocked actor's hidden notification remains unread and can reappear after
-- unblocking rather than being silently mutated while inaccessible.
create or replace function public.mark_social_notifications_read(
  p_notification_id uuid default null
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_affected integer;
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;

  update public.social_notifications notification
  set read_at = now()
  where notification.recipient_id = v_actor_id
    and notification.read_at is null
    and not public.social_accounts_are_blocked(
      notification.recipient_id,
      notification.actor_id
    )
    and (p_notification_id is null or notification.id = p_notification_id);
  get diagnostics v_affected = row_count;
  return v_affected;
end;
$$;

-- Reaction rows are toggles, not messages. Re-adding the same reaction must
-- not spam another durable notification for the same actor/object pair.
delete from public.social_notifications older
using public.social_notifications newer
where older.kind = 'review_reaction'
  and newer.kind = older.kind
  and newer.recipient_id = older.recipient_id
  and newer.actor_id = older.actor_id
  and newer.review_id = older.review_id
  and (
    newer.created_at > older.created_at
    or (newer.created_at = older.created_at and newer.id > older.id)
  );

delete from public.social_notifications older
using public.social_notifications newer
where older.kind = 'listening_broadcast_reaction'
  and newer.kind = older.kind
  and newer.recipient_id = older.recipient_id
  and newer.actor_id = older.actor_id
  and newer.listening_broadcast_id = older.listening_broadcast_id
  and (
    newer.created_at > older.created_at
    or (newer.created_at = older.created_at and newer.id > older.id)
  );

create unique index social_notifications_review_reaction_unique
  on public.social_notifications(recipient_id, actor_id, review_id)
  where kind = 'review_reaction';

create unique index social_notifications_broadcast_reaction_unique
  on public.social_notifications(
    recipient_id, actor_id, listening_broadcast_id
  )
  where kind = 'listening_broadcast_reaction';

create or replace function public.notify_review_reaction()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_owner_id uuid;
begin
  select profile_id into v_owner_id
  from public.music_reviews
  where id = new.review_id and deleted_at is null;

  if v_owner_id is not null
     and v_owner_id <> new.profile_id
     and not public.social_accounts_are_blocked(v_owner_id, new.profile_id) then
    insert into public.social_notifications(recipient_id, actor_id, kind, review_id)
    values (v_owner_id, new.profile_id, 'review_reaction', new.review_id)
    on conflict (recipient_id, actor_id, review_id)
      where kind = 'review_reaction'
      do nothing;
  end if;
  return new;
end;
$$;

create or replace function public.notify_listening_broadcast_reaction()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_host_id uuid;
begin
  select host_profile_id into v_host_id
  from public.listening_broadcasts
  where id = new.broadcast_id;

  if v_host_id is not null
     and v_host_id <> new.profile_id
     and not public.social_accounts_are_blocked(v_host_id, new.profile_id) then
    insert into public.social_notifications(
      recipient_id, actor_id, kind, listening_broadcast_id
    ) values (
      v_host_id, new.profile_id, 'listening_broadcast_reaction', new.broadcast_id
    )
    on conflict (recipient_id, actor_id, listening_broadcast_id)
      where kind = 'listening_broadcast_reaction'
      do nothing;
  end if;
  return new;
end;
$$;

revoke all on function public.list_social_notifications(
  timestamptz, uuid, integer
) from public;
revoke all on function public.count_unread_social_notifications() from public;
revoke all on function public.mark_social_notifications_read(uuid) from public;
grant execute on function public.list_social_notifications(
  timestamptz, uuid, integer
) to authenticated;
grant execute on function public.count_unread_social_notifications() to authenticated;
grant execute on function public.mark_social_notifications_read(uuid) to authenticated;
