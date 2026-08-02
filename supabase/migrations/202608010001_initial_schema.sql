-- Harmony collaboration schema. Apply with `supabase db push`.
-- The client may read session state but writes queue state exclusively through
-- `apply_queue_command`, which serializes a session with an advisory lock.

create extension if not exists pgcrypto;

create type public.session_role as enum ('conductor', 'collaborator');
create type public.music_provider as enum ('apple_music', 'spotify');
create type public.track_availability as enum ('playable', 'open_in_provider', 'unavailable');
create type public.playback_mode as enum ('conductor_playback', 'personal_listen_along', 'queue_only');
create type public.queue_command_type as enum ('add', 'move', 'remove', 'play', 'pause', 'skip');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (char_length(trim(display_name)) between 1 and 80),
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.sessions (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(trim(title)) between 1 and 120),
  conductor_id uuid not null references public.profiles(id) on delete restrict,
  invite_code text not null unique check (invite_code ~ '^[A-Z0-9]{6,8}$'),
  queue_revision bigint not null default 0 check (queue_revision >= 0),
  playback_mode public.playback_mode not null default 'conductor_playback',
  playback_state jsonb not null default '{"status":"stopped"}'::jsonb,
  allow_collaborator_invites boolean not null default true,
  expires_at timestamptz,
  ended_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.session_members (
  session_id uuid not null references public.sessions(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  role public.session_role not null default 'collaborator',
  joined_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  primary key (session_id, profile_id)
);

create table public.canonical_tracks (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(trim(title)) between 1 and 500),
  artist text not null check (char_length(trim(artist)) between 1 and 500),
  album text,
  duration_ms integer check (duration_ms is null or duration_ms > 0),
  isrc text check (isrc is null or isrc ~ '^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$'),
  artwork_url text,
  created_at timestamptz not null default now()
);

create table public.provider_tracks (
  id uuid primary key default gen_random_uuid(),
  canonical_track_id uuid not null references public.canonical_tracks(id) on delete cascade,
  provider public.music_provider not null,
  provider_id text not null,
  storefront text not null default 'us',
  deep_link text,
  availability public.track_availability not null default 'playable',
  match_confidence numeric(4,3) check (match_confidence is null or match_confidence between 0 and 1),
  created_at timestamptz not null default now(),
  unique (provider, provider_id, storefront),
  unique (canonical_track_id, provider, storefront)
);

create table public.queue_items (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.sessions(id) on delete cascade,
  canonical_track_id uuid not null references public.canonical_tracks(id) on delete restrict,
  added_by uuid not null references public.profiles(id) on delete restrict,
  -- Fractional positions keep an insert/move to one row; occasional rebalance is safe.
  position double precision not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (session_id, position)
);

create table public.queue_events (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.sessions(id) on delete cascade,
  revision bigint not null check (revision > 0),
  command_id uuid not null,
  actor_id uuid not null references public.profiles(id) on delete restrict,
  type public.queue_command_type not null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (session_id, revision),
  unique (session_id, command_id)
);

-- Tokens are written only by a trusted Edge Function/service role. RLS makes
-- them private to their owner; never return token columns through app queries.
create table public.provider_connections (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  provider public.music_provider not null,
  provider_user_id text,
  scopes text[] not null default '{}',
  encrypted_refresh_token text,
  expires_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (profile_id, provider)
);

create index session_members_profile_session_idx on public.session_members(profile_id, session_id);
create index sessions_conductor_created_idx on public.sessions(conductor_id, created_at desc);
create index provider_tracks_canonical_idx on public.provider_tracks(canonical_track_id);
create index canonical_tracks_isrc_idx on public.canonical_tracks(isrc) where isrc is not null;
create index queue_items_session_position_idx on public.queue_items(session_id, position);
create index queue_events_session_revision_idx on public.queue_events(session_id, revision);
create index provider_connections_profile_idx on public.provider_connections(profile_id);

-- Safe, client-readable provider state. The base table contains an encrypted
-- refresh token and remains inaccessible to `authenticated` clients.
create view public.provider_connection_statuses as
select id, profile_id, provider, provider_user_id, scopes, expires_at, created_at, updated_at
from public.provider_connections
where profile_id = auth.uid();

create or replace function public.set_updated_at()
returns trigger language plpgsql set search_path = public as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger profiles_updated_at before update on public.profiles
for each row execute function public.set_updated_at();
create trigger sessions_updated_at before update on public.sessions
for each row execute function public.set_updated_at();
create trigger queue_items_updated_at before update on public.queue_items
for each row execute function public.set_updated_at();
create trigger provider_connections_updated_at before update on public.provider_connections
for each row execute function public.set_updated_at();

