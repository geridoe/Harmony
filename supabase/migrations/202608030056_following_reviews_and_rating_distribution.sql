-- The dedicated Reviews destination reads authored reviews directly rather
-- than reducing the mixed social-activity feed. Keep follower discovery and
-- review visibility separate: only an accepted outgoing follow and the
-- author's current followers visibility can place a review in this feed.

create index music_reviews_following_page_idx
  on public.music_reviews(created_at desc, id desc)
  where deleted_at is null
    and visibility = 'followers'
    and nullif(btrim(body), '') is not null;

create index music_reviews_following_subject_page_idx
  on public.music_reviews(subject_kind, created_at desc, id desc)
  where deleted_at is null
    and visibility = 'followers'
    and nullif(btrim(body), '') is not null;

create function public.list_following_reviews(
  p_subject_kind text default null,
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
declare
  v_actor_id uuid := auth.uid();
  v_subject_kind text := lower(coalesce(nullif(btrim(p_subject_kind), ''), 'all'));
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if v_subject_kind not in ('all', 'track', 'album') then
    raise exception 'review subject kind must be all, track, or album'
      using errcode = '22023';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'following review page size must be between 1 and 100'
      using errcode = '22023';
  end if;
  if (p_before_created_at is null) <> (p_before_id is null) then
    raise exception 'following review cursor timestamp and id must be provided together'
      using errcode = '22023';
  end if;

  return query
  select review.*
  from public.music_reviews review
  join public.social_follows follow_edge
    on follow_edge.follower_id = v_actor_id
   and follow_edge.followed_id = review.profile_id
   and follow_edge.state = 'accepted'
  where review.deleted_at is null
    and review.visibility = 'followers'
    and nullif(btrim(review.body), '') is not null
    and not public.social_accounts_are_blocked(v_actor_id, review.profile_id)
    and (
      v_subject_kind = 'all'
      or review.subject_kind::text = v_subject_kind
    )
    and (
      p_before_created_at is null
      or review.created_at < p_before_created_at
      or (
        review.created_at = p_before_created_at
        and review.id < p_before_id
      )
    )
  order by review.created_at desc, review.id desc
  limit p_limit;
end;
$$;

revoke all on function public.list_following_reviews(
  text, timestamptz, uuid, integer
) from public;
grant execute on function public.list_following_reviews(
  text, timestamptz, uuid, integer
) to authenticated;

comment on function public.list_following_reviews(
  text, timestamptz, uuid, integer
) is 'Keyset-paginated active written followers-only reviews from accounts the authenticated profile follows; filters subject before pagination, excludes rating-only rows and blocks, and never returns private reviews.';

-- Ratings are current owner-to-subject state, not necessarily authored review
-- stars. Return every half-star bucket, including zero-count buckets, and
-- repeat exhaustive totals on each row so one RPC supplies both the histogram
-- and its summary without deriving either value from loaded review pages.
create function public.get_my_rating_distribution(
  p_subject_kind text default null
)
returns table (
  scope text,
  rating numeric,
  rating_count bigint,
  total_ratings bigint,
  average_rating numeric
)
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_scope text := lower(coalesce(nullif(btrim(p_subject_kind), ''), 'all'));
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if v_scope not in ('all', 'track', 'album') then
    raise exception 'rating subject kind must be all, track, or album'
      using errcode = '22023';
  end if;

  return query
  with owner_ratings as (
    select 'track'::text as subject_kind, state.default_rating as rating
    from public.profile_track_subject_states state
    where state.profile_id = v_actor_id
      and state.default_rating is not null
    union all
    select 'album'::text, state.default_rating
    from public.profile_album_subject_states state
    where state.profile_id = v_actor_id
      and state.default_rating is not null
  ),
  scoped_ratings as (
    select owner_rating.rating
    from owner_ratings owner_rating
    where v_scope = 'all' or owner_rating.subject_kind = v_scope
  ),
  summary as (
    select
      count(*)::bigint as total_ratings,
      round(avg(scoped_rating.rating), 2)::numeric as average_rating
    from scoped_ratings scoped_rating
  ),
  buckets as (
    select (bucket * 0.5)::numeric as rating
    from generate_series(1, 10) bucket
  )
  select
    v_scope,
    bucket.rating,
    count(scoped_rating.rating)::bigint,
    summary.total_ratings,
    summary.average_rating
  from buckets bucket
  cross join summary
  left join scoped_ratings scoped_rating on scoped_rating.rating = bucket.rating
  group by bucket.rating, summary.total_ratings, summary.average_rating
  order by bucket.rating;
end;
$$;

revoke all on function public.get_my_rating_distribution(text) from public;
grant execute on function public.get_my_rating_distribution(text) to authenticated;

comment on function public.get_my_rating_distribution(text) is
  'Returns all ten half-star buckets plus exhaustive total and average for the authenticated owner current track, album, or combined subject-state ratings.';
