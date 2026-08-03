-- Auth-bound owner review paging is deliberately separate from follower and
-- profile browsing. The existing profile_active_reviews_page_idx supports the
-- predicate and ordering below.
create function public.list_my_music_reviews(
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
    and (
      p_before_created_at is null
      or review.created_at < p_before_created_at
      or (review.created_at = p_before_created_at and review.id < p_before_id)
    )
  order by review.created_at desc, review.id desc
  limit p_limit;
end;
$$;

-- The dedicated Reviews destination must not derive owner totals from the
-- caller's bounded mixed social-review cache. This aggregate is scoped to the
-- authenticated owner and deliberately returns no review bodies.
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
    and review.deleted_at is null;
end;
$$;

revoke all on function public.list_my_music_reviews(timestamptz, uuid, integer) from public;
revoke all on function public.get_my_music_review_stats() from public;
grant execute on function public.list_my_music_reviews(timestamptz, uuid, integer) to authenticated;
grant execute on function public.get_my_music_review_stats() to authenticated;

comment on function public.list_my_music_reviews(timestamptz, uuid, integer) is
  'Keyset-paginated active reviews authored by the authenticated profile.';

comment on function public.get_my_music_review_stats() is
  'Exhaustive current-owner review totals, independent of review pagination and follower activity.';
