-- Ratings and authored reviews are distinct Letterboxd-style actions. A
-- rating is current owner-to-subject state; a review is published writing and
-- therefore requires a non-blank body. Historical rating-only review rows are
-- retained for compatibility, but no review browsing/statistics RPC exposes
-- them as authored reviews.

create index profile_written_reviews_page_idx
  on public.music_reviews(profile_id, created_at desc, id desc)
  where deleted_at is null
    and nullif(btrim(body), '') is not null;

create or replace function public.create_music_review(
  p_subject_kind public.review_subject_kind,
  p_canonical_track_id uuid default null,
  p_provider public.music_provider default null,
  p_provider_subject_id text default null,
  p_subject_title text default null,
  p_subject_artist text default null,
  p_subject_artwork_url text default null,
  p_subject_deep_link text default null,
  p_rating numeric default null,
  p_body text default '',
  p_visibility public.social_visibility default 'followers',
  p_contains_spoilers boolean default false,
  p_is_loved boolean default false,
  p_canonical_album_id uuid default null,
  p_provider_storefront text default null,
  p_album_upc text default null,
  p_album_release_date date default null,
  p_album_total_tracks integer default null,
  p_album_type text default null
)
returns public.music_reviews
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if nullif(btrim(coalesce(p_body, '')), '') is null then
    raise exception 'a review requires written text'
      using errcode = '22023', detail = 'review_body_required';
  end if;
  if p_rating is not null and (
    p_rating < 0.5
    or p_rating > 5.0
    or mod(p_rating * 10, 5) <> 0
  ) then
    raise exception 'rating must be between 0.5 and 5.0 in half-star steps'
      using errcode = '22023', detail = 'review_rating_invalid';
  end if;

  return public.create_music_review_rated_core(
    p_subject_kind => p_subject_kind,
    p_canonical_track_id => p_canonical_track_id,
    p_provider => p_provider,
    p_provider_subject_id => p_provider_subject_id,
    p_subject_title => p_subject_title,
    p_subject_artist => p_subject_artist,
    p_subject_artwork_url => p_subject_artwork_url,
    p_subject_deep_link => p_subject_deep_link,
    p_rating => p_rating,
    p_body => p_body,
    p_visibility => p_visibility,
    p_contains_spoilers => p_contains_spoilers,
    p_is_loved => p_is_loved,
    p_canonical_album_id => p_canonical_album_id,
    p_provider_storefront => p_provider_storefront,
    p_album_upc => p_album_upc,
    p_album_release_date => p_album_release_date,
    p_album_total_tracks => p_album_total_tracks,
    p_album_type => p_album_type
  );
end;
$$;

create or replace function public.update_music_review(
  p_review_id uuid,
  p_rating numeric default null,
  p_body text default '',
  p_visibility public.social_visibility default 'followers',
  p_contains_spoilers boolean default false,
  p_is_loved boolean default false
)
returns public.music_reviews
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if nullif(btrim(coalesce(p_body, '')), '') is null then
    raise exception 'a review requires written text'
      using errcode = '22023', detail = 'review_body_required';
  end if;
  if p_rating is not null and (
    p_rating < 0.5
    or p_rating > 5.0
    or mod(p_rating * 10, 5) <> 0
  ) then
    raise exception 'rating must be between 0.5 and 5.0 in half-star steps'
      using errcode = '22023', detail = 'review_rating_invalid';
  end if;

  return public.update_music_review_rated_core(
    p_review_id => p_review_id,
    p_rating => p_rating,
    p_body => p_body,
    p_visibility => p_visibility,
    p_contains_spoilers => p_contains_spoilers,
    p_is_loved => p_is_loved
  );
end;
$$;

create or replace function public.create_track_review_with_optional_diary(
  p_canonical_track_id uuid,
  p_provider public.music_provider default null,
  p_provider_subject_id text default null,
  p_rating numeric default null,
  p_body text default '',
  p_review_visibility public.social_visibility default 'followers',
  p_contains_spoilers boolean default false,
  p_is_loved boolean default false,
  p_diary_played_at timestamptz default null,
  p_diary_visibility public.social_visibility default 'private',
  p_is_relisten boolean default false,
  p_tags text[] default '{}'::text[],
  p_diary_rating numeric default null
)
returns table(review_id uuid, diary_entry_id uuid)
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if nullif(btrim(coalesce(p_body, '')), '') is null then
    raise exception 'a review requires written text'
      using errcode = '22023', detail = 'review_body_required';
  end if;
  if p_rating is not null and (
    p_rating < 0.5
    or p_rating > 5.0
    or mod(p_rating * 10, 5) <> 0
  ) then
    raise exception 'rating must be between 0.5 and 5.0 in half-star steps'
      using errcode = '22023', detail = 'review_rating_invalid';
  end if;

  return query
  select result.review_id, result.diary_entry_id
  from public.create_track_review_with_optional_diary_rated_core(
    p_canonical_track_id => p_canonical_track_id,
    p_provider => p_provider,
    p_provider_subject_id => p_provider_subject_id,
    p_rating => p_rating,
    p_body => p_body,
    p_review_visibility => p_review_visibility,
    p_contains_spoilers => p_contains_spoilers,
    p_is_loved => p_is_loved,
    p_diary_played_at => p_diary_played_at,
    p_diary_visibility => p_diary_visibility,
    p_is_relisten => p_is_relisten,
    p_tags => p_tags,
    p_diary_rating => p_diary_rating
  ) result;
