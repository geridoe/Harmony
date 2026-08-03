-- Preserve Reviews and Diary as separate records while allowing one coherent
-- authoring action. Any validation or insert failure rolls the whole call back.
create function public.create_track_review_with_optional_diary(
  p_canonical_track_id uuid,
  p_provider public.music_provider default null,
  p_provider_subject_id text default null,
  p_rating numeric default 3.0,
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
declare
  v_review public.music_reviews%rowtype;
  v_entry public.listening_history_entries%rowtype;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
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

  -- The review is created after the historical Diary snapshot so the review's
  -- rating/Loved values remain the authoritative current subject state.
  v_review := public.create_music_review(
    p_subject_kind => 'track',
    p_canonical_track_id => p_canonical_track_id,
    p_provider => p_provider,
    p_provider_subject_id => p_provider_subject_id,
    p_rating => p_rating,
    p_body => p_body,
    p_visibility => p_review_visibility,
    p_contains_spoilers => p_contains_spoilers,
    p_is_loved => p_is_loved
  );

  if p_diary_played_at is not null then
    v_entry := public.update_listening_diary_entry(
      v_entry.id,
      p_diary_played_at,
      p_diary_visibility,
      p_is_relisten,
      p_tags,
      v_review.id
    );
  end if;

  return query select v_review.id, v_entry.id;
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

comment on function public.create_track_review_with_optional_diary(
  uuid, public.music_provider, text, numeric, text, public.social_visibility,
  boolean, boolean, timestamptz, public.social_visibility, boolean, text[], numeric
) is 'Atomically creates a track review and, when requested, a separately modeled linked manual Diary entry.';
