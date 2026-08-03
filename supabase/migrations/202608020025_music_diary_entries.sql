-- A manual music-diary entry remains a listening-history row. The optional
-- journal metadata therefore inherits the existing feed, deletion RPC, RLS,
-- visibility semantics, and realtime publication.

create or replace function public.normalize_music_diary_tags(p_tags text[])
returns text[]
language sql
immutable
set search_path = public
as $$
  select coalesce(array_agg(normalized_tag order by first_position), '{}'::text[])
  from (
    select lower(btrim(tag)) as normalized_tag, min(position) as first_position
    from unnest(coalesce(p_tags, '{}'::text[])) with ordinality as supplied(tag, position)
    where tag is not null and btrim(tag) <> ''
    group by lower(btrim(tag))
  ) normalized;
$$;

create or replace function public.music_diary_tags_are_valid(p_tags text[])
returns boolean
language sql
immutable
set search_path = public
as $$
  select
    p_tags is not null
    and p_tags = public.normalize_music_diary_tags(p_tags)
    and cardinality(p_tags) <= 10
    and coalesce((select bool_and(char_length(tag) <= 30) from unnest(p_tags) tag), true);
$$;

alter table public.listening_history_entries
  add column is_relisten boolean not null default false,
  add column tags text[] not null default '{}'::text[],
  add constraint listening_history_diary_metadata_manual_only check (
    source = 'manual' or (not is_relisten and tags = '{}'::text[])
  ),
  add constraint listening_history_diary_tags_valid check (
    public.music_diary_tags_are_valid(tags)
  );

-- PostgreSQL treats a new parameter list as an overload. Drop the old
-- function first so PostgREST sees a single unambiguous RPC. The new trailing
-- parameters have defaults, preserving all existing named-parameter calls.
drop function public.record_listening_history(
  uuid,
  public.music_provider,
  text,
  timestamptz,
  public.listening_history_source,
  public.social_visibility
);

create function public.record_listening_history(
  p_canonical_track_id uuid default null,
  p_provider public.music_provider default null,
  p_provider_track_id text default null,
  p_played_at timestamptz default now(),
  p_source public.listening_history_source default 'manual',
  p_visibility public.social_visibility default 'private',
  p_is_relisten boolean default false,
  p_tags text[] default '{}'::text[]
)
returns public.listening_history_entries
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_tags text[] := public.normalize_music_diary_tags(p_tags);
  v_entry public.listening_history_entries%rowtype;
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if p_played_at is null then
    raise exception 'played-at date is required' using errcode = '22004';
  end if;
  if p_source = 'manual' and p_played_at > now() then
    raise exception 'played-at date cannot be in the future' using errcode = '22023';
  end if;
  if p_canonical_track_id is not null
     and not exists (select 1 from public.canonical_tracks where id = p_canonical_track_id) then
    raise exception 'canonical track not found' using errcode = 'P0002';
  end if;
  if cardinality(v_tags) > 10
     or exists (select 1 from unnest(v_tags) tag where char_length(tag) > 30) then
    raise exception 'diary entries support at most ten tags of thirty characters each'
      using errcode = '22023';
  end if;
  if p_source <> 'manual' and (coalesce(p_is_relisten, false) or cardinality(v_tags) > 0) then
    raise exception 'relisten and tags are only available for manual history entries'
      using errcode = '22023';
  end if;

  insert into public.listening_history_entries(
    profile_id,
    canonical_track_id,
    provider,
    provider_track_id,
    played_at,
    source,
    visibility,
    is_relisten,
    tags
  ) values (
    v_actor_id,
    p_canonical_track_id,
    p_provider,
    nullif(trim(coalesce(p_provider_track_id, '')), ''),
    p_played_at,
    p_source,
    p_visibility,
    coalesce(p_is_relisten, false),
    v_tags
  )
  returning * into v_entry;

  return v_entry;
end;
$$;

grant execute on function public.record_listening_history(uuid, public.music_provider, text, timestamptz, public.listening_history_source, public.social_visibility, boolean, text[]) to authenticated;
