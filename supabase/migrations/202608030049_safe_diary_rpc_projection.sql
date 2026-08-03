-- Migration 048 intentionally removed direct client access to the private
-- review_id column. PostgREST applies those column privileges again when a
-- table-valued RPC result is projected, even though the SECURITY DEFINER
-- function already authorized and redacted the row. Return a dedicated narrow
-- composite instead, including safe display JSON for the two client embeds.

drop function public.list_my_listening_diary(timestamptz, uuid, integer);
drop function public.list_profile_listening_diary(uuid, timestamptz, uuid, integer);
drop function public.list_visible_listening_diary_entries(uuid[]);

create type public.public_listening_diary_entry as (
  id uuid,
  profile_id uuid,
  played_at timestamptz,
  source public.listening_history_source,
  visibility public.social_visibility,
  is_relisten boolean,
  tags text[],
  review_id uuid,
  rating numeric,
  canonical_tracks jsonb,
  profiles jsonb
);

revoke all on type public.public_listening_diary_entry from public;
grant usage on type public.public_listening_diary_entry to authenticated;

create function public.list_my_listening_diary(
  p_before_played_at timestamptz default null,
  p_before_id uuid default null,
  p_limit integer default 50
)
returns setof public.public_listening_diary_entry
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'journal page size must be between 1 and 100' using errcode = '22023';
  end if;
  if (p_before_played_at is null) <> (p_before_id is null) then
    raise exception 'journal cursor timestamp and id must be provided together'
      using errcode = '22023';
  end if;

  return query
  select
    entry.id,
    entry.profile_id,
    entry.played_at,
    entry.source,
    entry.visibility,
    entry.is_relisten,
    entry.tags,
    entry.review_id,
    entry.rating,
    case when track.id is null then null else jsonb_build_object(
      'id', track.id,
      'title', track.title,
      'artist', track.artist,
      'album', track.album,
      'duration_ms', track.duration_ms,
      'artwork_url', track.artwork_url,
      'is_explicit', track.is_explicit
    ) end,
    jsonb_build_object('display_name', profile.display_name)
  from public.listening_history_entries entry
  join public.profiles profile on profile.id = entry.profile_id
  left join public.canonical_tracks track on track.id = entry.canonical_track_id
  where entry.profile_id = v_actor_id
    and entry.source = 'manual'
    and (
      p_before_played_at is null
      or entry.played_at < p_before_played_at
      or (entry.played_at = p_before_played_at and entry.id < p_before_id)
    )
  order by entry.played_at desc, entry.id desc
  limit p_limit;
end;
$$;

create function public.list_profile_listening_diary(
  p_profile_id uuid,
  p_before_played_at timestamptz default null,
  p_before_id uuid default null,
  p_limit integer default 50
)
returns setof public.public_listening_diary_entry
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if p_profile_id is null then
    raise exception 'profile id is required' using errcode = '22004';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'profile diary page size must be between 1 and 100' using errcode = '22023';
  end if;
  if (p_before_played_at is null) <> (p_before_id is null) then
    raise exception 'profile diary cursor timestamp and id must be provided together'
      using errcode = '22023';
  end if;

  return query
  select
    entry.id,
    entry.profile_id,
    entry.played_at,
    entry.source,
    entry.visibility,
    entry.is_relisten,
    entry.tags,
    case
      when entry.review_id is null or public.can_view_music_review(entry.review_id)
        then entry.review_id
      else null
    end,
    entry.rating,
    case when track.id is null then null else jsonb_build_object(
      'id', track.id,
      'title', track.title,
      'artist', track.artist,
      'album', track.album,
      'duration_ms', track.duration_ms,
      'artwork_url', track.artwork_url,
      'is_explicit', track.is_explicit
    ) end,
    jsonb_build_object('display_name', profile.display_name)
  from public.listening_history_entries entry
  join public.profiles profile on profile.id = entry.profile_id
  left join public.canonical_tracks track on track.id = entry.canonical_track_id
  where entry.profile_id = p_profile_id
    and entry.source = 'manual'
    and public.can_view_social(entry.profile_id, entry.visibility)
    and (
      p_before_played_at is null
      or entry.played_at < p_before_played_at
      or (entry.played_at = p_before_played_at and entry.id < p_before_id)
    )
  order by entry.played_at desc, entry.id desc
  limit p_limit;
end;
$$;

create function public.list_visible_listening_diary_entries(
  p_entry_ids uuid[]
)
returns setof public.public_listening_diary_entry
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if p_entry_ids is null
     or cardinality(p_entry_ids) > 100
     or array_position(p_entry_ids, null) is not null then
    raise exception 'Diary entry ids must contain at most one hundred nonnull ids'
      using errcode = '22023';
  end if;

  return query
  select
    entry.id,
    entry.profile_id,
    entry.played_at,
    entry.source,
    entry.visibility,
    entry.is_relisten,
    entry.tags,
    case
      when entry.review_id is null or public.can_view_music_review(entry.review_id)
        then entry.review_id
      else null
    end,
    entry.rating,
    case when track.id is null then null else jsonb_build_object(
      'id', track.id,
      'title', track.title,
      'artist', track.artist,
      'album', track.album,
      'duration_ms', track.duration_ms,
      'artwork_url', track.artwork_url,
      'is_explicit', track.is_explicit
    ) end,
    jsonb_build_object('display_name', profile.display_name)
  from public.listening_history_entries entry
  join public.profiles profile on profile.id = entry.profile_id
  left join public.canonical_tracks track on track.id = entry.canonical_track_id
  where entry.id = any(p_entry_ids)
    and entry.source = 'manual'
    and public.can_view_social(entry.profile_id, entry.visibility)
  order by array_position(p_entry_ids, entry.id);
end;
$$;

revoke all on function public.list_my_listening_diary(timestamptz, uuid, integer) from public;
revoke all on function public.list_profile_listening_diary(uuid, timestamptz, uuid, integer) from public;
revoke all on function public.list_visible_listening_diary_entries(uuid[]) from public;
grant execute on function public.list_my_listening_diary(timestamptz, uuid, integer) to authenticated;
grant execute on function public.list_profile_listening_diary(uuid, timestamptz, uuid, integer) to authenticated;
grant execute on function public.list_visible_listening_diary_entries(uuid[]) to authenticated;
