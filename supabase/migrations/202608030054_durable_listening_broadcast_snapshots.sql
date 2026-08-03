-- Live presence is ephemeral, but notifications need a durable target after a
-- host stops sharing. Snapshot only display/catalog/provider context; never
-- copy credentials or playback authorization into the broadcast record.

alter table public.listening_broadcasts
  add column host_display_name_snapshot text,
  add column status_snapshot public.listening_presence_status not null default 'listening',
  -- Intentionally not a foreign key: deleting mutable catalog data must not
  -- erase the durable identity shown by an existing notification.
  add column canonical_track_id_snapshot uuid,
  add column track_title_snapshot text,
  add column track_artist_snapshot text,
  add column track_album_snapshot text,
  add column track_duration_ms_snapshot integer,
  add column track_artwork_url_snapshot text,
  add column track_is_explicit_snapshot boolean,
  add column source_provider_snapshot public.music_provider,
  add column source_provider_track_id_snapshot text,
  add column source_deep_link_snapshot text,
  add column ended_reason text;

-- Every historical row can retain its host identity. Active rows additionally
-- still have presence/catalog context available for a complete backfill.
update public.listening_broadcasts broadcast
set host_display_name_snapshot = profile.display_name
from public.profiles profile
where profile.id = broadcast.host_profile_id;

update public.listening_broadcasts
set ended_reason = case
  when ended_at = expires_at then 'expired'
  else 'stopped'
end
where ended_at is not null;

update public.listening_broadcasts broadcast
set status_snapshot = snapshot.status,
    canonical_track_id_snapshot = snapshot.canonical_track_id,
    track_title_snapshot = snapshot.track_title,
    track_artist_snapshot = snapshot.track_artist,
    track_album_snapshot = snapshot.track_album,
    track_duration_ms_snapshot = snapshot.track_duration_ms,
    track_artwork_url_snapshot = snapshot.track_artwork_url,
    track_is_explicit_snapshot = snapshot.track_is_explicit,
    source_provider_snapshot = snapshot.provider,
    source_provider_track_id_snapshot = snapshot.provider_track_id,
    source_deep_link_snapshot = snapshot.provider_deep_link
from (
  select
    presence.broadcast_id,
    presence.status,
    presence.canonical_track_id,
    track.title as track_title,
    track.artist as track_artist,
    track.album as track_album,
    track.duration_ms as track_duration_ms,
    track.artwork_url as track_artwork_url,
    track.is_explicit as track_is_explicit,
    presence.provider,
    presence.provider_track_id,
    presence.provider_deep_link
  from public.listening_presence presence
  left join public.canonical_tracks track
    on track.id = presence.canonical_track_id
) snapshot
where snapshot.broadcast_id = broadcast.id;

alter table public.listening_broadcasts
  alter column host_display_name_snapshot set not null,
  add constraint listening_broadcast_snapshot_host_name_valid check (
    char_length(btrim(host_display_name_snapshot)) between 1 and 80
  ),
  add constraint listening_broadcast_snapshot_duration_valid check (
    track_duration_ms_snapshot is null or track_duration_ms_snapshot > 0
  ),
  add constraint listening_broadcast_ended_reason_valid check (
    ended_reason is null or ended_reason in ('stopped', 'superseded', 'expired')
  );