end;
$$;

-- The exact owner pages count only authored writing. The storage table keeps
-- legacy rating-only rows so old identifiers and links remain non-destructive.
create or replace function public.list_my_music_reviews(
  p_before_created_at timestamptz default null,
  p_before_id uuid default null,
  p_limit integer default 50
)
returns setof public.music_reviews
language plpgsql
stable
security invoker
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'review page size must be between 1 and 100' using errcode = '22023';
  end if;
  if (p_before_created_at is null) <> (p_before_id is null) then
    raise exception 'review cursor timestamp and id must be provided together'
      using errcode = '22023';
  end if;

  return query
  select review.*
  from public.music_reviews review
  where review.profile_id = auth.uid()
    and review.deleted_at is null
    and nullif(btrim(review.body), '') is not null
    and (
      p_before_created_at is null
      or review.created_at < p_before_created_at
      or (review.created_at = p_before_created_at and review.id < p_before_id)
    )
  order by review.created_at desc, review.id desc
  limit p_limit;
end;
$$;

create or replace function public.list_profile_music_reviews(
  p_profile_id uuid,
  p_before_created_at timestamptz default null,
  p_before_id uuid default null,
  p_limit integer default 50
)
returns setof public.music_reviews
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
    raise exception 'profile review page size must be between 1 and 100' using errcode = '22023';
  end if;
  if (p_before_created_at is null) <> (p_before_id is null) then
    raise exception 'profile review cursor timestamp and id must be provided together'
      using errcode = '22023';
  end if;

  return query
  select review.*
  from public.music_reviews review
  where review.profile_id = p_profile_id
    and review.deleted_at is null
    and nullif(btrim(review.body), '') is not null
    and public.can_view_social(review.profile_id, review.visibility)
    and (
      p_before_created_at is null
      or review.created_at < p_before_created_at
      or (review.created_at = p_before_created_at and review.id < p_before_id)
    )
  order by review.created_at desc, review.id desc
  limit p_limit;
end;
$$;

create or replace function public.get_my_music_review_stats()
returns table (
  review_count bigint,
  average_rating numeric,
  loved_count bigint,
  song_count bigint,
  album_count bigint
)
language plpgsql
stable
security invoker
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;

  return query
  select
    count(*)::bigint,
    avg(review.rating)::numeric,
    count(*) filter (where review.is_loved)::bigint,
    count(*) filter (where review.subject_kind = 'track')::bigint,
    count(*) filter (where review.subject_kind = 'album')::bigint
  from public.music_reviews review
  where review.profile_id = auth.uid()
    and review.deleted_at is null
    and nullif(btrim(review.body), '') is not null;
end;
$$;

