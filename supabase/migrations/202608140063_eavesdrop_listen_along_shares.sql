-- Position-aware, cross-provider Eavesdrop listen-alongs.
--
-- A listening_share is one explicit host opt-in interval. Existing
-- listening_broadcasts remain one immutable conversation/snapshot per track.
-- Exact playback position exists only on the active listening_presence row and
-- is removed when the share stops or expires.

do $$ begin
  create type public.listening_playback_state as enum ('playing', 'paused');
exception when duplicate_object then null;
end $$;

create table public.listening_shares (
  id uuid primary key default gen_random_uuid(),
  host_profile_id uuid not null references public.profiles(id) on delete cascade,
  visibility public.social_visibility not null default 'followers',
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  end_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (visibility = 'followers'),
  check (ended_at is null or ended_at >= started_at),
  check (end_reason is null or end_reason in ('stopped', 'expired', 'privacy')),
  check ((ended_at is null) = (end_reason is null))
);

create unique index listening_shares_one_active_per_host_idx
  on public.listening_shares(host_profile_id)
  where ended_at is null;
create index listening_shares_host_started_idx
  on public.listening_shares(host_profile_id, started_at desc);

create trigger listening_shares_updated_at
before update on public.listening_shares
for each row execute function public.set_updated_at();

alter table public.listening_broadcasts
  add column listening_share_id uuid
    references public.listening_shares(id) on delete cascade,
  add column generation bigint,
  add constraint listening_broadcast_share_generation_valid check (
    (listening_share_id is null and generation is null)
    or (listening_share_id is not null and generation >= 0)
  );

create unique index listening_broadcast_share_generation_idx
  on public.listening_broadcasts(listening_share_id, generation)
  where listening_share_id is not null;

alter table public.listening_presence
  add column listening_share_id uuid
    references public.listening_shares(id) on delete cascade,
  add column generation bigint,
  add column playback_state public.listening_playback_state,
  add column position_anchor_ms bigint,
  add column anchor_server_at timestamptz,
  add column heartbeat_at timestamptz,
  add column client_sequence bigint,
  add column track_duration_ms integer,
  add constraint listening_presence_synchronized_state_valid check (
    listening_share_id is null
    or (
      generation >= 0
      and playback_state is not null
      and position_anchor_ms between 0 and track_duration_ms
      and anchor_server_at is not null
      and heartbeat_at is not null
      and client_sequence >= 0
      and track_duration_ms > 0
      and expires_at > heartbeat_at
    )
  );

create unique index listening_presence_share_idx
  on public.listening_presence(listening_share_id)
  where listening_share_id is not null;
create index listening_presence_fresh_heartbeat_idx
  on public.listening_presence(heartbeat_at, expires_at)
  where listening_share_id is not null;

alter table public.listening_shares enable row level security;
revoke insert, update, delete on public.listening_shares from authenticated;
grant select on public.listening_shares to authenticated;

