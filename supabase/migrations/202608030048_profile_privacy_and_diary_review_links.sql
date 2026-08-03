-- Public Diary rows may link to a more-private review. Keep that relationship
-- available to its owner, but never expose the raw foreign key through the
-- table API or a profile/activity RPC unless the caller can view the review.

-- Table-level SELECT implicitly grants every column, so replace it with an
-- explicit allow-list that excludes review_id. RLS still decides which rows a
-- caller may read. Trusted RPCs below are the only client-facing link surface.
revoke select on public.listening_history_entries from public, anon, authenticated;
grant select (
  id,
  profile_id,
  canonical_track_id,
  provider,
  provider_track_id,
  played_at,
  source,
  visibility,
  created_at,
  is_relisten,
  tags,
  rating
) on public.listening_history_entries to authenticated;

-- Profiles are discoverable to signed-in people, except across a block. An
-- owner always retains access to their own profile.
drop policy if exists "profiles are visible to signed-in users" on public.profiles;
create policy "profiles are visible unless blocked"
on public.profiles
for select to authenticated
using (
  id = auth.uid()
  or not public.social_accounts_are_blocked(auth.uid(), id)
);

-- The owner RPC must be SECURITY DEFINER now that direct clients cannot select
-- review_id. Its explicit owner predicate is the authorization boundary.
create or replace function public.list_my_listening_diary(
  p_before_played_at timestamptz default null,
  p_before_id uuid default null,
  p_limit integer default 50
)
returns setof public.listening_history_entries
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
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'journal page size must be between 1 and 100' using errcode = '22023';
  end if;
  if (p_before_played_at is null) <> (p_before_id is null) then
    raise exception 'journal cursor timestamp and id must be provided together'
      using errcode = '22023';
  end if;

  return query
  select entry.*
  from public.listening_history_entries entry
  where entry.profile_id = v_actor_id
    and entry.source = 'manual'
    and (
      p_before_played_at is null
      or entry.played_at < p_before_played_at
      or (entry.played_at = p_before_played_at and entry.id < p_before_id)
    )
  order by entry.played_at desc, entry.id desc
  limit p_limit;
end;
$$;

-- Preserve the existing table-composite return contract so PostgREST resource
-- embedding and the Swift decoder remain unchanged. Only review_id is redacted.
create or replace function public.list_profile_listening_diary(
  p_profile_id uuid,
  p_before_played_at timestamptz default null,
  p_before_id uuid default null,
  p_limit integer default 50
)
returns setof public.listening_history_entries
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
  if p_profile_id is null then
    raise exception 'profile id is required' using errcode = '22004';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'profile diary page size must be between 1 and 100' using errcode = '22023';
  end if;
  if (p_before_played_at is null) <> (p_before_id is null) then
    raise exception 'profile diary cursor timestamp and id must be provided together'
      using errcode = '22023';
  end if;

  return query
  select row(
    entry.id,
    entry.profile_id,
    entry.canonical_track_id,
    entry.provider,
    entry.provider_track_id,
    entry.played_at,
    entry.source,
    entry.visibility,
    entry.created_at,
    entry.is_relisten,
    entry.tags,
    case
      when entry.review_id is null or public.can_view_music_review(entry.review_id)
        then entry.review_id
      else null
    end,
    entry.rating
  )::public.listening_history_entries
  from public.listening_history_entries entry
  where entry.profile_id = p_profile_id
    and entry.source = 'manual'
    and public.can_view_social(entry.profile_id, entry.visibility)
    and (
      p_before_played_at is null
      or entry.played_at < p_before_played_at
      or (entry.played_at = p_before_played_at and entry.id < p_before_id)
    )
  order by entry.played_at desc, entry.id desc
  limit p_limit;
end;
$$;

-- Following Activity hydrates Diary event IDs in one bounded call. This avoids
-- the raw table link and applies the same visibility/redaction contract as the
-- profile Diary page.
create function public.list_visible_listening_diary_entries(
  p_entry_ids uuid[]
)
returns setof public.listening_history_entries
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
  if p_entry_ids is null
     or cardinality(p_entry_ids) > 100
     or array_position(p_entry_ids, null) is not null then
    raise exception 'Diary entry ids must contain at most one hundred nonnull ids'
      using errcode = '22023';
  end if;

  return query
  select row(
    entry.id,
    entry.profile_id,
    entry.canonical_track_id,
    entry.provider,
    entry.provider_track_id,
    entry.played_at,
    entry.source,
    entry.visibility,
    entry.created_at,
    entry.is_relisten,
    entry.tags,
    case
      when entry.review_id is null or public.can_view_music_review(entry.review_id)
        then entry.review_id
      else null
    end,
    entry.rating
  )::public.listening_history_entries
  from public.listening_history_entries entry
  where entry.id = any(p_entry_ids)
    and entry.source = 'manual'
    and public.can_view_social(entry.profile_id, entry.visibility)
  order by array_position(p_entry_ids, entry.id);
end;
$$;