-- Rating plus optional Diary is a single transaction, but it creates no
-- review. The historical Diary snapshot is written first, then the explicit
-- rating/Loved values win as the current track subject state.
create function public.save_track_rating_with_optional_diary(
  p_canonical_track_id uuid,
  p_rating numeric,
  p_is_loved boolean default false,
  p_provider public.music_provider default null,
  p_provider_subject_id text default null,
  p_diary_played_at timestamptz default null,
  p_diary_visibility public.social_visibility default 'private',
  p_is_relisten boolean default false,
  p_tags text[] default '{}'::text[],
  p_diary_rating numeric default null
)
returns table (
  diary_entry_id uuid,
  canonical_track_id uuid,
  has_listened boolean,
  default_rating numeric,
  is_loved boolean,
  want_to_listen boolean,
  state_updated_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_entry public.listening_history_entries%rowtype;
  v_state public.profile_track_subject_states%rowtype;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if p_rating is null then
    raise exception 'rating is required'
      using errcode = '22004', detail = 'rating_required';
  end if;
  if p_rating < 0.5 or p_rating > 5.0 or mod(p_rating * 10, 5) <> 0 then
    raise exception 'rating must be between 0.5 and 5.0 in half-star steps'
      using errcode = '22023', detail = 'rating_invalid';
  end if;
  if not exists (
    select 1 from public.canonical_tracks track
    where track.id = p_canonical_track_id
  ) then
    raise exception 'canonical track not found' using errcode = 'P0002';
  end if;
  if p_diary_played_at is null and (
    coalesce(p_is_relisten, false)
    or cardinality(public.normalize_music_diary_tags(p_tags)) > 0
    or p_diary_rating is not null
    or p_diary_visibility is distinct from 'private'
  ) then
    raise exception 'Diary context requires add-to-Diary'
      using errcode = '22023';
  end if;
  if p_diary_played_at is not null and p_diary_visibility is null then
    raise exception 'Diary visibility is required when adding to Diary'
      using errcode = '22004';
  end if;
  if (p_provider is null) <> (
    nullif(btrim(coalesce(p_provider_subject_id, '')), '') is null
  ) then
    raise exception 'provider and provider track identifier must be supplied together'
      using errcode = '22023';
  end if;
  if p_provider is not null and not exists (
    select 1
    from public.provider_tracks mapping
    where mapping.canonical_track_id = p_canonical_track_id
      and mapping.provider = p_provider
      and mapping.provider_id = btrim(p_provider_subject_id)
  ) then
    raise exception 'provider track mapping does not belong to the canonical track'
      using errcode = '22023';
  end if;

  if p_diary_played_at is not null then
    v_entry := public.record_listening_history(
      p_canonical_track_id => p_canonical_track_id,
      p_provider => p_provider,
      p_provider_track_id => p_provider_subject_id,
      p_played_at => p_diary_played_at,
      p_source => 'manual',
      p_visibility => p_diary_visibility,
      p_is_relisten => p_is_relisten,
      p_tags => p_tags,
      p_rating => p_diary_rating
    );
  end if;

  v_state := public.set_my_track_subject_state(
    p_canonical_track_id => p_canonical_track_id,
    p_has_listened => true,
    p_default_rating => p_rating,
    p_is_loved => p_is_loved,
    p_want_to_listen => false
  );

  return query select
    v_entry.id,
    v_state.canonical_track_id,
    v_state.has_listened,
    v_state.default_rating,
    v_state.is_loved,
    v_state.want_to_listen,
    v_state.updated_at;
end;
$$;

-- Reassert the client boundary after replacing functions.
revoke all on function public.create_music_review(
  public.review_subject_kind, uuid, public.music_provider, text, text, text,
  text, text, numeric, text, public.social_visibility, boolean, boolean, uuid,
  text, text, date, integer, text
) from public;
revoke all on function public.update_music_review(
  uuid, numeric, text, public.social_visibility, boolean, boolean
) from public;
revoke all on function public.create_track_review_with_optional_diary(
  uuid, public.music_provider, text, numeric, text, public.social_visibility,
  boolean, boolean, timestamptz, public.social_visibility, boolean, text[], numeric
) from public;
revoke all on function public.list_my_music_reviews(timestamptz, uuid, integer) from public;
revoke all on function public.list_profile_music_reviews(uuid, timestamptz, uuid, integer) from public;
revoke all on function public.get_my_music_review_stats() from public;
revoke all on function public.save_track_rating_with_optional_diary(
  uuid, numeric, boolean, public.music_provider, text, timestamptz,
  public.social_visibility, boolean, text[], numeric
) from public;

grant execute on function public.create_music_review(
  public.review_subject_kind, uuid, public.music_provider, text, text, text,
  text, text, numeric, text, public.social_visibility, boolean, boolean, uuid,
  text, text, date, integer, text
) to authenticated;
grant execute on function public.update_music_review(
  uuid, numeric, text, public.social_visibility, boolean, boolean
) to authenticated;
grant execute on function public.create_track_review_with_optional_diary(
  uuid, public.music_provider, text, numeric, text, public.social_visibility,
  boolean, boolean, timestamptz, public.social_visibility, boolean, text[], numeric
) to authenticated;
grant execute on function public.list_my_music_reviews(timestamptz, uuid, integer) to authenticated;
grant execute on function public.list_profile_music_reviews(uuid, timestamptz, uuid, integer) to authenticated;
grant execute on function public.get_my_music_review_stats() to authenticated;
grant execute on function public.save_track_rating_with_optional_diary(
  uuid, numeric, boolean, public.music_provider, text, timestamptz,
  public.social_visibility, boolean, text[], numeric
) to authenticated;

comment on function public.create_music_review(
  public.review_subject_kind, uuid, public.music_provider, text, text, text,
  text, text, numeric, text, public.social_visibility, boolean, boolean, uuid,
  text, text, date, integer, text
) is 'Creates an authored review. Non-blank written text is required; use subject state for rating-only saves.';
comment on function public.update_music_review(
  uuid, numeric, text, public.social_visibility, boolean, boolean
) is 'Updates an authored review. Non-blank written text remains required; rating is optional.';
comment on function public.create_track_review_with_optional_diary(
  uuid, public.music_provider, text, numeric, text, public.social_visibility,
  boolean, boolean, timestamptz, public.social_visibility, boolean, text[], numeric
) is 'Atomically creates a written track review and optional linked Diary snapshot. Non-blank review text is required.';
comment on function public.save_track_rating_with_optional_diary(
  uuid, numeric, boolean, public.music_provider, text, timestamptz,
  public.social_visibility, boolean, text[], numeric
) is 'Atomically saves a required current track rating/Loved state and optional independent Diary snapshot without creating a review.';
