-- Migration 059 appended attributes to a named composite return type. On the
-- hosted PostgREST path PostgreSQL attempted to coerce the complete composite
-- text representation into the first UUID attribute. Replace that fragile
-- altered-composite boundary with an explicit one-row table result, matching
-- the array-of-object contract already decoded by iOS and the smoke client.

drop function public.get_member_profile_overview(uuid);

create function public.get_member_profile_overview(p_profile_id uuid)
returns table (
  profile_id uuid,
  display_name text,
  avatar_url text,
  is_self boolean,
  viewer_follows boolean,
  follows_viewer boolean,
  outgoing_follow_state public.follow_state,
  incoming_follow_state public.follow_state,
  written_review_count bigint,
  diary_entry_count bigint,
  loved_music_count bigint,
  music_list_count bigint,
  rating_count bigint,
  average_rating numeric,
  ratings_visible boolean,
  follower_count bigint,
  following_count bigint
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_profile public.profiles%rowtype;
  v_settings public.profile_social_settings%rowtype;
  v_viewer_follows boolean;
  v_follows_viewer boolean;
  v_outgoing_follow_state public.follow_state;
  v_incoming_follow_state public.follow_state;
  v_ratings_visible boolean;
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if p_profile_id is null then
    raise exception 'profile id is required' using errcode = '22004';
  end if;

  select profile.* into v_profile
  from public.profiles profile
  where profile.id = p_profile_id;
  if not found
     or public.social_accounts_are_blocked(v_actor_id, p_profile_id) then
    raise exception 'profile unavailable' using errcode = '42501';
  end if;

  select settings.* into v_settings
  from public.profile_social_settings settings
  where settings.profile_id = p_profile_id;
  if not found then
    raise exception 'profile unavailable' using errcode = '42501';
  end if;

  select follow_edge.state into v_outgoing_follow_state
  from public.social_follows follow_edge
  where follow_edge.follower_id = v_actor_id
    and follow_edge.followed_id = p_profile_id;
  v_viewer_follows := coalesce(v_outgoing_follow_state = 'accepted', false);

  select follow_edge.state into v_incoming_follow_state
  from public.social_follows follow_edge
  where follow_edge.follower_id = p_profile_id
    and follow_edge.followed_id = v_actor_id;
  v_follows_viewer := coalesce(v_incoming_follow_state = 'accepted', false);

  v_ratings_visible := p_profile_id = v_actor_id
    or (v_settings.rating_visibility = 'followers' and v_viewer_follows);

  return query
  select
    v_profile.id,
    v_profile.display_name,
    v_profile.avatar_url,
    v_profile.id = v_actor_id,
    v_viewer_follows,
    v_follows_viewer,
    v_outgoing_follow_state,
    v_incoming_follow_state,
    (
      select count(*)
      from public.music_reviews review
      where review.profile_id = p_profile_id
        and review.deleted_at is null
        and nullif(btrim(review.body), '') is not null
        and public.can_view_social(review.profile_id, review.visibility)
    ),
    (
      select count(*)
      from public.listening_history_entries entry
      where entry.profile_id = p_profile_id
        and entry.source = 'manual'
        and public.can_view_social(entry.profile_id, entry.visibility)
    ),
    (
      select case
        when p_profile_id = v_actor_id
          or (v_settings.shelf_visibility = 'followers' and v_viewer_follows)
        then
          (select count(*) from public.profile_track_subject_states state
           where state.profile_id = p_profile_id and state.is_loved)
          +
          (select count(*) from public.profile_album_subject_states state
           where state.profile_id = p_profile_id and state.is_loved)
        else 0
      end
    ),
    (
      select count(*)
      from public.music_lists list
      where list.owner_id = p_profile_id
        and list.deleted_at is null
        and public.can_view_social(list.owner_id, list.visibility)
    ),
    case when v_ratings_visible then (
      (select count(*) from public.profile_track_subject_states state
       where state.profile_id = p_profile_id and state.default_rating is not null)
      +
      (select count(*) from public.profile_album_subject_states state
       where state.profile_id = p_profile_id and state.default_rating is not null)
    ) else 0 end,
    case when v_ratings_visible then (
      select round(avg(owner_rating.rating), 2)
      from (
        select state.default_rating as rating
        from public.profile_track_subject_states state
        where state.profile_id = p_profile_id and state.default_rating is not null
        union all
        select state.default_rating
        from public.profile_album_subject_states state
        where state.profile_id = p_profile_id and state.default_rating is not null
      ) owner_rating
    ) else null end,
    v_ratings_visible,
    (
      select count(*)
      from public.social_follows follow_edge
      where follow_edge.followed_id = p_profile_id
        and follow_edge.state = 'accepted'
        and not public.social_accounts_are_blocked(
          v_actor_id,
          follow_edge.follower_id
        )
    ),
    (
      select count(*)
      from public.social_follows follow_edge
      where follow_edge.follower_id = p_profile_id
        and follow_edge.state = 'accepted'
        and not public.social_accounts_are_blocked(
          v_actor_id,
          follow_edge.followed_id
        )
    );
end;
$$;

revoke all on function public.get_member_profile_overview(uuid)
  from public, anon;
grant execute on function public.get_member_profile_overview(uuid)
  to authenticated;

comment on function public.get_member_profile_overview(uuid) is
  'Returns exactly one explicit table row for an authenticated, block-safe member profile summary; missing and either-direction blocked targets share the same unavailable error.';

-- The function changes from a named-composite result to explicit OUT columns,
-- so ask hosted PostgREST to discard its cached function descriptor promptly.
notify pgrst, 'reload schema';