-- Social broadcasts are live consent, not permanent social posts. Once one is
-- stopped or expires, its durable notification target is host-only. Active-feed
-- SQL separately continues to require ended_at IS NULL and a future expiry.
create or replace function public.can_view_listening_broadcast(
  p_broadcast_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null and exists (
    select 1
    from public.listening_broadcasts broadcast
    where broadcast.id = p_broadcast_id
      and (
        broadcast.host_profile_id = auth.uid()
        or (
          broadcast.ended_at is null
          and broadcast.expires_at > now()
          and public.can_view_social(
            broadcast.host_profile_id, broadcast.visibility
          )
        )
      )
  );
$$;

-- Capture the snapshot in the same transaction that assigns a new broadcast.
-- Reusing an active broadcast for the same provider identity extends only its
-- lifetime/visibility; its original display context remains immutable.
create or replace function public.assign_listening_broadcast()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reuse boolean := false;
  v_host_display_name text;
  v_track public.canonical_tracks%rowtype;
begin
  if tg_op = 'UPDATE' then
    v_reuse := old.expires_at > now()
      and old.broadcast_id is not null
      and old.canonical_track_id is not distinct from new.canonical_track_id
      and old.provider is not distinct from new.provider
      and old.provider_track_id is not distinct from new.provider_track_id;
  end if;

  if v_reuse then
    new.broadcast_id := old.broadcast_id;
    update public.listening_broadcasts
    set visibility = new.visibility,
        expires_at = new.expires_at,
        ended_at = null,
        ended_reason = null,
        status_snapshot = new.status,
        source_provider_snapshot = new.provider,
        source_provider_track_id_snapshot = new.provider_track_id,
        source_deep_link_snapshot = new.provider_deep_link
    where id = old.broadcast_id;
  else
    if tg_op = 'UPDATE' and old.broadcast_id is not null then
      update public.listening_broadcasts
      set ended_at = coalesce(
            ended_at,
            case when old.expires_at <= now() then old.expires_at else now() end
          ),
          ended_reason = coalesce(
            ended_reason,
            case when old.expires_at <= now() then 'expired' else 'superseded' end
          )
      where id = old.broadcast_id;
    end if;

    select profile.display_name into strict v_host_display_name
    from public.profiles profile
    where profile.id = new.profile_id;

    if new.canonical_track_id is not null then
      select * into strict v_track
      from public.canonical_tracks
      where id = new.canonical_track_id;
    end if;

    insert into public.listening_broadcasts(
      host_profile_id,
      visibility,
      started_at,
      expires_at,
      host_display_name_snapshot,
      status_snapshot,
      canonical_track_id_snapshot,
      track_title_snapshot,
      track_artist_snapshot,
      track_album_snapshot,
      track_duration_ms_snapshot,
      track_artwork_url_snapshot,
      track_is_explicit_snapshot,
      source_provider_snapshot,
      source_provider_track_id_snapshot,
      source_deep_link_snapshot
    ) values (
      new.profile_id,
      new.visibility,
      new.started_at,
      new.expires_at,
      v_host_display_name,
      new.status,
      new.canonical_track_id,
      v_track.title,
      v_track.artist,
      v_track.album,
      v_track.duration_ms,
      v_track.artwork_url,
      v_track.is_explicit,
      new.provider,
      new.provider_track_id,
      new.provider_deep_link
    ) returning id into new.broadcast_id;
  end if;
  return new;
end;
$$;

-- Distinguish an explicit/consent-driven stop from a track that was replaced.
create or replace function public.close_listening_broadcast()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.listening_broadcasts
  set ended_at = coalesce(
        ended_at,
        case when old.expires_at <= now() then old.expires_at else now() end
      ),
      ended_reason = coalesce(
        ended_reason,
        case when old.expires_at <= now() then 'expired' else 'stopped' end
      )
  where id = old.broadcast_id;
  return old;
end;
$$;

-- The settings row is directly PATCH-able, so synchronize live consent in the
-- database transaction. Private stops sharing; other changes narrow/widen the
-- active row and its broadcast together through assign_listening_broadcast().
create function public.sync_listening_presence_visibility()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.live_visibility is not distinct from old.live_visibility then
    return new;
  end if;

  if new.live_visibility = 'private' then
    delete from public.listening_presence
    where profile_id = new.profile_id;
  else
    update public.listening_presence
    set visibility = new.live_visibility
    where profile_id = new.profile_id
      and expires_at > now();
  end if;

  return new;
end;
$$;

create trigger profile_social_settings_sync_live_presence
after update of live_visibility on public.profile_social_settings
for each row execute function public.sync_listening_presence_visibility();

create function public.get_listening_broadcast_snapshot(
  p_broadcast_id uuid,
  p_viewer_provider public.music_provider default null,
  p_storefront text default 'us'
)
returns table (
  broadcast_id uuid,
  host_profile_id uuid,
  host_display_name text,
  status text,
  visibility public.social_visibility,
  canonical_track_id uuid,
  track_title text,
  track_artist text,
  track_album text,
  track_duration_ms integer,
  track_artwork_url text,
  track_is_explicit boolean,
  started_at timestamptz,
  expires_at timestamptz,
  ended_at timestamptz,
  effective_ended_at timestamptz,
  ended_reason text,
  updated_at timestamptz,
  source_provider text,
  source_provider_track_id text,
  source_deep_link text,
  viewer_provider text,
  viewer_provider_track_id text,
  viewer_provider_deep_link text,
  viewer_availability text
)
language sql
stable
security invoker
set search_path = public
as $$
  select
    broadcast.id,
    broadcast.host_profile_id,
    broadcast.host_display_name_snapshot,
    case
      when broadcast.ended_reason = 'expired' then 'expired'
      when broadcast.ended_at is not null then 'ended'
      when broadcast.expires_at <= now() then 'expired'
      else coalesce(presence.status, broadcast.status_snapshot)::text
    end,
    broadcast.visibility,
    broadcast.canonical_track_id_snapshot,
    broadcast.track_title_snapshot,
    broadcast.track_artist_snapshot,
    broadcast.track_album_snapshot,
    broadcast.track_duration_ms_snapshot,
    broadcast.track_artwork_url_snapshot,
    broadcast.track_is_explicit_snapshot,
    broadcast.started_at,
    broadcast.expires_at,
    broadcast.ended_at,
    case
      when broadcast.ended_at is not null then broadcast.ended_at
      when broadcast.expires_at <= now() then broadcast.expires_at
      else null
    end,
    case
      when broadcast.ended_at is not null
        then coalesce(broadcast.ended_reason, 'stopped')
      when broadcast.expires_at <= now() then 'expired'
      else null
    end,
    broadcast.updated_at,
    broadcast.source_provider_snapshot::text,
    broadcast.source_provider_track_id_snapshot,
    broadcast.source_deep_link_snapshot,
    mapping.provider::text,
    mapping.provider_id,
    mapping.deep_link,
    mapping.availability::text
  from public.listening_broadcasts broadcast
  left join public.listening_presence presence
    on presence.broadcast_id = broadcast.id
  left join lateral (
    select provider_track.*
    from public.provider_tracks provider_track
    where provider_track.canonical_track_id =
        broadcast.canonical_track_id_snapshot
      and provider_track.provider = p_viewer_provider
    order by
      (provider_track.storefront = lower(coalesce(p_storefront, 'us'))) desc,
      (provider_track.storefront = 'global') desc,
      provider_track.created_at desc
    limit 1
  ) mapping on true
  where broadcast.id = p_broadcast_id;
$$;

revoke all on function public.get_listening_broadcast_snapshot(
  uuid, public.music_provider, text
) from public;
grant execute on function public.get_listening_broadcast_snapshot(
  uuid, public.music_provider, text
) to authenticated;

comment on function public.get_listening_broadcast_snapshot(
  uuid, public.music_provider, text
) is 'Returns one RLS-authorized immutable Eavesdrop display/provider snapshot. Ended/expired snapshots are host-only and never enter the active feed.';
