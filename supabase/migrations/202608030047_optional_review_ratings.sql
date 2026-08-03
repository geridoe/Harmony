-- Letterboxd-style written reviews do not require a star rating. A review must
-- still contain either a valid half-star rating or non-blank written text.
-- Saving/clearing a review rating updates the current subject state through
-- the existing review triggers; separately modeled Diary snapshots are not
-- mutated.

alter table public.music_reviews
  alter column rating drop not null;

alter table public.music_reviews
  add constraint music_reviews_content_required check (
    rating is not null or nullif(btrim(body), '') is not null
  );

-- An unrated written review still proves the member listened, but it must not
-- inflate the rating sample size. AVG already ignores NULL; rating_count must
-- do so explicitly while listened_count continues to include every review.
create or replace function public.get_canonical_album_state_aggregate(
  p_canonical_album_id uuid
)
returns table (
  canonical_album_id uuid,
  rating_count bigint,
  average_rating numeric,
  listened_count bigint,
  loved_count bigint,
  want_to_listen_count bigint
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
  if not exists (
    select 1
    from public.canonical_albums album
    where album.id = p_canonical_album_id
  ) then
    raise exception 'canonical album not found' using errcode = 'P0002';
  end if;

  return query
  with newest_visible_review as (
    select distinct on (review.profile_id)
      review.profile_id,
      review.rating,
      review.is_loved
    from public.music_reviews review
    where review.subject_kind = 'album'
      and review.canonical_album_id = p_canonical_album_id
      and review.deleted_at is null
    order by
      review.profile_id,
      review.updated_at desc,
      review.created_at desc,
      review.id desc
  )
  select
    p_canonical_album_id,
    count(review.rating),
    round(avg(review.rating), 2),
    count(*),
    count(*) filter (where review.is_loved),
    0::bigint
  from newest_visible_review review;
end;
$$;

alter function public.create_music_review(
  public.review_subject_kind, uuid, public.music_provider, text, text, text,
  text, text, numeric, text, public.social_visibility, boolean, boolean, uuid,
  text, text, date, integer, text
) rename to create_music_review_rated_core;

revoke all on function public.create_music_review_rated_core(
  public.review_subject_kind, uuid, public.music_provider, text, text, text,
  text, text, numeric, text, public.social_visibility, boolean, boolean, uuid,
  text, text, date, integer, text
) from public, authenticated;

create function public.create_music_review(
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
  if p_rating is null and nullif(btrim(coalesce(p_body, '')), '') is null then
    raise exception 'a review requires a rating or written text'
      using errcode = '22023', detail = 'review_content_required';
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

revoke all on function public.create_music_review(
  public.review_subject_kind, uuid, public.music_provider, text, text, text,
  text, text, numeric, text, public.social_visibility, boolean, boolean, uuid,
  text, text, date, integer, text
) from public;
grant execute on function public.create_music_review(
  public.review_subject_kind, uuid, public.music_provider, text, text, text,
  text, text, numeric, text, public.social_visibility, boolean, boolean, uuid,
  text, text, date, integer, text
) to authenticated;

alter function public.update_music_review(
  uuid, numeric, text, public.social_visibility, boolean, boolean
) rename to update_music_review_rated_core;

revoke all on function public.update_music_review_rated_core(
  uuid, numeric, text, public.social_visibility, boolean, boolean
) from public, authenticated;

create function public.update_music_review(
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
  if p_rating is null and nullif(btrim(coalesce(p_body, '')), '') is null then
    raise exception 'a review requires a rating or written text'
      using errcode = '22023', detail = 'review_content_required';
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

revoke all on function public.update_music_review(
  uuid, numeric, text, public.social_visibility, boolean, boolean
) from public;
grant execute on function public.update_music_review(
  uuid, numeric, text, public.social_visibility, boolean, boolean
) to authenticated;

alter function public.create_track_review_with_optional_diary(
  uuid, public.music_provider, text, numeric, text, public.social_visibility,
  boolean, boolean, timestamptz, public.social_visibility, boolean, text[], numeric
) rename to create_track_review_with_optional_diary_rated_core;

revoke all on function public.create_track_review_with_optional_diary_rated_core(
  uuid, public.music_provider, text, numeric, text, public.social_visibility,
  boolean, boolean, timestamptz, public.social_visibility, boolean, text[], numeric
) from public, authenticated;

create function public.create_track_review_with_optional_diary(
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
  if p_rating is null and nullif(btrim(coalesce(p_body, '')), '') is null then
    raise exception 'a review requires a rating or written text'
      using errcode = '22023', detail = 'review_content_required';
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

revoke all on function public.create_track_review_with_optional_diary(
  uuid, public.music_provider, text, numeric, text, public.social_visibility,
  boolean, boolean, timestamptz, public.social_visibility, boolean, text[], numeric
) from public;
grant execute on function public.create_track_review_with_optional_diary(
  uuid, public.music_provider, text, numeric, text, public.social_visibility,
  boolean, boolean, timestamptz, public.social_visibility, boolean, text[], numeric
) to authenticated;

comment on column public.music_reviews.rating is
  'Optional authored half-star rating. NULL represents a written review without a star rating.';
comment on function public.create_music_review(
  public.review_subject_kind, uuid, public.music_provider, text, text, text,
  text, text, numeric, text, public.social_visibility, boolean, boolean, uuid,
  text, text, date, integer, text
) is 'Creates a rating-only, written-only, or rated written review. At least rating or non-blank body is required.';
comment on function public.update_music_review(
  uuid, numeric, text, public.social_visibility, boolean, boolean
) is 'Updates a review and permits clearing its rating when written text remains.';
comment on function public.create_track_review_with_optional_diary(
  uuid, public.music_provider, text, numeric, text, public.social_visibility,
  boolean, boolean, timestamptz, public.social_visibility, boolean, text[], numeric
) is 'Atomically creates an optionally rated track review and an optional independent Diary snapshot.';
