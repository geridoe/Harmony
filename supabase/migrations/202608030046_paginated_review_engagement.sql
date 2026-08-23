-- Review collections must not embed an unbounded conversation for every card.
-- Keep the parent review as the visibility authority, page its active comments
-- with a stable two-part cursor, and expose only bounded engagement summary
-- data until the detail screen explicitly loads the conversation.

-- LOCK TABLE is only valid inside an explicit transaction. Keep this migration
-- atomic so the child-table locks remain held through trigger installation and
-- no engagement change can land between the backfill and counter maintenance.
begin;

alter table public.music_reviews
  add column heart_count bigint not null default 0,
  add column comment_count bigint not null default 0,
  add constraint music_reviews_heart_count_nonnegative check (heart_count >= 0),
  add constraint music_reviews_comment_count_nonnegative check (comment_count >= 0);

-- Engagement changes are not edits to the authored review. Restrict the
-- existing timestamp trigger so counter maintenance does not reorder current
-- opinion reduction or make an old review look newly edited.
drop trigger music_reviews_updated_at on public.music_reviews;
create trigger music_reviews_updated_at
before update of
  subject_kind,
  canonical_track_id,
  canonical_album_id,
  provider,
  provider_subject_id,
  subject_title,
  subject_artist,
  subject_artwork_url,
  subject_deep_link,
  rating,
  body,
  visibility,
  contains_spoilers,
  is_loved,
  deleted_at
on public.music_reviews
for each row execute function public.set_updated_at();

-- Backfill without changing authored updated_at. Deleted reviews remain
-- inaccessible and do not need engagement summaries. Hold both child tables
-- against concurrent DML until their maintenance triggers and the backfill are
-- committed, preventing an insert/delete transition from falling in between.
lock table public.review_comments, public.review_reactions
  in share row exclusive mode;

update public.music_reviews review
set heart_count = (
      select count(*)
      from public.review_reactions reaction
      where reaction.review_id = review.id
        and reaction.kind = 'heart'
    ),
    comment_count = (
      select count(*)
      from public.review_comments comment
      where comment.review_id = review.id
        and comment.deleted_at is null
    )
where review.deleted_at is null;

create function public.sync_music_review_comment_count()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_delta bigint := 0;
  v_review_id uuid;
begin
  if tg_op = 'INSERT' then
    v_review_id := new.review_id;
    if new.deleted_at is null then v_delta := 1; end if;
  elsif tg_op = 'DELETE' then
    v_review_id := old.review_id;
    if old.deleted_at is null then v_delta := -1; end if;
  else
    v_review_id := new.review_id;
    if old.deleted_at is null and new.deleted_at is not null then
      v_delta := -1;
    elsif old.deleted_at is not null and new.deleted_at is null then
      v_delta := 1;
    end if;
  end if;

  if v_delta <> 0 then
    update public.music_reviews
    set comment_count = greatest(0::bigint, comment_count + v_delta)
    where id = v_review_id;
  end if;

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

create trigger review_comments_sync_review_count
after insert or delete or update of deleted_at on public.review_comments
for each row execute function public.sync_music_review_comment_count();

create function public.sync_music_review_heart_count()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' and new.kind = 'heart' then
    update public.music_reviews
    set heart_count = heart_count + 1
    where id = new.review_id;
  elsif tg_op = 'DELETE' and old.kind = 'heart' then
    update public.music_reviews
    set heart_count = greatest(0::bigint, heart_count - 1)
    where id = old.review_id;
  end if;

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

create trigger review_reactions_sync_review_heart_count
after insert or delete on public.review_reactions
for each row execute function public.sync_music_review_heart_count();

create index review_comments_page_idx
  on public.review_comments(review_id, created_at desc, id desc)
  where deleted_at is null;

create index review_reactions_heart_review_idx
  on public.review_reactions(review_id)
  where kind = 'heart';

create function public.list_review_comments(
  p_review_id uuid,
  p_before_created_at timestamptz default null,
  p_before_id uuid default null,
  p_limit integer default 50
)
returns setof public.review_comments
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
    raise exception 'review comment page size must be between 1 and 100'
      using errcode = '22023';
  end if;
  if (p_before_created_at is null) <> (p_before_id is null) then
    raise exception 'review comment cursor timestamp and id must be provided together'
      using errcode = '22023';
  end if;
  if not public.can_view_music_review(p_review_id) then
    raise exception 'review unavailable' using errcode = '42501';
  end if;

  return query
  select comment.*
  from public.review_comments comment
  where comment.review_id = p_review_id
    and comment.deleted_at is null
    and not public.social_accounts_are_blocked(auth.uid(), comment.author_id)
    and (
      p_before_created_at is null
      or comment.created_at < p_before_created_at
      or (
        comment.created_at = p_before_created_at
        and comment.id < p_before_id
      )
    )
  order by comment.created_at desc, comment.id desc
  limit p_limit;
end;
$$;

create function public.get_review_engagement(p_review_id uuid)
returns jsonb
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_heart_count bigint;
  v_comment_count bigint;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if not public.can_view_music_review(p_review_id) then
    raise exception 'review unavailable' using errcode = '42501';
  end if;

  select review.heart_count, review.comment_count
    into v_heart_count, v_comment_count
  from public.music_reviews review
  where review.id = p_review_id;

  return jsonb_build_object(
    'heart_count', v_heart_count,
    'comment_count', v_comment_count,
    'viewer_has_hearted', exists (
      select 1
      from public.review_reactions reaction
      where reaction.review_id = p_review_id
        and reaction.profile_id = auth.uid()
        and reaction.kind = 'heart'
    )
  );
end;
$$;

revoke all on function public.list_review_comments(
  uuid, timestamptz, uuid, integer
) from public;
revoke all on function public.get_review_engagement(uuid) from public;
revoke all on function public.sync_music_review_comment_count() from public;
revoke all on function public.sync_music_review_heart_count() from public;

grant execute on function public.list_review_comments(
  uuid, timestamptz, uuid, integer
) to authenticated;
grant execute on function public.get_review_engagement(uuid) to authenticated;

comment on function public.list_review_comments(
  uuid, timestamptz, uuid, integer
) is 'Keyset-paginated active comments on a review visible to the authenticated caller.';

comment on function public.get_review_engagement(uuid) is
  'Transactionally maintained heart/comment totals and the authenticated caller heart state for one visible review.';

commit;
