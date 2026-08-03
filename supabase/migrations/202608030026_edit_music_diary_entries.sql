-- A diary entry may point at the owner's track review for the same listen.
-- The relationship is optional and does not alter history/review read policy.
alter table public.listening_history_entries
  add column review_id uuid references public.music_reviews(id) on delete set null,
  add constraint listening_history_review_manual_only check (
    source = 'manual' or review_id is null
  );

create index listening_history_review_idx
  on public.listening_history_entries(review_id)
  where review_id is not null;

create function public.update_listening_diary_entry(
  p_entry_id uuid,
  p_played_at timestamptz,
  p_visibility public.social_visibility,
  p_is_relisten boolean,
  p_tags text[],
  p_review_id uuid default null
)
returns public.listening_history_entries
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_tags text[] := public.normalize_music_diary_tags(p_tags);
  v_entry public.listening_history_entries%rowtype;
  v_review public.music_reviews%rowtype;
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if p_played_at is null then
    raise exception 'played-at date is required' using errcode = '22004';
  end if;
  if p_played_at > now() then
    raise exception 'played-at date cannot be in the future' using errcode = '22023';
  end if;
  if cardinality(v_tags) > 10
     or exists (select 1 from unnest(v_tags) tag where char_length(tag) > 30) then
    raise exception 'diary entries support at most ten tags of thirty characters each'
      using errcode = '22023';
  end if;

  select * into v_entry
  from public.listening_history_entries
  where id = p_entry_id
    and profile_id = v_actor_id
    and source = 'manual'
  for update;

  if not found then
    raise exception 'diary entry not found' using errcode = 'P0002';
  end if;

  if p_review_id is not null then
    select * into v_review
    from public.music_reviews
    where id = p_review_id
      and profile_id = v_actor_id
      and deleted_at is null
      and subject_kind = 'track'
    for share;

    if not found then
      raise exception 'owned active track review not found' using errcode = 'P0002';
    end if;

    -- Prefer the canonical identity. A legacy row without one may use a full
    -- provider identity fallback, but an unverifiable link is never accepted.
    if not (
      (v_entry.canonical_track_id is not null
        and v_entry.canonical_track_id = v_review.canonical_track_id)
      or
      (v_entry.canonical_track_id is null
        and v_entry.provider is not null
        and v_entry.provider_track_id is not null
        and v_review.provider = v_entry.provider
        and v_review.provider_subject_id = v_entry.provider_track_id)
    ) then
      raise exception 'review subject does not match diary track' using errcode = '22023';
    end if;
  end if;

  update public.listening_history_entries
  set played_at = p_played_at,
      visibility = p_visibility,
      is_relisten = coalesce(p_is_relisten, false),
      tags = v_tags,
      review_id = p_review_id
  where id = v_entry.id
  returning * into v_entry;

  return v_entry;
end;
$$;

revoke all on function public.update_listening_diary_entry(uuid, timestamptz, public.social_visibility, boolean, text[], uuid) from public;
grant execute on function public.update_listening_diary_entry(uuid, timestamptz, public.social_visibility, boolean, text[], uuid) to authenticated;