-- Profile pages should honor the record's explicit visibility. The previous
-- extra follower-only gate made a `public` review invisible to nonfollowers.
create or replace function public.list_profile_music_reviews(
  p_profile_id uuid,
  p_before_created_at timestamptz default null,
  p_before_id uuid default null,
  p_limit integer default 50
)
returns setof public.music_reviews
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
  if p_profile_id is null then
    raise exception 'profile id is required' using errcode = '22004';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'profile review page size must be between 1 and 100' using errcode = '22023';
  end if;
  if (p_before_created_at is null) <> (p_before_id is null) then
    raise exception 'profile review cursor timestamp and id must be provided together'
      using errcode = '22023';
  end if;

  return query
  select review.*
  from public.music_reviews review
  where review.profile_id = p_profile_id
    and review.deleted_at is null
    and public.can_view_social(review.profile_id, review.visibility)
    and (
      p_before_created_at is null
      or review.created_at < p_before_created_at
      or (review.created_at = p_before_created_at and review.id < p_before_id)
    )
  order by review.created_at desc, review.id desc
  limit p_limit;
end;
$$;

-- A public Loved shelf must not return the owner's private subject-state flags
-- merely because the Swift client normally projects three columns. Make the
-- RPC itself narrow so every caller, including raw REST clients, gets only the
-- public shelf identity and cursor.
drop function public.list_profile_loved_tracks(uuid, timestamptz, uuid, integer);

create type public.public_loved_track as (
  profile_id uuid,
  canonical_track_id uuid,
  updated_at timestamptz,
  canonical_track jsonb
);

create function public.list_profile_loved_tracks(
  p_profile_id uuid,
  p_before_updated_at timestamptz default null,
  p_before_canonical_track_id uuid default null,
  p_limit integer default 50
)
returns setof public.public_loved_track
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
  if p_profile_id is null then
    raise exception 'profile id is required' using errcode = '22004';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'Loved page size must be between 1 and 100' using errcode = '22023';
  end if;
  if (p_before_updated_at is null) <> (p_before_canonical_track_id is null) then
    raise exception 'Loved cursor timestamp and canonical track id must be provided together'
      using errcode = '22023';
  end if;

  return query
  select row(
    state.profile_id,
    state.canonical_track_id,
    state.updated_at,
    jsonb_build_object(
      'id', track.id,
      'title', track.title,
      'artist', track.artist,
      'album', track.album,
      'duration_ms', track.duration_ms,
      'artwork_url', track.artwork_url,
      'is_explicit', track.is_explicit
    )
  )::public.public_loved_track
  from public.profile_track_subject_states state
  join public.profile_social_settings settings on settings.profile_id = state.profile_id
  join public.canonical_tracks track on track.id = state.canonical_track_id
  where state.profile_id = p_profile_id
    and state.is_loved
    and (
      state.profile_id = v_actor_id
      or (
        settings.shelf_visibility = 'followers'
        and not public.social_accounts_are_blocked(v_actor_id, state.profile_id)
        and exists (
          select 1
          from public.social_follows follow
          where follow.follower_id = v_actor_id
            and follow.followed_id = state.profile_id
            and follow.state = 'accepted'
        )
      )
    )
    and (
      p_before_updated_at is null
      or state.updated_at < p_before_updated_at
      or (
        state.updated_at = p_before_updated_at
        and state.canonical_track_id < p_before_canonical_track_id
      )
    )
  order by state.updated_at desc, state.canonical_track_id desc
  limit p_limit;
end;
$$;

revoke all on function public.list_visible_listening_diary_entries(uuid[]) from public;
grant execute on function public.list_visible_listening_diary_entries(uuid[]) to authenticated;

-- Reassert the established RPC grants after replacement.
revoke all on function public.list_my_listening_diary(timestamptz, uuid, integer) from public;
revoke all on function public.list_profile_listening_diary(uuid, timestamptz, uuid, integer) from public;
revoke all on function public.list_profile_music_reviews(uuid, timestamptz, uuid, integer) from public;
grant execute on function public.list_my_listening_diary(timestamptz, uuid, integer) to authenticated;
grant execute on function public.list_profile_listening_diary(uuid, timestamptz, uuid, integer) to authenticated;
grant execute on function public.list_profile_music_reviews(uuid, timestamptz, uuid, integer) to authenticated;
revoke all on function public.list_profile_loved_tracks(uuid, timestamptz, uuid, integer) from public;
grant execute on function public.list_profile_loved_tracks(uuid, timestamptz, uuid, integer) to authenticated;

-- Realtime reads WAL rows outside the normal REST projection. Publish only the
-- same safe Diary columns so review_id cannot appear even as a null-valued key
-- in a follower's change payload.
alter publication supabase_realtime drop table public.listening_history_entries;
alter publication supabase_realtime add table public.listening_history_entries (
  id,
  profile_id,
  canonical_track_id,
  provider,
  provider_track_id,
  played_at,
  source,
  visibility,
  created_at,
  is_relisten,
  tags,
  rating
);
