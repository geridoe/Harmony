-- A Letterboxd-style review is the member's current written opinion of one
-- canonical subject. Diary listens remain repeatable historical records, while
-- deleting a review permits a later replacement without destroying the old row.

-- Do not silently choose among authored duplicates. If any durable project has
-- them, stop deployment so they can be reviewed without deleting user writing.
do $$
begin
  if exists (
    select 1
    from public.music_reviews review
    where review.deleted_at is null
      and nullif(btrim(review.body), '') is not null
      and review.subject_kind = 'track'
    group by review.profile_id, review.canonical_track_id
    having count(*) > 1
  ) or exists (
    select 1
    from public.music_reviews review
    where review.deleted_at is null
      and nullif(btrim(review.body), '') is not null
      and review.subject_kind = 'album'
      and review.canonical_album_id is not null
    group by review.profile_id, review.canonical_album_id
    having count(*) > 1
  ) or exists (
    select 1
    from public.music_reviews review
    where review.deleted_at is null
      and nullif(btrim(review.body), '') is not null
      and review.subject_kind = 'album'
      and review.canonical_album_id is null
    group by review.profile_id, review.provider, review.provider_subject_id
    having count(*) > 1
  ) then
    raise exception 'active music review duplicates require an authorship audit before enforcing uniqueness'
      using errcode = '23505', detail = 'active_music_review_duplicates';
  end if;
end;
$$;

create unique index music_reviews_one_active_track_opinion_idx
  on public.music_reviews(profile_id, canonical_track_id)
  where deleted_at is null
    and subject_kind = 'track'
    and nullif(btrim(body), '') is not null;

create unique index music_reviews_one_active_album_opinion_idx
  on public.music_reviews(profile_id, canonical_album_id)
  where deleted_at is null
    and subject_kind = 'album'
    and canonical_album_id is not null
    and nullif(btrim(body), '') is not null;

-- Legacy album rows that could not be canonicalized still receive the same
-- invariant using their exact provider identity. New creation resolves a
-- canonical album before insertion.
create unique index music_reviews_one_active_legacy_album_opinion_idx
  on public.music_reviews(profile_id, provider, provider_subject_id)
  where deleted_at is null
    and subject_kind = 'album'
    and canonical_album_id is null
    and nullif(btrim(body), '') is not null;

-- Serialize same-author/same-subject creation and return a stable conflict
-- instead of exposing an implementation-specific unique-index error. This runs
-- after canonical album resolution and covers every review creation RPC.
create function public.guard_one_active_music_review()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_subject_key text;
begin
  if new.deleted_at is not null or nullif(btrim(new.body), '') is null then
    return new;
  end if;

  v_subject_key := case
    when new.subject_kind = 'track' then 'track:' || new.canonical_track_id::text
    when new.canonical_album_id is not null then 'album:' || new.canonical_album_id::text
    else 'legacy-album:' || coalesce(new.provider::text, '') || ':' ||
      coalesce(new.provider_subject_id, '')
  end;
  perform pg_advisory_xact_lock(
    hashtextextended(new.profile_id::text || ':' || v_subject_key, 0)
  );

  if exists (
    select 1
    from public.music_reviews review
    where review.profile_id = new.profile_id
      and review.deleted_at is null
      and nullif(btrim(review.body), '') is not null
      and (
        (new.subject_kind = 'track'
          and review.subject_kind = 'track'
          and review.canonical_track_id = new.canonical_track_id)
        or
        (new.subject_kind = 'album'
          and new.canonical_album_id is not null
          and review.subject_kind = 'album'
          and review.canonical_album_id = new.canonical_album_id)
        or
        (new.subject_kind = 'album'
          and new.canonical_album_id is null
          and review.subject_kind = 'album'
          and review.canonical_album_id is null
          and review.provider is not distinct from new.provider
          and review.provider_subject_id is not distinct from new.provider_subject_id)
      )
  ) then
    raise exception 'an active review already exists for this music'
      using errcode = 'PT409', detail = 'music_review_already_exists';
  end if;

  return new;
end;
$$;

create trigger music_reviews_guard_one_active_opinion
before insert on public.music_reviews
for each row execute function public.guard_one_active_music_review();

revoke all on function public.guard_one_active_music_review() from public;

-- The composer can resolve an existing opinion directly and route to Edit
-- without scanning locally loaded review pages. The caller identity is always
-- derived from auth.uid().
create function public.get_my_active_music_review(
  p_subject_kind public.review_subject_kind,
  p_canonical_track_id uuid default null,
  p_canonical_album_id uuid default null
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
  if p_subject_kind is null then
    raise exception 'review subject kind is required' using errcode = '22004';
  end if;
  if p_subject_kind = 'track' and
     (p_canonical_track_id is null or p_canonical_album_id is not null) then
    raise exception 'a track review lookup requires only canonical_track_id'
      using errcode = '22023';
  end if;
  if p_subject_kind = 'album' and
     (p_canonical_album_id is null or p_canonical_track_id is not null) then
    raise exception 'an album review lookup requires only canonical_album_id'
      using errcode = '22023';
  end if;

  return query
  select review.*
  from public.music_reviews review
  where review.profile_id = auth.uid()
    and review.deleted_at is null
    and nullif(btrim(review.body), '') is not null
    and (
      (p_subject_kind = 'track'
        and review.subject_kind = 'track'
        and review.canonical_track_id = p_canonical_track_id)
      or
      (p_subject_kind = 'album'
        and review.subject_kind = 'album'
        and review.canonical_album_id = p_canonical_album_id)
    )
  limit 1;
end;
$$;

revoke all on function public.get_my_active_music_review(
  public.review_subject_kind, uuid, uuid
) from public;
grant execute on function public.get_my_active_music_review(
  public.review_subject_kind, uuid, uuid
) to authenticated;

comment on function public.get_my_active_music_review(
  public.review_subject_kind, uuid, uuid
) is 'Returns the authenticated member current written review for one canonical song or album so a composer can route to Edit.';

notify pgrst, 'reload schema';
