-- Keep the migration-026 update contract available to existing clients while
-- offering one transaction boundary for all editable diary fields, including
-- the migration-028 historical rating snapshot.
create function public.update_listening_diary_entry_with_rating(
  p_entry_id uuid,
  p_played_at timestamptz,
  p_visibility public.social_visibility,
  p_is_relisten boolean,
  p_tags text[],
  p_review_id uuid,
  p_rating numeric
)
returns public.listening_history_entries
language plpgsql
security definer
set search_path = public
as $$
declare
  v_entry public.listening_history_entries%rowtype;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if p_rating is not null and (
    p_rating < 0.5
    or p_rating > 5.0
    or mod(p_rating * 10, 5) <> 0
  ) then
    raise exception 'rating must be between 0.5 and 5.0 in half-star steps'
      using errcode = '22023';
  end if;

  -- This owner/manual-only function locks the entry, normalizes and validates
  -- tags/date, and enforces the owned active matching-track review invariant.
  v_entry := public.update_listening_diary_entry(
    p_entry_id,
    p_played_at,
    p_visibility,
    p_is_relisten,
    p_tags,
    p_review_id
  );

  update public.listening_history_entries
  set rating = p_rating
  where id = v_entry.id
  returning * into v_entry;

  -- Migration 028's AFTER UPDATE OF rating trigger updates the current/default
  -- track rating in this same transaction without rewriting older snapshots.
  return v_entry;
end;
$$;

revoke all on function public.update_listening_diary_entry_with_rating(uuid, timestamptz, public.social_visibility, boolean, text[], uuid, numeric) from public;
grant execute on function public.update_listening_diary_entry_with_rating(uuid, timestamptz, public.social_visibility, boolean, text[], uuid, numeric) to authenticated;
