-- The private Listened/Ratings/Loved/Want-to-listen shelf uses stable keyset
-- pagination, independent of social activity volume.
drop index public.profile_track_subject_states_profile_updated_idx;

create index profile_track_subject_states_profile_updated_idx
  on public.profile_track_subject_states(
    profile_id,
    updated_at desc,
    canonical_track_id desc
  );

create function public.list_my_track_subject_states(
  p_before_updated_at timestamptz default null,
  p_before_canonical_track_id uuid default null,
  p_limit integer default 50
)
returns setof public.profile_track_subject_states
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
    raise exception 'track-state page size must be between 1 and 100'
      using errcode = '22023';
  end if;
  if (p_before_updated_at is null) <> (p_before_canonical_track_id is null) then
    raise exception 'track-state cursor timestamp and canonical track id must be provided together'
      using errcode = '22023';
  end if;

  return query
  select state.*
  from public.profile_track_subject_states state
  where state.profile_id = auth.uid()
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

revoke all on function public.list_my_track_subject_states(timestamptz, uuid, integer) from public;
grant execute on function public.list_my_track_subject_states(timestamptz, uuid, integer) to authenticated;
