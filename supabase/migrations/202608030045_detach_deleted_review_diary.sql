-- A soft-deleted review remains physically present, so the Diary foreign key's
-- ON DELETE SET NULL action never runs. Detach owner Diary rows explicitly in
-- the same transaction that hides the review.
create or replace function public.delete_music_review(p_review_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_deleted_review_id uuid;
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;

  update public.music_reviews
  set deleted_at = now()
  where id = p_review_id
    and profile_id = v_actor_id
    and deleted_at is null
  returning id into v_deleted_review_id;

  if not found then
    return false;
  end if;

  update public.listening_history_entries
  set review_id = null
  where review_id = v_deleted_review_id
    and profile_id = v_actor_id;

  return true;
end;
$$;

revoke all on function public.delete_music_review(uuid) from public;
grant execute on function public.delete_music_review(uuid) to authenticated;

comment on function public.delete_music_review(uuid) is
  'Soft-deletes an owner review and atomically detaches any linked owner Diary entry.';
