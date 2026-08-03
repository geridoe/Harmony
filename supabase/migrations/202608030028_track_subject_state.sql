-- A diary rating belongs to that historical listen. Current/default rating,
-- Loved, Want to listen, and undated Listened state belong to the person-track
-- relationship instead, independent of any review row.

alter table public.listening_history_entries
  add column rating numeric(2,1),
  add constraint listening_history_rating_valid check (
    rating is null
    or (rating >= 0.5 and rating <= 5.0 and mod(rating * 10, 5) = 0)
  ),
  add constraint listening_history_rating_manual_only check (
    source = 'manual' or rating is null
  );

create table public.profile_track_subject_states (
  profile_id uuid not null references public.profiles(id) on delete cascade,
  canonical_track_id uuid not null references public.canonical_tracks(id) on delete cascade,
  has_listened boolean not null default false,
  default_rating numeric(2,1),
  is_loved boolean not null default false,
  want_to_listen boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (profile_id, canonical_track_id),
  check (
    default_rating is null
    or (default_rating >= 0.5 and default_rating <= 5.0 and mod(default_rating * 10, 5) = 0)
  ),
  check (default_rating is null or has_listened)
);

create index profile_track_subject_states_profile_updated_idx
  on public.profile_track_subject_states(profile_id, updated_at desc, canonical_track_id);

create trigger profile_track_subject_states_updated_at
before update on public.profile_track_subject_states
for each row execute function public.set_updated_at();

alter table public.profile_track_subject_states enable row level security;

create policy "users view their own track subject states"
on public.profile_track_subject_states
for select to authenticated
using (profile_id = auth.uid());

revoke insert, update, delete on public.profile_track_subject_states from authenticated;

-- Existing history establishes Listened without manufacturing a rating.
insert into public.profile_track_subject_states(profile_id, canonical_track_id, has_listened)
select distinct profile_id, canonical_track_id, true
from public.listening_history_entries
where canonical_track_id is not null
on conflict (profile_id, canonical_track_id) do update
set has_listened = true,
    want_to_listen = false;

-- Preserve the current review-based experience as migration seed data. The
-- newest active track review supplies the initial default rating and Loved
-- state, but future subject-state changes are independent of review rows.
insert into public.profile_track_subject_states(
  profile_id,
  canonical_track_id,
  has_listened,
  default_rating,
  is_loved,
  want_to_listen
)
select distinct on (profile_id, canonical_track_id)
  profile_id,
  canonical_track_id,
  true,
  rating,
  is_loved,
  false
from public.music_reviews
where subject_kind = 'track'
  and canonical_track_id is not null
  and deleted_at is null
order by profile_id, canonical_track_id, updated_at desc, id desc
on conflict (profile_id, canonical_track_id) do update
set has_listened = true,
    default_rating = excluded.default_rating,
    is_loved = excluded.is_loved,
    want_to_listen = false;

create function public.sync_track_subject_state_from_history()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.canonical_track_id is null then
    return new;
  end if;

  insert into public.profile_track_subject_states(
    profile_id,
    canonical_track_id,
    has_listened,
    default_rating,
    want_to_listen
  ) values (
    new.profile_id,
    new.canonical_track_id,
    true,
    new.rating,
    false
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

create trigger listening_history_sync_track_subject_insert
after insert on public.listening_history_entries
for each row execute function public.sync_track_subject_state_from_history();

create trigger listening_history_sync_track_subject_rating
after update of rating on public.listening_history_entries
for each row
execute function public.sync_track_subject_state_from_history();

create function public.set_my_track_subject_state(
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

  return v_state;
end;
$$;

create function public.set_listening_diary_rating(
  p_entry_id uuid,
  p_rating numeric
)
returns public.listening_history_entries
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_entry public.listening_history_entries%rowtype;
begin
  if v_actor_id is null then
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

  update public.listening_history_entries
  set rating = p_rating
  where id = p_entry_id
    and profile_id = v_actor_id
    and source = 'manual'
  returning * into v_entry;

  if not found then
    raise exception 'diary entry not found' using errcode = 'P0002';
  end if;

  return v_entry;
end;
$$;

-- Extend the existing creation RPC with a trailing optional rating without
-- leaving an ambiguous PostgREST overload. Existing named-parameter callers
-- continue to work unchanged.
drop function public.record_listening_history(
  uuid,
  public.music_provider,
  text,
  timestamptz,
  public.listening_history_source,
  public.social_visibility,
  boolean,
  text[]
);

create function public.record_listening_history(
  p_canonical_track_id uuid default null,
  p_provider public.music_provider default null,
  p_provider_track_id text default null,
  p_played_at timestamptz default now(),
  p_source public.listening_history_source default 'manual',
  p_visibility public.social_visibility default 'private',
  p_is_relisten boolean default false,
  p_tags text[] default '{}'::text[],
  p_rating numeric default null
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
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if p_played_at is null then
    raise exception 'played-at date is required' using errcode = '22004';
  end if;
  if p_source = 'manual' and p_played_at > now() then
    raise exception 'played-at date cannot be in the future' using errcode = '22023';
  end if;
  if p_canonical_track_id is not null
     and not exists (select 1 from public.canonical_tracks where id = p_canonical_track_id) then
    raise exception 'canonical track not found' using errcode = 'P0002';
  end if;
  if cardinality(v_tags) > 10
     or exists (select 1 from unnest(v_tags) tag where char_length(tag) > 30) then
    raise exception 'diary entries support at most ten tags of thirty characters each'
      using errcode = '22023';
  end if;
  if p_source <> 'manual' and (
    coalesce(p_is_relisten, false)
    or cardinality(v_tags) > 0
    or p_rating is not null
  ) then
    raise exception 'relisten, tags, and rating are only available for manual history entries'
      using errcode = '22023';
  end if;
  if p_rating is not null and (
    p_rating < 0.5
    or p_rating > 5.0
    or mod(p_rating * 10, 5) <> 0
  ) then
    raise exception 'rating must be between 0.5 and 5.0 in half-star steps'
      using errcode = '22023';
  end if;

  insert into public.listening_history_entries(
    profile_id,
    canonical_track_id,
    provider,
    provider_track_id,
    played_at,
    source,
    visibility,
    is_relisten,
    tags,
    rating
  ) values (
    v_actor_id,
    p_canonical_track_id,
    p_provider,
    nullif(trim(coalesce(p_provider_track_id, '')), ''),
    p_played_at,
    p_source,
    p_visibility,
    coalesce(p_is_relisten, false),
    v_tags,
    p_rating
  )
  returning * into v_entry;

  return v_entry;
end;
$$;

revoke all on function public.sync_track_subject_state_from_history() from public;
revoke all on function public.set_my_track_subject_state(uuid, boolean, numeric, boolean, boolean) from public;
revoke all on function public.set_listening_diary_rating(uuid, numeric) from public;
revoke all on function public.record_listening_history(uuid, public.music_provider, text, timestamptz, public.listening_history_source, public.social_visibility, boolean, text[], numeric) from public;
grant execute on function public.set_my_track_subject_state(uuid, boolean, numeric, boolean, boolean) to authenticated;
grant execute on function public.set_listening_diary_rating(uuid, numeric) to authenticated;
grant execute on function public.record_listening_history(uuid, public.music_provider, text, timestamptz, public.listening_history_source, public.social_visibility, boolean, text[], numeric) to authenticated;
