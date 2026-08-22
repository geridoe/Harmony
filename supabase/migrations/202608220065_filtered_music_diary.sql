-- Exhaustive server-side Diary browsing. Filters are applied before the stable
-- (played_at, id) keyset cursor, so results do not depend on loaded client pages.

create index listening_history_manual_rating_idx
  on public.listening_history_entries(profile_id, rating, played_at desc, id desc)
  where source = 'manual';
create index listening_history_manual_relisten_idx
  on public.listening_history_entries(profile_id, is_relisten, played_at desc, id desc)
  where source = 'manual';
create index listening_history_manual_tags_gin_idx
  on public.listening_history_entries using gin(tags)
  where source = 'manual';

create function public.search_listening_diary(
  p_profile_id uuid default null,
  p_query text default null,
  p_played_from timestamptz default null,
  p_played_through timestamptz default null,
  p_min_rating numeric default null,
  p_max_rating numeric default null,
  p_is_relisten boolean default null,
  p_tags text[] default null,
  p_provider public.music_provider default null,
  p_before_played_at timestamptz default null,
  p_before_id uuid default null,
  p_limit integer default 50
)
returns setof public.public_listening_diary_entry
language plpgsql volatile security definer set search_path = public as $$
declare
  v_actor_id uuid := auth.uid();
  v_profile_id uuid := coalesce(p_profile_id, auth.uid());
  v_query text := nullif(btrim(coalesce(p_query, '')), '');
  v_tags text[] := public.normalize_music_diary_tags(p_tags);
begin
  if v_actor_id is null then raise exception 'authentication required' using errcode = '28000'; end if;
  if v_profile_id is null then raise exception 'profile id is required' using errcode = '22004'; end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 then raise exception 'Diary page size must be between 1 and 100' using errcode = '22023'; end if;
  if (p_before_played_at is null) <> (p_before_id is null) then raise exception 'Diary cursor timestamp and id must be provided together' using errcode = '22023'; end if;
  if v_query is not null and char_length(v_query) > 200 then raise exception 'Diary search must not exceed 200 characters' using errcode = '22023'; end if;
  if p_played_from is not null and p_played_through is not null and p_played_from > p_played_through then raise exception 'Diary date range is invalid' using errcode = '22023'; end if;
  if (p_min_rating is not null and (p_min_rating < 0.5 or p_min_rating > 5 or mod(p_min_rating * 10, 5) <> 0))
    or (p_max_rating is not null and (p_max_rating < 0.5 or p_max_rating > 5 or mod(p_max_rating * 10, 5) <> 0))
    or (p_min_rating is not null and p_max_rating is not null and p_min_rating > p_max_rating) then
    raise exception 'Diary rating range is invalid' using errcode = '22023';
  end if;
  if p_tags is not null and (cardinality(v_tags) > 10 or exists (select 1 from unnest(v_tags) tag where char_length(tag) > 30)) then
    raise exception 'Diary filters support at most ten tags of thirty characters each' using errcode = '22023';
  end if;
  perform public.consume_account_rate_limit('diary_search', 120, interval '1 minute');

  return query
  select entry.id, entry.profile_id, entry.played_at, entry.source, entry.visibility,
    entry.is_relisten, entry.tags,
    case when entry.review_id is null or public.can_view_music_review(entry.review_id) then entry.review_id else null end,
    entry.rating,
    case when track.id is null then null else jsonb_build_object(
      'id', track.id, 'title', track.title, 'artist', track.artist, 'album', track.album,
      'duration_ms', track.duration_ms, 'artwork_url', track.artwork_url, 'is_explicit', track.is_explicit
    ) end,
    jsonb_build_object('display_name', profile.display_name)
  from public.listening_history_entries entry
  join public.profiles profile on profile.id = entry.profile_id
  left join public.canonical_tracks track on track.id = entry.canonical_track_id
  where entry.profile_id = v_profile_id
    and entry.source = 'manual'
    and (entry.profile_id = v_actor_id or public.can_view_social(entry.profile_id, entry.visibility))
    and (p_played_from is null or entry.played_at >= p_played_from)
    and (p_played_through is null or entry.played_at <= p_played_through)
    and (p_min_rating is null or entry.rating >= p_min_rating)
    and (p_max_rating is null or entry.rating <= p_max_rating)
    and (p_is_relisten is null or entry.is_relisten = p_is_relisten)
    and (p_tags is null or entry.tags @> v_tags)
    and (p_provider is null or entry.provider = p_provider)
    and (v_query is null or concat_ws(' ', track.title, track.artist, track.album) ilike '%'
      || replace(replace(replace(v_query, '\\', '\\\\'), '%', '\\%'), '_', '\\_') || '%' escape '\\')
    and (p_before_played_at is null or entry.played_at < p_before_played_at or (entry.played_at = p_before_played_at and entry.id < p_before_id))
  order by entry.played_at desc, entry.id desc
  limit p_limit;
end; $$;

revoke all on function public.search_listening_diary(uuid, text, timestamptz, timestamptz, numeric, numeric, boolean, text[], public.music_provider, timestamptz, uuid, integer) from public;
grant execute on function public.search_listening_diary(uuid, text, timestamptz, timestamptz, numeric, numeric, boolean, text[], public.music_provider, timestamptz, uuid, integer) to authenticated;

comment on function public.search_listening_diary(uuid, text, timestamptz, timestamptz, numeric, numeric, boolean, text[], public.music_provider, timestamptz, uuid, integer)
is 'Privacy-safe exhaustive Diary search with server-side filters and stable keyset pagination.';