-- Followers may see only a fresh, explicitly shared timeline. Public profile
-- visibility is intentionally insufficient for synchronized playback.
create function public.can_view_listening_share(p_listening_share_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null and exists (
    select 1
    from public.listening_shares share
    where share.id = p_listening_share_id
      and (
        share.host_profile_id = auth.uid()
        or (
          share.ended_at is null
          and share.visibility = 'followers'
          and public.is_accepted_follower(share.host_profile_id)
          and not public.social_accounts_are_blocked(
            auth.uid(), share.host_profile_id
          )
          and exists (
            select 1
            from public.listening_presence presence
            where presence.listening_share_id = share.id
              and presence.profile_id = share.host_profile_id
              and presence.expires_at > now()
              and presence.heartbeat_at > now() - interval '30 seconds'
          )
        )
      )
  );
$$;

create policy "view authorized listening shares"
on public.listening_shares for select to authenticated
using (public.can_view_listening_share(id));

drop policy if exists "view consented listening presence"
  on public.listening_presence;
create policy "view fresh listening presence"
on public.listening_presence for select to authenticated
using (
  (
    listening_share_id is not null
    and expires_at > now()
    and heartbeat_at > now() - interval '30 seconds'
    and public.can_view_listening_share(listening_share_id)
  )
  or (
    listening_share_id is null
    and expires_at > now()
    and public.can_view_social(profile_id, visibility)
  )
);

-- Share-linked broadcasts are visible to followers only while that exact
-- generation is current. Ended per-track snapshots remain host-only.
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
          broadcast.listening_share_id is not null
          and broadcast.ended_at is null
          and public.can_view_listening_share(broadcast.listening_share_id)
          and exists (
            select 1
            from public.listening_presence presence
            where presence.broadcast_id = broadcast.id
              and presence.listening_share_id = broadcast.listening_share_id
              and presence.generation = broadcast.generation
          )
        )
        or (
          broadcast.listening_share_id is null
          and broadcast.ended_at is null
          and broadcast.expires_at > now()
          and public.can_view_social(
            broadcast.host_profile_id, broadcast.visibility
          )
        )
      )
  );
$$;

-- Prevent legacy actor RPCs from silently changing a synchronized timeline
-- without its monotonic generation/sequence contract.
create function public.guard_synchronized_listening_presence()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (
    (tg_op = 'INSERT' and new.listening_share_id is not null)
    or (tg_op = 'UPDATE' and old.listening_share_id is not null)
  ) and coalesce(
    current_setting('harmony.synchronized_listening_write', true), 'off'
  ) <> 'on' then
    raise exception 'use publish_listening_state for synchronized listening'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger listening_presence_guard_synchronized_write
before insert or update on public.listening_presence
for each row execute function public.guard_synchronized_listening_presence();

-- Removing the ephemeral row closes the current per-track broadcast and its
-- stable share. Track transitions update presence instead and do not end the
-- stable share.
create or replace function public.close_listening_broadcast()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_effective_ended_at timestamptz := case
    when old.expires_at <= now() then old.expires_at else now()
  end;
  v_reason text := case
    when old.expires_at <= now()
      or old.heartbeat_at <= now() - interval '30 seconds'
      then 'expired'
    else 'stopped'
  end;
begin
  update public.listening_broadcasts
  set ended_at = coalesce(ended_at, v_effective_ended_at),
      ended_reason = coalesce(ended_reason, v_reason)
  where id = old.broadcast_id;

  if old.listening_share_id is not null then
    update public.listening_shares
    set ended_at = coalesce(ended_at, v_effective_ended_at),
        end_reason = coalesce(end_reason, v_reason)
    where id = old.listening_share_id;
  end if;
  return old;
end;
$$;

-- Only the explicit Followers setting can sustain a synchronized share.
-- Audience reduction ends it atomically; legacy display-only presence keeps
-- its earlier private/followers behavior for compatibility.
create or replace function public.sync_listening_presence_visibility()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.live_visibility is not distinct from old.live_visibility then
    return new;
  end if;

  if new.live_visibility is distinct from 'followers'::public.social_visibility then
    update public.listening_shares share
    set ended_at = coalesce(share.ended_at, now()),
        end_reason = coalesce(share.end_reason, 'privacy')
    from public.listening_presence presence
    where presence.profile_id = new.profile_id
      and presence.listening_share_id = share.id;

    delete from public.listening_presence
    where profile_id = new.profile_id
      and (
        listening_share_id is not null
        or new.live_visibility = 'private'
      );
  else
    update public.listening_presence
    set visibility = 'followers'
    where profile_id = new.profile_id
      and expires_at > now();
  end if;

  return new;
end;
$$;

-- Physical cleanup is deliberately separate from history: it deletes only
-- expired active presence (including exact position), never recently played.
create function public.cleanup_expired_listening_shares()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_deleted integer;
begin
  delete from public.listening_presence
  where listening_share_id is not null
    and (
      expires_at <= now()
      or heartbeat_at <= now() - interval '30 seconds'
    );
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