-- Profiles are created automatically when Supabase Auth creates a user. The
-- client can subsequently set a display name through the normal profile update.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name, avatar_url)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data ->> 'full_name', ''), nullif(new.raw_user_meta_data ->> 'name', ''), 'Harmony listener'),
    nullif(new.raw_user_meta_data ->> 'avatar_url', '')
  ) on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created after insert on auth.users
for each row execute procedure public.handle_new_user();

alter table public.profiles enable row level security;
alter table public.sessions enable row level security;
alter table public.session_members enable row level security;
alter table public.canonical_tracks enable row level security;
alter table public.provider_tracks enable row level security;
alter table public.queue_items enable row level security;
alter table public.queue_events enable row level security;
alter table public.provider_connections enable row level security;

create policy "profiles are visible to signed-in users" on public.profiles for select to authenticated using (true);
create policy "users update their own profile" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

create policy "members read their sessions" on public.sessions for select to authenticated using (
  exists (select 1 from public.session_members m where m.session_id = id and m.profile_id = auth.uid())
);
create policy "members read session members" on public.session_members for select to authenticated using (
  exists (select 1 from public.session_members mine where mine.session_id = session_members.session_id and mine.profile_id = auth.uid())
);
create policy "members read tracks" on public.canonical_tracks for select to authenticated using (true);
create policy "members read provider mappings" on public.provider_tracks for select to authenticated using (true);
create policy "members read queue items" on public.queue_items for select to authenticated using (
  exists (select 1 from public.session_members m where m.session_id = queue_items.session_id and m.profile_id = auth.uid())
);
create policy "members read queue events" on public.queue_events for select to authenticated using (
  exists (select 1 from public.session_members m where m.session_id = queue_events.session_id and m.profile_id = auth.uid())
);
create policy "users read their own provider connection metadata" on public.provider_connections for select to authenticated using (profile_id = auth.uid());

-- Keep all collaboration writes out of table grants: security-definer RPCs are
-- the authority for command validation, revision advancement, and audit logs.
revoke insert, update, delete on public.sessions, public.session_members, public.queue_items, public.queue_events from authenticated;
revoke insert, update, delete on public.provider_connections from authenticated;
revoke select on public.provider_connections from authenticated;
grant select on public.provider_connection_statuses to authenticated;

create or replace function public.create_session(
  p_title text,
  p_invite_code text,
  p_playback_mode public.playback_mode default 'conductor_playback',
  p_allow_collaborator_invites boolean default true,
  p_expires_at timestamptz default null
)
returns public.sessions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_session public.sessions%rowtype;
begin
  if v_actor_id is null then raise exception 'authentication required' using errcode = '28000'; end if;
  if not exists (select 1 from public.profiles where id = v_actor_id) then raise exception 'profile not found' using errcode = 'P0002'; end if;
  insert into public.sessions(title, conductor_id, invite_code, playback_mode, allow_collaborator_invites, expires_at)
  values (p_title, v_actor_id, upper(p_invite_code), p_playback_mode, p_allow_collaborator_invites, p_expires_at)
  returning * into v_session;
  insert into public.session_members(session_id, profile_id, role) values (v_session.id, v_actor_id, 'conductor');
  return v_session;
end;
$$;

create or replace function public.join_session_by_invite(p_invite_code text)
returns public.sessions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_session public.sessions%rowtype;
begin
  if v_actor_id is null then raise exception 'authentication required' using errcode = '28000'; end if;
  select * into v_session from public.sessions
  where invite_code = upper(p_invite_code) and ended_at is null and (expires_at is null or expires_at > now())
  for update;
  if not found then raise exception 'session not available' using errcode = 'P0002'; end if;
  insert into public.session_members(session_id, profile_id, role)
  values (v_session.id, v_actor_id, 'collaborator') on conflict (session_id, profile_id) do nothing;
  return v_session;
end;
$$;

grant execute on function public.create_session(text, text, public.playback_mode, boolean, timestamptz) to authenticated;
grant execute on function public.join_session_by_invite(text) to authenticated;

