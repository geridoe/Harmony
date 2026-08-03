-- A subject-state row represents at least one intentional relationship with a
-- track. Clearing every flag should remove it from the owner Music shelf
-- instead of leaving an empty, permanently visible row.

create or replace function public.set_my_track_subject_state(
  p_canonical_track_id uuid,
  p_has_listened boolean,
  p_default_rating numeric,
  p_is_loved boolean,
  p_want_to_listen boolean
)
returns public.profile_track_subject_states
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_has_listened boolean := coalesce(p_has_listened, false) or p_default_rating is not null;
  v_state public.profile_track_subject_states%rowtype;
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if not exists (select 1 from public.canonical_tracks where id = p_canonical_track_id) then
    raise exception 'canonical track not found' using errcode = 'P0002';
  end if;
  if p_default_rating is not null and (
    p_default_rating < 0.5
    or p_default_rating > 5.0
    or mod(p_default_rating * 10, 5) <> 0
  ) then
    raise exception 'rating must be between 0.5 and 5.0 in half-star steps'
      using errcode = '22023';
  end if;
  if not v_has_listened and (
    exists (
      select 1 from public.listening_history_entries
      where profile_id = v_actor_id and canonical_track_id = p_canonical_track_id
    )
    or exists (
      select 1 from public.music_reviews
      where profile_id = v_actor_id
        and canonical_track_id = p_canonical_track_id
        and subject_kind = 'track'
        and deleted_at is null
    )
  ) then
    raise exception 'remove diary entries and active reviews before clearing Listened'
      using errcode = '22023';
  end if;

  insert into public.profile_track_subject_states(
    profile_id,
    canonical_track_id,
    has_listened,
    default_rating,
    is_loved,
    want_to_listen
  ) values (
    v_actor_id,
    p_canonical_track_id,
    v_has_listened,
    p_default_rating,
    coalesce(p_is_loved, false),
    case when v_has_listened then false else coalesce(p_want_to_listen, false) end
  )
  on conflict (profile_id, canonical_track_id) do update
  set has_listened = excluded.has_listened,
      default_rating = excluded.default_rating,
      is_loved = excluded.is_loved,
      want_to_listen = excluded.want_to_listen
  returning * into v_state;

  if not v_state.has_listened
    and v_state.default_rating is null
    and not v_state.is_loved
    and not v_state.want_to_listen
  then
    delete from public.profile_track_subject_states
    where profile_id = v_actor_id
      and canonical_track_id = p_canonical_track_id;
  end if;

  -- Return the submitted state even when it was removed. Existing clients keep
  -- their response shape; subsequent reads correctly omit the empty shelf row.
  return v_state;
end;
$$;

revoke all on function public.set_my_track_subject_state(uuid, boolean, numeric, boolean, boolean) from public;
grant execute on function public.set_my_track_subject_state(uuid, boolean, numeric, boolean, boolean) to authenticated;
