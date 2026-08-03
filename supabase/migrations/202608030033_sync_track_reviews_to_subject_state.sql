-- A track review is an authored expression of the listener's current track
-- relationship. Match the product model used by Letterboxd: saving a rating
-- or Like with a review updates current/default state, while historical Diary
-- entry ratings remain unchanged. Album reviews have no canonical track state.

create function public.sync_track_subject_state_from_review()
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

  insert into public.profile_track_subject_states(
    profile_id,
    canonical_track_id,
    has_listened,
    default_rating,
    is_loved,
    want_to_listen
  ) values (
    new.profile_id,
    new.canonical_track_id,
    true,
    new.rating,
    new.is_loved,
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

create trigger music_reviews_sync_track_subject_insert
after insert on public.music_reviews
for each row execute function public.sync_track_subject_state_from_review();

create trigger music_reviews_sync_track_subject_update
after update of rating, is_loved, deleted_at on public.music_reviews
for each row execute function public.sync_track_subject_state_from_review();

revoke all on function public.sync_track_subject_state_from_review() from public;
