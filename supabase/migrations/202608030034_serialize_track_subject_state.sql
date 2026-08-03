-- Remove legacy no-op rows created before migration 032 and serialize every
-- writer that establishes or clears the owner/track relationship. Without a
-- shared advisory lock, a concurrent history/review insert could race the
-- clear-time blocker check.

delete from public.profile_track_subject_states
where not has_listened
  and default_rating is null
  and not is_loved
  and not want_to_listen;

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

  perform pg_advisory_xact_lock(
    hashtextextended(v_actor_id::text || ':' || p_canonical_track_id::text, 0)
  );

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
    raise exception 'Listened cannot be cleared while this track has Diary/history entries or an active review.'
      using errcode = '22023', detail = 'track_subject_listened_is_required';
  end if;

  insert into public.profile_track_subject_states(
    profile_id, canonical_track_id, has_listened, default_rating, is_loved,
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

  return v_state;
end;
$$;

create or replace function public.sync_track_subject_state_from_history()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.canonical_track_id is null then
    return new;
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(new.profile_id::text || ':' || new.canonical_track_id::text, 0)
  );

  insert into public.profile_track_subject_states(
    profile_id, canonical_track_id, has_listened, default_rating,
    want_to_listen
  ) values (
    new.profile_id, new.canonical_track_id, true, new.rating, false
  )
  on conflict (profile_id, canonical_track_id) do update
  set has_listened = true,
      default_rating = case
        when tg_op = 'UPDATE' then new.rating
        else coalesce(new.rating, public.profile_track_subject_states.default_rating)
      end,
      want_to_listen = false;

  return new;
end;
$$;

create or replace function public.sync_track_subject_state_from_review()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.subject_kind <> 'track'
    or new.canonical_track_id is null
    or new.deleted_at is not null
  then
    return new;
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(new.profile_id::text || ':' || new.canonical_track_id::text, 0)
  );

  insert into public.profile_track_subject_states(
    profile_id, canonical_track_id, has_listened, default_rating, is_loved,
    want_to_listen
  ) values (
    new.profile_id, new.canonical_track_id, true, new.rating, new.is_loved,
    false
  )
  on conflict (profile_id, canonical_track_id) do update
  set has_listened = true,
      default_rating = excluded.default_rating,
      is_loved = excluded.is_loved,
      want_to_listen = false;

  return new;
end;
$$;

revoke all on function public.set_my_track_subject_state(uuid, boolean, numeric, boolean, boolean) from public;
grant execute on function public.set_my_track_subject_state(uuid, boolean, numeric, boolean, boolean) to authenticated;
revoke all on function public.sync_track_subject_state_from_history() from public;
revoke all on function public.sync_track_subject_state_from_review() from public;
