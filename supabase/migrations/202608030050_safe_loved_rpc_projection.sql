-- Migration 048 narrowed the public Loved shelf correctly, but wrapped the
-- composite in one SELECT column. A SETOF composite function must return its
-- attributes as separate columns for PostgREST to project them.
create or replace function public.list_profile_loved_tracks(
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
  select
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

revoke all on function public.list_profile_loved_tracks(
  uuid, timestamptz, uuid, integer
) from public;
grant execute on function public.list_profile_loved_tracks(
  uuid, timestamptz, uuid, integer
) to authenticated;