create or replace function public.apply_queue_command(
  p_session_id uuid,
  p_command_id uuid,
  p_expected_revision bigint,
  p_type public.queue_command_type,
  p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_session public.sessions%rowtype;
  v_role public.session_role;
  v_existing public.queue_events%rowtype;
  v_item public.queue_items%rowtype;
  v_new_revision bigint;
  v_position double precision;
  v_track_id uuid;
  v_target_item_id uuid;
begin
  if v_actor_id is null then raise exception 'authentication required' using errcode = '28000'; end if;
  if p_command_id is null then raise exception 'command_id is required' using errcode = '22023'; end if;
  if p_expected_revision is null or p_expected_revision < 0 then raise exception 'a non-negative expected_revision is required' using errcode = '22023'; end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then raise exception 'payload must be an object' using errcode = '22023'; end if;

  -- Idempotency check before locking/revision validation.
  select * into v_existing from public.queue_events where session_id = p_session_id and command_id = p_command_id;
  if found then
    if v_existing.actor_id <> v_actor_id then raise exception 'command id already belongs to another user' using errcode = '42501'; end if;
    return jsonb_build_object('status', 'applied', 'idempotent', true, 'revision', v_existing.revision, 'event_id', v_existing.id);
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_session_id::text, 0));
  select * into v_session from public.sessions where id = p_session_id for update;
  if not found or v_session.ended_at is not null or (v_session.expires_at is not null and v_session.expires_at <= now()) then
    raise exception 'session not available' using errcode = 'P0002';
  end if;
  select role into v_role from public.session_members where session_id = p_session_id and profile_id = v_actor_id;
  if not found then raise exception 'not a session member' using errcode = '42501'; end if;

  if p_expected_revision <> v_session.queue_revision then
    return jsonb_build_object('status', 'conflict', 'revision', v_session.queue_revision);
  end if;

  if p_type = 'add' then
    v_track_id := nullif(p_payload ->> 'canonical_track_id', '')::uuid;
    if v_track_id is null or not exists (select 1 from public.canonical_tracks where id = v_track_id) then
      raise exception 'a valid canonical_track_id is required' using errcode = '22023';
    end if;
    select coalesce(max(position), 0) + 1024 into v_position from public.queue_items where session_id = p_session_id;
    insert into public.queue_items(session_id, canonical_track_id, added_by, position)
    values (p_session_id, v_track_id, v_actor_id, v_position);
  elsif p_type = 'move' then
    if v_role <> 'conductor' then raise exception 'only the conductor may move queue items' using errcode = '42501'; end if;
    v_target_item_id := nullif(p_payload ->> 'queue_item_id', '')::uuid;
    v_position := (p_payload ->> 'position')::double precision;
    if v_target_item_id is null or v_position is null then raise exception 'queue_item_id and position are required' using errcode = '22023'; end if;
    update public.queue_items set position = v_position where id = v_target_item_id and session_id = p_session_id;
    if not found then raise exception 'queue item not found' using errcode = 'P0002'; end if;
  elsif p_type = 'remove' then
    v_target_item_id := nullif(p_payload ->> 'queue_item_id', '')::uuid;
    select * into v_item from public.queue_items where id = v_target_item_id and session_id = p_session_id for update;
    if not found then raise exception 'queue item not found' using errcode = 'P0002'; end if;
    if v_role <> 'conductor' and v_item.added_by <> v_actor_id then raise exception 'may only remove your own queue item' using errcode = '42501'; end if;
    delete from public.queue_items where id = v_target_item_id;
  elsif p_type in ('play', 'pause', 'skip') then
    if v_role <> 'conductor' then raise exception 'only the conductor controls playback' using errcode = '42501'; end if;
    update public.sessions set playback_state = p_payload where id = p_session_id;
  else
    raise exception 'unsupported command' using errcode = '22023';
  end if;

  v_new_revision := v_session.queue_revision + 1;
  update public.sessions set queue_revision = v_new_revision where id = p_session_id;
  insert into public.queue_events(session_id, revision, command_id, actor_id, type, payload)
  values (p_session_id, v_new_revision, p_command_id, v_actor_id, p_type, p_payload);

  return jsonb_build_object('status', 'applied', 'idempotent', false, 'revision', v_new_revision);
end;
$$;

grant execute on function public.apply_queue_command(uuid, uuid, bigint, public.queue_command_type, jsonb) to authenticated;

-- Publish only non-sensitive collaboration tables. Realtime still enforces RLS
-- for Postgres Changes subscriptions; use Broadcast for ephemeral presence.
alter publication supabase_realtime add table public.sessions, public.session_members, public.queue_items, public.queue_events;
