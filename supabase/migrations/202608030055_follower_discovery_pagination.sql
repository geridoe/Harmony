-- Account discovery is intentionally separate from content publication.
-- Finding an account never grants access to that account's listening activity,
-- history, reviews, shelves, lists, or live broadcasts.

create index profiles_discovery_name_id_idx
  on public.profiles ((lower(display_name)), id);

create function public.list_social_profiles(
  p_search text default null,
  p_after_display_name text default null,
  p_after_id uuid default null,
  p_limit integer default 50
)
returns table (
  id uuid,
  display_name text
)
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_search text := nullif(btrim(p_search), '');
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'profile page size must be between 1 and 100'
      using errcode = '22023';
  end if;
  if (p_after_display_name is null) <> (p_after_id is null) then
    raise exception 'profile cursor display name and id must be provided together'
      using errcode = '22023';
  end if;
  if p_after_display_name is not null
      and nullif(btrim(p_after_display_name), '') is null then
    raise exception 'profile cursor display name must not be blank'
      using errcode = '22023';
  end if;

  return query
  select profile.id, profile.display_name
  from public.profiles profile
  where profile.id <> v_actor_id
    and not public.social_accounts_are_blocked(v_actor_id, profile.id)
    and (
      v_search is null
      or strpos(lower(profile.display_name), lower(v_search)) > 0
    )
    and (
      p_after_display_name is null
      or lower(profile.display_name) > lower(p_after_display_name)
      or (
        lower(profile.display_name) = lower(p_after_display_name)
        and profile.id > p_after_id
      )
    )
  order by lower(profile.display_name), profile.id
  limit p_limit;
end;
$$;

revoke all on function public.list_social_profiles(
  text, text, uuid, integer
) from public;
grant execute on function public.list_social_profiles(
  text, text, uuid, integer
) to authenticated;

comment on function public.list_social_profiles(
  text, text, uuid, integer
) is 'Lists discoverable, unblocked accounts using lower(display_name), id keyset pagination. This does not grant visibility to social content.';

-- A blocked profile is intentionally hidden by the normal profiles RLS policy.
-- This narrow definer projection lets a caller manage only blocks they created;
-- it cannot reveal accounts that blocked the caller.
create function public.list_my_blocked_profiles()
returns table (
  id uuid,
  display_name text
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;

  return query
  select profile.id, profile.display_name
  from public.profile_blocks block_edge
  join public.profiles profile on profile.id = block_edge.blocked_id
  where block_edge.blocker_id = v_actor_id
  order by lower(profile.display_name), profile.id;
end;
$$;

revoke all on function public.list_my_blocked_profiles() from public;
grant execute on function public.list_my_blocked_profiles() to authenticated;

comment on function public.list_my_blocked_profiles()
is 'Returns account identity only for blocks created by the authenticated caller, for Manage blocked UI; never reveals accounts that blocked the caller.';