-- Publish one authoritative host observation. The server rounds exact
-- position to 250 ms and supplies all wall-clock timestamps.
create function public.publish_listening_state(
  p_canonical_track_id uuid default null,
  p_source_provider public.music_provider default null,
  p_source_provider_track_id text default null,
  p_playback_state public.listening_playback_state default 'playing',
  p_observed_position_ms bigint default 0,
  p_duration_ms integer default null,
  p_generation bigint default 0,
  p_client_sequence bigint default 0
)
returns table (
  listening_share_id uuid,
  broadcast_id uuid,
  generation bigint,
  client_sequence bigint,
  playback_state text,
  position_anchor_ms bigint,
  anchor_server_at timestamptz,
  heartbeat_at timestamptz,
  expires_at timestamptz,
  idempotent boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_now timestamptz := clock_timestamp();
  v_visibility public.social_visibility;
  v_duration integer;
  v_position bigint;
  v_provider_track_id text := nullif(btrim(coalesce(
    p_source_provider_track_id, ''
  )), '');
  v_source_deep_link text;
  v_presence public.listening_presence%rowtype;
  v_share public.listening_shares%rowtype;
  v_result public.listening_presence%rowtype;
  v_is_new boolean := false;
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_actor_id::text, 0));
  perform public.cleanup_expired_listening_shares();

  select settings.live_visibility into v_visibility
  from public.profile_social_settings settings
  where settings.profile_id = v_actor_id;
  if v_visibility is distinct from 'followers'::public.social_visibility then
    raise exception 'live listening visibility must be followers'
      using errcode = '42501', detail = 'live_listening_not_enabled';
  end if;

  if p_canonical_track_id is null then
    raise exception 'canonical track is required' using errcode = '22023';
  end if;
  select coalesce(p_duration_ms, track.duration_ms)
  into v_duration
  from public.canonical_tracks track
  where track.id = p_canonical_track_id;
  if not found then
    raise exception 'canonical track not found' using errcode = 'P0002';
  end if;
  if v_duration is null or v_duration <= 0 or v_duration > 86400000 then
    raise exception 'valid track duration is required' using errcode = '22023';
  end if;
  if p_observed_position_ms is null or p_observed_position_ms < 0
     or p_observed_position_ms > v_duration then
    raise exception 'position must be within track duration'
      using errcode = '22023';
  end if;
  if p_generation is null or p_generation < 0
     or p_client_sequence is null or p_client_sequence < 0 then
    raise exception 'generation and client sequence must be nonnegative'
      using errcode = '22023';
  end if;
  if (p_source_provider is null) <> (v_provider_track_id is null) then
    raise exception 'source provider and track id must be supplied together'
      using errcode = '22023';
  end if;
  if v_provider_track_id is not null and char_length(v_provider_track_id) > 500 then
    raise exception 'source provider track id is too long' using errcode = '22023';
  end if;

  if p_source_provider is not null then
    select mapping.deep_link into v_source_deep_link
    from public.provider_tracks mapping
    where mapping.canonical_track_id = p_canonical_track_id
      and mapping.provider = p_source_provider
      and mapping.provider_id = v_provider_track_id
    order by (mapping.storefront = 'global') desc, mapping.created_at desc
    limit 1;
    if not found then
      raise exception 'source provider mapping does not match canonical track'
        using errcode = '22023', detail = 'source_mapping_mismatch';
    end if;
  end if;

  -- Round to 250 ms, clamped after rounding.
  v_position := least(
    v_duration::bigint,
    greatest(0::bigint, round(p_observed_position_ms / 250.0)::bigint * 250)
  );

  select * into v_presence
  from public.listening_presence
  where profile_id = v_actor_id
  for update;

  -- A legacy presence is a display-only share. Replace it instead of silently
  -- adopting it into the synchronization contract.
  if found and v_presence.listening_share_id is null then
    delete from public.listening_presence where profile_id = v_actor_id;
    v_presence := null;
  end if;

  if v_presence.listening_share_id is not null then
    select * into v_share
    from public.listening_shares
    where id = v_presence.listening_share_id
    for update;
  end if;

  if v_presence.listening_share_id is null or v_share.ended_at is not null then
    if p_generation <> 0 then
      raise exception 'a new listening share must begin at generation zero'
        using errcode = '22023', detail = 'listening_generation_initial';
    end if;
    update public.listening_shares
    set ended_at = coalesce(ended_at, v_now),
        end_reason = coalesce(end_reason, 'expired')
    where host_profile_id = v_actor_id and ended_at is null;
    insert into public.listening_shares(
      host_profile_id, visibility, started_at
    ) values (v_actor_id, 'followers', v_now)
    returning * into v_share;
    v_is_new := true;
  else
    if p_generation < v_presence.generation
       or (p_generation = v_presence.generation
           and p_client_sequence < v_presence.client_sequence) then
      raise exception 'stale listening state'
        using errcode = 'PT409', detail = 'listening_state_stale';
    end if;
    if p_generation > v_presence.generation + 1 then
      raise exception 'listening generation gap'
        using errcode = 'PT409', detail = 'listening_generation_gap';
    end if;

    if p_generation = v_presence.generation
       and p_client_sequence = v_presence.client_sequence then
      if v_presence.canonical_track_id is distinct from p_canonical_track_id
         or v_presence.provider is distinct from p_source_provider
         or v_presence.provider_track_id is distinct from v_provider_track_id
         or v_presence.playback_state is distinct from p_playback_state
         or v_presence.position_anchor_ms is distinct from v_position
         or v_presence.track_duration_ms is distinct from v_duration then
        raise exception 'duplicate listening sequence has different state'
          using errcode = 'PT409', detail = 'listening_state_duplicate_mismatch';
      end if;

      perform set_config('harmony.synchronized_listening_write', 'on', true);
      update public.listening_presence
      set heartbeat_at = v_now,
          expires_at = v_now + interval '30 seconds'
      where profile_id = v_actor_id
      returning * into v_result;

      return query select
        v_result.listening_share_id, v_result.broadcast_id,
        v_result.generation, v_result.client_sequence,
        v_result.playback_state::text, v_result.position_anchor_ms,
        v_result.anchor_server_at, v_result.heartbeat_at,
        v_result.expires_at, true;
      return;
    end if;

    if p_generation = v_presence.generation then
      if v_presence.canonical_track_id is distinct from p_canonical_track_id
         or v_presence.provider is distinct from p_source_provider
         or v_presence.provider_track_id is distinct from v_provider_track_id then
        raise exception 'track identity requires the next generation'
          using errcode = 'PT409', detail = 'listening_generation_required';
      end if;
    elsif v_presence.canonical_track_id is not distinct from p_canonical_track_id then
      raise exception 'next generation requires a track change'
        using errcode = 'PT409', detail = 'listening_generation_track_unchanged';
    end if;
  end if;

  perform set_config('harmony.synchronized_listening_write', 'on', true);
  if v_is_new then
    insert into public.listening_presence(
      profile_id, canonical_track_id, provider, provider_track_id,
      provider_deep_link, status, visibility, started_at, expires_at,
      listening_share_id, generation, playback_state, position_anchor_ms,
      anchor_server_at, heartbeat_at, client_sequence, track_duration_ms
    ) values (
      v_actor_id, p_canonical_track_id, p_source_provider,
      v_provider_track_id, v_source_deep_link,
      (case when p_playback_state = 'playing' then 'listening'
            else 'paused' end)::public.listening_presence_status,
      'followers', v_now, v_now + interval '30 seconds', v_share.id,
      p_generation, p_playback_state, v_position, v_now, v_now,
      p_client_sequence, v_duration
    ) returning * into v_result;
  else
    update public.listening_presence
    set canonical_track_id = p_canonical_track_id,
        provider = p_source_provider,
        provider_track_id = v_provider_track_id,
        provider_deep_link = v_source_deep_link,
        status = (case when p_playback_state = 'playing' then 'listening'
                       else 'paused' end)::public.listening_presence_status,
        visibility = 'followers',
        started_at = case when p_generation > listening_presence.generation then v_now
                          else started_at end,
        expires_at = v_now + interval '30 seconds',
        generation = p_generation,
        playback_state = p_playback_state,
        position_anchor_ms = v_position,
        anchor_server_at = v_now,
        heartbeat_at = v_now,
        client_sequence = p_client_sequence,
        track_duration_ms = v_duration
    where profile_id = v_actor_id
    returning * into v_result;
  end if;

  update public.listening_broadcasts
  set listening_share_id = v_result.listening_share_id,
      generation = v_result.generation
  where id = v_result.broadcast_id;

  return query select
    v_result.listening_share_id, v_result.broadcast_id,
    v_result.generation, v_result.client_sequence,
    v_result.playback_state::text, v_result.position_anchor_ms,
    v_result.anchor_server_at, v_result.heartbeat_at,
    v_result.expires_at, false;
