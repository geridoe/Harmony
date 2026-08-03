-- Member profile relationship counts and lists use the same authenticated,
-- block-safe identity boundary as the rest of the profile destination. Pending
-- requests remain private relationship-management state and are never counted.

create index social_follows_accepted_followers_idx
  on public.social_follows(followed_id, follower_id)
  where state = 'accepted';

create index social_follows_accepted_following_idx
  on public.social_follows(follower_id, followed_id)
  where state = 'accepted';

-- The original two-account helper is needed by trusted functions and triggers,
-- but exposing it as an authenticated RPC permits arbitrary block-graph probes.
-- Give RLS and invoker functions an auth-bound alternative in a schema that is
-- deliberately absent from Supabase's exposed-schema list, then keep the raw
-- helper executable only by its owner. Authenticated receives only the schema
-- usage/function privileges needed while evaluating policies and invoker RPCs.
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create function private.viewer_social_account_is_blocked(p_profile_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null
     and public.social_accounts_are_blocked(auth.uid(), p_profile_id);
$$;

revoke all on function public.social_accounts_are_blocked(uuid, uuid)
  from public, anon, authenticated;
revoke all on function private.viewer_social_account_is_blocked(uuid)
  from public, anon, authenticated;
grant usage on schema private to authenticated;
grant execute on function private.viewer_social_account_is_blocked(uuid)
  to authenticated;

drop policy if exists "profiles are visible unless blocked" on public.profiles;
create policy "profiles are visible unless blocked"
on public.profiles
for select to authenticated
using (
  id = auth.uid()
  or not private.viewer_social_account_is_blocked(id)
);

drop policy if exists "recipients view unblocked social notifications"
  on public.social_notifications;
create policy "recipients view unblocked social notifications"
on public.social_notifications
for select to authenticated
using (
  recipient_id = auth.uid()
  and not private.viewer_social_account_is_blocked(actor_id)
);

drop policy if exists "view current followed social activity"
  on public.social_activity_events;
create policy "view current followed social activity"
on public.social_activity_events
for select to authenticated
using (
  not private.viewer_social_account_is_blocked(actor_id)
  and (
    actor_id = auth.uid()
    or exists (
      select 1
      from public.social_follows follow_edge
      where follow_edge.follower_id = auth.uid()
        and follow_edge.followed_id = actor_id
        and follow_edge.state = 'accepted'
    )
  )
  and (
    (
      kind = 'diary_logged'
      and exists (
        select 1
        from public.listening_history_entries entry
        where entry.id = diary_entry_id
          and entry.profile_id = actor_id
          and entry.source = 'manual'
          and entry.visibility = 'followers'
      )
    )
    or
    (
      kind = 'review_published'
      and exists (
        select 1
        from public.music_reviews review
        where review.id = review_id
          and review.profile_id = actor_id
          and review.deleted_at is null
          and review.visibility = 'followers'
      )
    )
    or
    (
      kind = 'list_published'
      and exists (
        select 1
        from public.music_lists list
        where list.id = list_id
          and list.owner_id = actor_id
          and list.deleted_at is null
          and list.visibility <> 'private'
          and public.can_view_social(list.owner_id, list.visibility)
      )
    )
  )
);

drop policy if exists "view unblocked likes of visible music lists"
  on public.music_list_likes;
create policy "view unblocked likes of visible music lists"
on public.music_list_likes
for select to authenticated
using (
  public.can_view_music_list(list_id)
  and not private.viewer_social_account_is_blocked(profile_id)
);

drop policy if exists "view unblocked comments of visible music lists"
  on public.music_list_comments;
create policy "view unblocked comments of visible music lists"
on public.music_list_comments
for select to authenticated
using (
  deleted_at is null
  and public.can_view_music_list(list_id)
  and not private.viewer_social_account_is_blocked(author_id)
);

drop policy if exists "view unblocked comments on visible reviews"
  on public.review_comments;
create policy "view unblocked comments on visible reviews"
on public.review_comments
for select to authenticated
using (
  deleted_at is null
  and public.can_view_music_review(review_id)
  and not private.viewer_social_account_is_blocked(author_id)
);

drop policy if exists "view unblocked reactions on visible reviews"
  on public.review_reactions;
create policy "view unblocked reactions on visible reviews"
on public.review_reactions
for select to authenticated
using (
  public.can_view_music_review(review_id)
  and not private.viewer_social_account_is_blocked(profile_id)
);

drop policy if exists "view unblocked comments on permitted listening broadcasts"
  on public.listening_broadcast_comments;
create policy "view unblocked comments on permitted listening broadcasts"
on public.listening_broadcast_comments
for select to authenticated
using (
  deleted_at is null
  and public.can_view_listening_broadcast(broadcast_id)
  and not private.viewer_social_account_is_blocked(author_id)
);

drop policy if exists "view unblocked reactions on permitted listening broadcasts"
  on public.listening_broadcast_reactions;
create policy "view unblocked reactions on permitted listening broadcasts"
on public.listening_broadcast_reactions
for select to authenticated
using (
  public.can_view_listening_broadcast(broadcast_id)
  and not private.viewer_social_account_is_blocked(profile_id)
);

-- Preserve account discovery while removing its dependency on the raw helper.
create or replace function public.list_social_profiles(
  p_search text default null,
  p_after_display_name text default null,
  p_after_id uuid default null,
  p_limit integer default 50
)
returns table (id uuid, display_name text)
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
    and not private.viewer_social_account_is_blocked(profile.id)
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

-- These established invoker RPCs previously called the raw two-account helper.
-- Preserve their signatures and RLS behavior while binding block checks to the
-- authenticated viewer.
create or replace function public.list_following_reviews(
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
    and not private.viewer_social_account_is_blocked(review.profile_id)
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

create or replace function public.list_review_comments(
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
    and not private.viewer_social_account_is_blocked(comment.author_id)
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

create or replace function public.list_music_list_comments(
  p_list_id uuid,
  p_before_created_at timestamptz default null,
  p_before_id uuid default null,
  p_limit integer default 50
)
returns setof public.music_list_comments
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
    raise exception 'list comment page size must be between 1 and 100'
      using errcode = '22023';
  end if;
  if (p_before_created_at is null) <> (p_before_id is null) then
    raise exception 'comment cursor timestamp and id must be provided together'
      using errcode = '22023';
  end if;
  if not public.can_view_music_list(p_list_id) then
    raise exception 'music list unavailable' using errcode = '42501';
  end if;

  return query
  select comment.*
  from public.music_list_comments comment
  where comment.list_id = p_list_id
    and comment.deleted_at is null
    and not private.viewer_social_account_is_blocked(comment.author_id)
    and (
      p_before_created_at is null
      or comment.created_at < p_before_created_at
      or (comment.created_at = p_before_created_at and comment.id < p_before_id)
    )
  order by comment.created_at desc, comment.id desc
  limit p_limit;
end;
$$;

-- Normalize exact-target follow requests to the same missing/block response as
-- member profile reads, avoiding an existence signal through error selection.
create or replace function public.request_social_follow(p_profile_id uuid)
returns public.social_follows
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_follow public.social_follows%rowtype;
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if p_profile_id is null or p_profile_id = v_actor_id then
    raise exception 'choose another profile' using errcode = '22023';
  end if;
  if not exists (select 1 from public.profiles where id = p_profile_id)
     or public.social_accounts_are_blocked(v_actor_id, p_profile_id) then
    raise exception 'profile unavailable' using errcode = '42501';
  end if;

  insert into public.social_follows(follower_id, followed_id, state)
  values (v_actor_id, p_profile_id, 'requested')
  on conflict (follower_id, followed_id)
  do update set state = public.social_follows.state
  returning * into v_follow;
  return v_follow;
end;
$$;

alter type public.member_profile_overview
  add attribute follower_count bigint;
alter type public.member_profile_overview
  add attribute following_count bigint;

create or replace function public.get_member_profile_overview(p_profile_id uuid)
returns public.member_profile_overview
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
  v_result public.member_profile_overview;
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

  select row(
    v_profile.id,
    v_profile.display_name,
    v_profile.avatar_url,
    v_profile.id = v_actor_id,
    v_viewer_follows,
    v_follows_viewer,
    v_outgoing_follow_state,
    v_incoming_follow_state,
    (
      select count(*) from public.music_reviews review
      where review.profile_id = p_profile_id
        and review.deleted_at is null
        and nullif(btrim(review.body), '') is not null
        and public.can_view_social(review.profile_id, review.visibility)
    ),
    (
      select count(*) from public.listening_history_entries entry
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
      select count(*) from public.music_lists list
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
        and not public.social_accounts_are_blocked(v_actor_id, follow_edge.follower_id)
    ),
    (
      select count(*)
      from public.social_follows follow_edge
      where follow_edge.follower_id = p_profile_id
        and follow_edge.state = 'accepted'
        and not public.social_accounts_are_blocked(v_actor_id, follow_edge.followed_id)
    )
  )::public.member_profile_overview into v_result;

  return v_result;
end;
$$;

create function public.list_member_profile_connections(
  p_profile_id uuid,
  p_direction text,
  p_after_display_name text default null,
  p_after_id uuid default null,
  p_limit integer default 50
)
returns table (
  profile_id uuid,
  display_name text,
  avatar_url text,
  outgoing_follow_state public.follow_state,
  incoming_follow_state public.follow_state
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_direction text := lower(nullif(btrim(p_direction), ''));
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if p_profile_id is null then
    raise exception 'profile id is required' using errcode = '22004';
  end if;
  if not exists (select 1 from public.profiles where profiles.id = p_profile_id)
     or public.social_accounts_are_blocked(v_actor_id, p_profile_id) then
    raise exception 'profile unavailable' using errcode = '42501';
  end if;
  if v_direction not in ('followers', 'following') then
    raise exception 'member profile connection direction must be followers or following'
      using errcode = '22023';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'member profile connection page size must be between 1 and 100'
      using errcode = '22023';
  end if;
  if (p_after_display_name is null) <> (p_after_id is null) then
    raise exception 'member profile connection cursor display name and id must be provided together'
      using errcode = '22023';
  end if;
  if p_after_display_name is not null
     and nullif(btrim(p_after_display_name), '') is null then
    raise exception 'member profile connection cursor display name must not be blank'
      using errcode = '22023';
  end if;

  return query
  with accepted_members as (
    select case
      when v_direction = 'followers' then follow_edge.follower_id
      else follow_edge.followed_id
    end as member_id
    from public.social_follows follow_edge
    where follow_edge.state = 'accepted'
      and (
        (v_direction = 'followers' and follow_edge.followed_id = p_profile_id)
        or
        (v_direction = 'following' and follow_edge.follower_id = p_profile_id)
      )
  )
  select
    member_profile.id,
    member_profile.display_name,
    member_profile.avatar_url,
    case when member_profile.id = v_actor_id then null else (
      select edge.state
      from public.social_follows edge
      where edge.follower_id = v_actor_id
        and edge.followed_id = member_profile.id
    ) end,
    case when member_profile.id = v_actor_id then null else (
      select edge.state
      from public.social_follows edge
      where edge.follower_id = member_profile.id
        and edge.followed_id = v_actor_id
    ) end
  from accepted_members accepted_member
  join public.profiles member_profile on member_profile.id = accepted_member.member_id
  where not public.social_accounts_are_blocked(v_actor_id, member_profile.id)
    and (
      p_after_display_name is null
      or lower(member_profile.display_name) > lower(p_after_display_name)
      or (
        lower(member_profile.display_name) = lower(p_after_display_name)
        and member_profile.id > p_after_id
      )
    )
  order by lower(member_profile.display_name), member_profile.id
  limit p_limit;
end;
$$;

revoke all on function public.list_member_profile_connections(
  uuid, text, text, uuid, integer
) from public, anon;
grant execute on function public.list_member_profile_connections(
  uuid, text, text, uuid, integer
) to authenticated;

comment on function private.viewer_social_account_is_blocked(uuid) is
  'Auth-bound block check for RLS and invoker functions; the raw arbitrary-pair helper is not client executable.';
comment on function public.list_member_profile_connections(
  uuid, text, text, uuid, integer
) is
  'Lists accepted Followers or Following for one available member using lower(display_name), id keyset pagination, excluding identities blocked in either direction with the viewer and returning only minimal identity plus viewer-relative states.';
