-- A review is an authored conversation space. The comment author may remove
-- their own contribution, and the review owner may moderate their thread.
create or replace function public.delete_review_comment(p_comment_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;

  update public.review_comments comment
  set deleted_at = now()
  where comment.id = p_comment_id
    and comment.deleted_at is null
    and (
      comment.author_id = auth.uid()
      or exists (
        select 1
        from public.music_reviews review
        where review.id = comment.review_id
          and review.profile_id = auth.uid()
          and review.deleted_at is null
      )
    );

  return found;
end;
$$;

revoke all on function public.delete_review_comment(uuid) from public;
grant execute on function public.delete_review_comment(uuid) to authenticated;

comment on function public.delete_review_comment(uuid) is
  'Soft-deletes a review comment when called by its author or the active review owner.';