end;
$$;

create function public.stop_listening_share()
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text, 0));
  delete from public.listening_presence
  where profile_id = auth.uid() and listening_share_id is not null;
  update public.listening_shares
  set ended_at = coalesce(ended_at, now()),
      end_reason = coalesce(end_reason, 'stopped')
  where host_profile_id = auth.uid() and ended_at is null;
  return true;
end;
$$;

create function public.list_live_listen_alongs(
  p_viewer_provider public.music_provider default null,
  p_storefront text default 'us'
)
returns table (
  listening_share_id uuid,
  broadcast_id uuid,
  generation bigint,
  client_sequence bigint,
  host_profile_id uuid,
  host_display_name text,
  canonical_track_id uuid,
  track_title text,
  track_artist text,
  track_album text,
  track_duration_ms integer,
  track_artwork_url text,
  track_is_explicit boolean,
  playback_state text,
  position_anchor_ms bigint,
  anchor_server_at timestamptz,
  server_now timestamptz,
  projected_position_ms bigint,
  heartbeat_at timestamptz,
  expires_at timestamptz,
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
    share.id,
    presence.broadcast_id,
    presence.generation,
    presence.client_sequence,
    share.host_profile_id,
    profile.display_name,
    track.id,
    track.title,
    track.artist,
    track.album,
    presence.track_duration_ms,
    track.artwork_url,
    track.is_explicit,
    presence.playback_state::text,
    presence.position_anchor_ms,
    presence.anchor_server_at,
    statement_timestamp(),
    least(
      presence.track_duration_ms::bigint,
      presence.position_anchor_ms + case
        when presence.playback_state = 'playing'
          then greatest(
            0::bigint,
            floor(extract(epoch from (
              statement_timestamp() - presence.anchor_server_at
            )) * 1000)::bigint
          )
        else 0
      end
    ),
    presence.heartbeat_at,
    presence.expires_at,
    presence.provider::text,
    presence.provider_track_id,
    presence.provider_deep_link,
    mapping.provider::text,
    mapping.provider_id,
    mapping.deep_link,
    mapping.availability::text
  from public.listening_shares share
  join public.listening_presence presence
    on presence.listening_share_id = share.id
  join public.profiles profile on profile.id = share.host_profile_id
  join public.canonical_tracks track on track.id = presence.canonical_track_id
  left join lateral (
    select provider_track.*
    from public.provider_tracks provider_track
    where provider_track.canonical_track_id = presence.canonical_track_id
      and provider_track.provider = p_viewer_provider
    order by
      (provider_track.storefront = lower(coalesce(p_storefront, 'us'))) desc,
      (provider_track.storefront = 'global') desc,
      provider_track.created_at desc
    limit 1
  ) mapping on true
  where share.ended_at is null
    and presence.expires_at > statement_timestamp()
    and presence.heartbeat_at > statement_timestamp() - interval '30 seconds'
  order by presence.heartbeat_at desc, share.id;
$$;

create function public.get_live_listen_along_state(
  p_listening_share_id uuid,
  p_viewer_provider public.music_provider default null,
  p_storefront text default 'us'
)
returns table (
  listening_share_id uuid,
  broadcast_id uuid,
  generation bigint,
  client_sequence bigint,
  host_profile_id uuid,
  host_display_name text,
  canonical_track_id uuid,
  track_title text,
  track_artist text,
  track_album text,
  track_duration_ms integer,
  track_artwork_url text,
  track_is_explicit boolean,
  playback_state text,
  position_anchor_ms bigint,
  anchor_server_at timestamptz,
  server_now timestamptz,
  projected_position_ms bigint,
  heartbeat_at timestamptz,
  expires_at timestamptz,
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
  select *
  from public.list_live_listen_alongs(p_viewer_provider, p_storefront) live
  where live.listening_share_id = p_listening_share_id;
$$;

revoke all on function public.can_view_listening_share(uuid) from public;
revoke all on function public.cleanup_expired_listening_shares() from public;
revoke all on function public.publish_listening_state(
  uuid, public.music_provider, text, public.listening_playback_state,
  bigint, integer, bigint, bigint
) from public;
revoke all on function public.stop_listening_share() from public;
revoke all on function public.list_live_listen_alongs(
  public.music_provider, text
) from public;
revoke all on function public.get_live_listen_along_state(
  uuid, public.music_provider, text
) from public;

grant execute on function public.can_view_listening_share(uuid) to authenticated;
grant execute on function public.cleanup_expired_listening_shares() to service_role;
grant execute on function public.publish_listening_state(
  uuid, public.music_provider, text, public.listening_playback_state,
  bigint, integer, bigint, bigint
) to authenticated;
grant execute on function public.stop_listening_share() to authenticated;
grant execute on function public.list_live_listen_alongs(
  public.music_provider, text
) to authenticated;
grant execute on function public.get_live_listen_along_state(
  uuid, public.music_provider, text
) to authenticated;

-- Supabase projects normally have pg_cron enabled. When it is available, run
-- physical expiry every minute; authorization already hides a state at the
-- stricter 30-second freshness boundary. Environments without pg_cron retain
-- the service-role cleanup RPC for their scheduler.
do $$
declare
  v_job_id bigint;
begin
  if exists (
    select 1 from pg_extension where extname = 'pg_cron'
  ) then
    for v_job_id in execute
      'select jobid from cron.job where jobname = '
      || quote_literal('harmony-expire-listening-shares')
    loop
      execute format('select cron.unschedule(%s)', v_job_id);
    end loop;
    execute $schedule$
      select cron.schedule(
        'harmony-expire-listening-shares',
        '* * * * *',
        'select public.cleanup_expired_listening_shares()'
      )
    $schedule$;
  end if;
end;
$$;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'listening_shares'
  ) then
    alter publication supabase_realtime
      add table public.listening_shares;
  end if;
end;
$$;

comment on table public.listening_shares is
  'One explicit host Eavesdrop interval; no queue, credentials, or position history.';
comment on function public.publish_listening_state(
  uuid, public.music_provider, text, public.listening_playback_state,
  bigint, integer, bigint, bigint
) is
  'Publishes a server-anchored, 250 ms-rounded host timeline with monotonic generation and sequence.';
comment on function public.list_live_listen_alongs(
  public.music_provider, text
) is
  'Lists fresh accepted-follower listen-alongs with one token-free viewer-provider mapping.';
