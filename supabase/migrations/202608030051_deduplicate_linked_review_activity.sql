-- A review authored with an optional Diary entry intentionally creates two
-- durable objects, and each object retains its own activity event. Present the
-- linked action as one card at read time: prefer the review while its review
-- event is currently visible, otherwise keep the Diary card. Filtering inside
-- the RPC query (before ORDER/LIMIT) preserves keyset-page density and lets a
-- Diary card reappear if the review later becomes private or is deleted.

-- Migration 048 removed direct client access to listening_history.review_id.
-- Keep list_following_activity SECURITY INVOKER and expose only this narrowly
-- scoped visibility decision through a definer helper.
create function public.diary_activity_has_visible_review_activity(
  p_diary_entry_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null and exists (
    select 1
    from public.listening_history_entries entry
    join public.music_reviews review
      on review.id = entry.review_id
     and review.profile_id = entry.profile_id
    join public.social_activity_events review_event
      on review_event.review_id = review.id
     and review_event.actor_id = review.profile_id
     and review_event.kind = 'review_published'
    where entry.id = p_diary_entry_id
      and entry.source = 'manual'
      and public.can_view_social(entry.profile_id, entry.visibility)
      and review.deleted_at is null
      and review.visibility = 'followers'
      and public.can_view_social(review.profile_id, review.visibility)
  );
$$;

create or replace function public.list_following_activity(
  p_before_published_at timestamptz default null,
  p_before_id uuid default null,
  p_limit integer default 50
)
returns setof public.social_activity_events
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
    raise exception 'activity page size must be between 1 and 100' using errcode = '22023';
  end if;
  if (p_before_published_at is null) <> (p_before_id is null) then
    raise exception 'activity cursor timestamp and id must be provided together'
      using errcode = '22023';
  end if;

  return query
  select event.*
  from public.social_activity_events event
  where (
    p_before_published_at is null
    or event.published_at < p_before_published_at
    or (event.published_at = p_before_published_at and event.id < p_before_id)
  )
    and (
      event.kind <> 'diary_logged'
      or not public.diary_activity_has_visible_review_activity(event.diary_entry_id)
    )
  order by event.published_at desc, event.id desc
  limit p_limit;
end;
$$;

revoke all on function public.diary_activity_has_visible_review_activity(uuid) from public;
revoke all on function public.list_following_activity(timestamptz, uuid, integer) from public;
grant execute on function public.diary_activity_has_visible_review_activity(uuid) to authenticated;
grant execute on function public.list_following_activity(timestamptz, uuid, integer) to authenticated;

comment on function public.diary_activity_has_visible_review_activity(uuid) is
  'Returns whether a Diary activity has a linked review activity currently visible to the authenticated caller; does not expose the linked review id.';
