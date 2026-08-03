-- Match Letterboxd's subject-state semantics for canonical album reviews.
-- A review keeps its authored rating/Loved snapshot, while saving that review
-- also makes the submitted values the owner's current/default album state.

create or replace function public.set_my_album_subject_state(
  p_canonical_album_id uuid,
  p_has_listened boolean,
  p_default_rating numeric,
  p_is_loved boolean,
  p_want_to_listen boolean
)
returns public.profile_album_subject_states
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_has_listened boolean :=
    coalesce(p_has_listened, false) or p_default_rating is not null;
  v_is_loved boolean := coalesce(p_is_loved, false);
  v_want_to_listen boolean;
  v_state public.profile_album_subject_states%rowtype;
  v_now timestamptz;
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if not exists (
    select 1
    from public.canonical_albums
    where id = p_canonical_album_id
  ) then
    raise exception 'canonical album not found' using errcode = 'P0002';
  end if;
  if p_default_rating is not null and (
    p_default_rating < 0.5
    or p_default_rating > 5.0
    or mod(p_default_rating * 10, 5) <> 0
  ) then
    raise exception 'rating must be between 0.5 and 5.0 in half-star steps'
      using errcode = '22023';
  end if;

  v_want_to_listen := case
    when v_has_listened then false
    else coalesce(p_want_to_listen, false)
  end;

  perform pg_advisory_xact_lock(hashtextextended(
    v_actor_id::text || ':album:' || p_canonical_album_id::text,
    0
  ));

  -- An active review is evidence that the album was heard. Serialize this
  -- check with review-trigger writes so a review insert cannot race a clear.
  if not v_has_listened and exists (
    select 1
    from public.music_reviews review
    where review.profile_id = v_actor_id
      and review.subject_kind = 'album'
      and review.canonical_album_id = p_canonical_album_id
      and review.deleted_at is null
  ) then
    raise exception 'Listened cannot be cleared while this album has an active review.'
      using errcode = '22023',
            detail = 'album_subject_listened_is_required';
  end if;

  -- Clearing every relationship deletes the shelf row. The response remains
  -- normalized so clients receive the same shape as an upsert response.
  if not v_has_listened
    and p_default_rating is null
    and not v_is_loved
    and not v_want_to_listen
  then
    delete from public.profile_album_subject_states
    where profile_id = v_actor_id
      and canonical_album_id = p_canonical_album_id
    returning * into v_state;

    v_now := now();
    v_state.profile_id := v_actor_id;
    v_state.canonical_album_id := p_canonical_album_id;
    v_state.has_listened := false;
    v_state.default_rating := null;
    v_state.is_loved := false;
    v_state.want_to_listen := false;
    v_state.created_at := coalesce(v_state.created_at, v_now);
    v_state.updated_at := v_now;
    return v_state;
  end if;

  insert into public.profile_album_subject_states(
    profile_id,
    canonical_album_id,
    has_listened,
    default_rating,
    is_loved,
    want_to_listen
  ) values (
    v_actor_id,
    p_canonical_album_id,
    v_has_listened,
    p_default_rating,
    v_is_loved,
    v_want_to_listen
  )
  on conflict (profile_id, canonical_album_id) do update
  set has_listened = excluded.has_listened,
      default_rating = excluded.default_rating,
      is_loved = excluded.is_loved,
      want_to_listen = excluded.want_to_listen
  returning * into v_state;

  return v_state;
end;
$$;

create function public.sync_album_subject_state_from_review()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.subject_kind <> 'album'
    or new.canonical_album_id is null
    or new.deleted_at is not null
  then
    return new;
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    new.profile_id::text || ':album:' || new.canonical_album_id::text,
    0
  ));

  insert into public.profile_album_subject_states(
    profile_id,
    canonical_album_id,
    has_listened,
    default_rating,
    is_loved,
    want_to_listen
  ) values (
    new.profile_id,
    new.canonical_album_id,
    true,
    new.rating,
    new.is_loved,
    false
  )
  on conflict (profile_id, canonical_album_id) do update
  set has_listened = true,
      default_rating = excluded.default_rating,
      is_loved = excluded.is_loved,
      want_to_listen = false;

  return new;
end;
$$;

create trigger music_reviews_sync_album_subject_insert
after insert on public.music_reviews
for each row execute function public.sync_album_subject_state_from_review();

create trigger music_reviews_sync_album_subject_update
after update of rating, is_loved, deleted_at on public.music_reviews
for each row execute function public.sync_album_subject_state_from_review();

-- Existing reviews predate the trigger. The most recently changed active
-- review supplies the same state that would have resulted from live writes.
with newest_active_review as (
  select distinct on (review.profile_id, review.canonical_album_id)
    review.profile_id,
    review.canonical_album_id,
    review.rating,
    review.is_loved
  from public.music_reviews review
  where review.subject_kind = 'album'
    and review.canonical_album_id is not null
    and review.deleted_at is null
  order by
    review.profile_id,
    review.canonical_album_id,
    review.updated_at desc,
    review.created_at desc,
    review.id desc
)
insert into public.profile_album_subject_states(
  profile_id,
  canonical_album_id,
  has_listened,
  default_rating,
  is_loved,
  want_to_listen
)
select
  review.profile_id,
  review.canonical_album_id,
  true,
  review.rating,
  review.is_loved,
  false
from newest_active_review review
on conflict (profile_id, canonical_album_id) do update
set has_listened = true,
    default_rating = excluded.default_rating,
    is_loved = excluded.is_loved,
    want_to_listen = false;

-- Community summaries represent one current member opinion, not the number of
-- historical reviews that member has authored. SECURITY INVOKER preserves the
-- music_reviews RLS boundary before the per-profile newest-row reduction.
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
    count(*),
    round(avg(review.rating), 2),
    count(*),
    count(*) filter (where review.is_loved),
    0::bigint
  from newest_visible_review review;
end;
$$;

create or replace function public.list_canonical_album_rating_distribution(
  p_canonical_album_id uuid
)
returns table (
  rating numeric,
  rating_count bigint
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
      review.rating
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
    bucket.step::numeric / 2,
    count(review.profile_id)
  from generate_series(1, 10) as bucket(step)
  left join newest_visible_review review
    on review.rating = bucket.step::numeric / 2
  group by bucket.step
  order by bucket.step;
end;
$$;

revoke all on function public.sync_album_subject_state_from_review()
from public;
revoke all on function public.set_my_album_subject_state(
  uuid, boolean, numeric, boolean, boolean
) from public;
grant execute on function public.set_my_album_subject_state(
  uuid, boolean, numeric, boolean, boolean
) to authenticated;
revoke all on function public.get_canonical_album_state_aggregate(uuid)
from public;
revoke all on function public.list_canonical_album_rating_distribution(uuid)
from public;
grant execute on function public.get_canonical_album_state_aggregate(uuid)
to authenticated;
grant execute on function public.list_canonical_album_rating_distribution(uuid)
to authenticated;
