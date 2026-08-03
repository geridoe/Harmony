-- Personal journal browsing is separate from the recent follower-history feed.
-- A stable two-part cursor prevents duplicates or gaps when multiple listens
-- share a timestamp, and the auth-bound predicate makes the result exhaustive
-- for the caller rather than dependent on other visible social activity.
create index listening_history_manual_journal_idx
  on public.listening_history_entries(profile_id, played_at desc, id desc)
  where source = 'manual';

create function public.list_my_listening_diary(
  p_before_played_at timestamptz default null,
  p_before_id uuid default null,
  p_limit integer default 50
)
returns setof public.listening_history_entries
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
    raise exception 'journal page size must be between 1 and 100' using errcode = '22023';
  end if;
  if (p_before_played_at is null) <> (p_before_id is null) then
    raise exception 'journal cursor timestamp and id must be provided together'
      using errcode = '22023';
  end if;

  return query
  select entry.*
  from public.listening_history_entries entry
  where entry.profile_id = auth.uid()
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

revoke all on function public.list_my_listening_diary(timestamptz, uuid, integer) from public;
grant execute on function public.list_my_listening_diary(timestamptz, uuid, integer) to authenticated;
