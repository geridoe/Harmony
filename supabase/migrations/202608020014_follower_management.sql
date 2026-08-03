-- Give each relationship action one precise meaning. An unfollow must not also
-- remove an incoming follower, while blocking intentionally removes both edges.
create or replace function public.remove_social_follow(p_profile_id uuid)
returns boolean
language plpgsql security definer set search_path = public as $$
declare v_actor_id uuid := auth.uid();
begin
  if v_actor_id is null then raise exception 'authentication required' using errcode = '28000'; end if;
  delete from public.social_follows
  where follower_id = v_actor_id and followed_id = p_profile_id;
  return found;
end;
$$;

create or replace function public.remove_social_follower(p_profile_id uuid)
returns boolean
language plpgsql security definer set search_path = public as $$
declare v_actor_id uuid := auth.uid();
begin
  if v_actor_id is null then raise exception 'authentication required' using errcode = '28000'; end if;
  delete from public.social_follows
  where follower_id = p_profile_id and followed_id = v_actor_id;
  return found;
end;
$$;

create or replace function public.unblock_social_profile(p_profile_id uuid)
returns boolean
language plpgsql security definer set search_path = public as $$
declare v_actor_id uuid := auth.uid();
begin
  if v_actor_id is null then raise exception 'authentication required' using errcode = '28000'; end if;
  delete from public.profile_blocks
  where blocker_id = v_actor_id and blocked_id = p_profile_id;
  return found;
end;
$$;

revoke all on function public.remove_social_follower(uuid), public.unblock_social_profile(uuid) from public;
grant execute on function public.remove_social_follower(uuid), public.unblock_social_profile(uuid) to authenticated;
