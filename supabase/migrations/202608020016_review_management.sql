create or replace function public.update_music_review(
  p_review_id uuid,
  p_rating numeric,
  p_body text,
  p_visibility public.social_visibility,
  p_contains_spoilers boolean default false
) returns public.music_reviews
language plpgsql security definer set search_path = public as $$
declare v_review public.music_reviews%rowtype;
begin
  if auth.uid() is null then raise exception 'authentication required' using errcode = '28000'; end if;
  update public.music_reviews
  set rating = p_rating,
      body = p_body,
      visibility = p_visibility,
      contains_spoilers = p_contains_spoilers
  where id = p_review_id and profile_id = auth.uid() and deleted_at is null
  returning * into v_review;
  if not found then raise exception 'review not found' using errcode = 'P0002'; end if;
  return v_review;
end;
$$;

create or replace function public.delete_music_review(p_review_id uuid)
returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'authentication required' using errcode = '28000'; end if;
  update public.music_reviews set deleted_at = now()
  where id = p_review_id and profile_id = auth.uid() and deleted_at is null;
  return found;
end;
$$;

create or replace function public.delete_review_comment(p_comment_id uuid)
returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'authentication required' using errcode = '28000'; end if;
  update public.review_comments set deleted_at = now()
  where id = p_comment_id and author_id = auth.uid() and deleted_at is null;
  return found;
end;
$$;

grant execute on function public.update_music_review(uuid, numeric, text, public.social_visibility, boolean), public.delete_music_review(uuid), public.delete_review_comment(uuid) to authenticated;
