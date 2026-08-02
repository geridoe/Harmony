do $$ begin
  create type public.listening_presence_status as enum ('listening', 'paused');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type public.listening_history_source as enum ('harmony_room', 'provider_import', 'manual');
exception when duplicate_object then null;
end $$;

create table public.listening_presence (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  canonical_track_id uuid references public.canonical_tracks(id) on delete set null,
  provider public.music_provider,
  provider_track_id text,
  provider_deep_link text,
  status public.listening_presence_status not null default 'listening',
  visibility public.social_visibility not null default 'followers',
  started_at timestamptz not null default now(),
  expires_at timestamptz not null,
  updated_at timestamptz not null default now(),
  check (expires_at > started_at),
  check (provider_track_id is null or char_length(provider_track_id) <= 500)
);

create table public.listening_history_entries (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  canonical_track_id uuid references public.canonical_tracks(id) on delete set null,
  provider public.music_provider,
  provider_track_id text,
  played_at timestamptz not null,
  source public.listening_history_source not null,
  visibility public.social_visibility not null default 'private',
  created_at timestamptz not null default now(),
  check (provider_track_id is null or char_length(provider_track_id) <= 500)
);

create index listening_presence_expires_idx on public.listening_presence(expires_at);
create index listening_history_profile_played_idx on public.listening_history_entries(profile_id, played_at desc);
create trigger listening_presence_updated_at before update on public.listening_presence
for each row execute function public.set_updated_at();

alter table public.listening_presence enable row level security;
alter table public.listening_history_entries enable row level security;

create policy "view consented listening presence" on public.listening_presence
for select to authenticated using (
  expires_at > now() and public.can_view_social(profile_id, visibility)
);
create policy "view consented listening history" on public.listening_history_entries
for select to authenticated using (public.can_view_social(profile_id, visibility));

revoke insert, update, delete on public.listening_presence, public.listening_history_entries from authenticated;

create or replace function public.publish_listening_presence(
  p_canonical_track_id uuid default null,
  p_provider public.music_provider default null,
  p_provider_track_id text default null,
  p_provider_deep_link text default null,
  p_status public.listening_presence_status default 'listening',
  p_visibility public.social_visibility default 'followers',
  p_started_at timestamptz default now(),
  p_expires_at timestamptz default now() + interval '5 minutes'
)
returns public.listening_presence
language plpgsql security definer set search_path = public as $$
declare
  v_actor_id uuid := auth.uid();
  v_presence public.listening_presence%rowtype;
begin
  if v_actor_id is null then raise exception 'authentication required' using errcode = '28000'; end if;
  if p_expires_at <= now() or p_expires_at > now() + interval '10 minutes' then
    raise exception 'listening presence must expire within ten minutes' using errcode = '22023';
  end if;
  if p_canonical_track_id is not null and not exists (select 1 from public.canonical_tracks where id = p_canonical_track_id) then
    raise exception 'canonical track not found' using errcode = 'P0002';
  end if;
  insert into public.listening_presence(profile_id, canonical_track_id, provider, provider_track_id, provider_deep_link, status, visibility, started_at, expires_at)
  values (v_actor_id, p_canonical_track_id, p_provider, nullif(trim(coalesce(p_provider_track_id, '')), ''), nullif(trim(coalesce(p_provider_deep_link, '')), ''), p_status, p_visibility, p_started_at, p_expires_at)
  on conflict (profile_id) do update set
    canonical_track_id = excluded.canonical_track_id,
    provider = excluded.provider,
    provider_track_id = excluded.provider_track_id,
    provider_deep_link = excluded.provider_deep_link,
    status = excluded.status,
    visibility = excluded.visibility,
    started_at = excluded.started_at,
    expires_at = excluded.expires_at
  returning * into v_presence;
  return v_presence;
end;
$$;

create or replace function public.stop_listening_presence()
returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'authentication required' using errcode = '28000'; end if;
  delete from public.listening_presence where profile_id = auth.uid();
  return true;
end;
$$;

create or replace function public.record_listening_history(
  p_canonical_track_id uuid default null,
  p_provider public.music_provider default null,
  p_provider_track_id text default null,
  p_played_at timestamptz default now(),
  p_source public.listening_history_source default 'manual',
  p_visibility public.social_visibility default 'private'
)
returns public.listening_history_entries
language plpgsql security definer set search_path = public as $$
declare
  v_actor_id uuid := auth.uid();
  v_entry public.listening_history_entries%rowtype;
begin
  if v_actor_id is null then raise exception 'authentication required' using errcode = '28000'; end if;
  if p_canonical_track_id is not null and not exists (select 1 from public.canonical_tracks where id = p_canonical_track_id) then
    raise exception 'canonical track not found' using errcode = 'P0002';
  end if;
  insert into public.listening_history_entries(profile_id, canonical_track_id, provider, provider_track_id, played_at, source, visibility)
  values (v_actor_id, p_canonical_track_id, p_provider, nullif(trim(coalesce(p_provider_track_id, '')), ''), p_played_at, p_source, p_visibility)
  returning * into v_entry;
  return v_entry;
end;
$$;

create or replace function public.delete_listening_history_entry(p_entry_id uuid)
returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'authentication required' using errcode = '28000'; end if;
  delete from public.listening_history_entries where id = p_entry_id and profile_id = auth.uid();
  return true;
end;
$$;

grant execute on function public.publish_listening_presence(uuid, public.music_provider, text, text, public.listening_presence_status, public.social_visibility, timestamptz, timestamptz), public.stop_listening_presence(), public.record_listening_history(uuid, public.music_provider, text, timestamptz, public.listening_history_source, public.social_visibility), public.delete_listening_history_entry(uuid) to authenticated;
