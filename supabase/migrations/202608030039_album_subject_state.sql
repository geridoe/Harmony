-- Album subject state is the owner's current relationship with a canonical
-- release. It is deliberately independent of authored reviews and track-level
-- listening history: neither source seeds, updates, nor blocks this row.

create table public.profile_album_subject_states (
  profile_id uuid not null references public.profiles(id) on delete cascade,
  canonical_album_id uuid not null
    references public.canonical_albums(id) on delete cascade,
  has_listened boolean not null default false,
  default_rating numeric(2,1),
  is_loved boolean not null default false,
  want_to_listen boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (profile_id, canonical_album_id),
  constraint profile_album_state_rating_valid check (
    default_rating is null
    or (
      default_rating >= 0.5
      and default_rating <= 5.0
      and mod(default_rating * 10, 5) = 0
    )
  ),
  constraint profile_album_state_rating_requires_listened check (
    default_rating is null or has_listened
  ),
  constraint profile_album_state_want_excludes_listened check (
    not (has_listened and want_to_listen)
  ),
  constraint profile_album_state_is_not_empty check (
    has_listened
    or default_rating is not null
    or is_loved
    or want_to_listen
  )
);

create index profile_album_subject_states_profile_updated_idx
  on public.profile_album_subject_states(
    profile_id,
    updated_at desc,
    canonical_album_id desc
  );

-- The common Ratings shelf can use a bounded index page without scanning
-- Listened/Loved/Want-to-listen-only rows owned by the same profile.
create index profile_album_subject_states_profile_rated_idx
  on public.profile_album_subject_states(
    profile_id,
    updated_at desc,
    canonical_album_id desc
  )
  where default_rating is not null;

create index profile_album_subject_states_album_idx
  on public.profile_album_subject_states(canonical_album_id);

create index profile_album_subject_states_album_rating_idx
  on public.profile_album_subject_states(canonical_album_id, default_rating)
  where default_rating is not null;

create trigger profile_album_subject_states_updated_at
before update on public.profile_album_subject_states
for each row execute function public.set_updated_at();

alter table public.profile_album_subject_states enable row level security;

create policy "users view their own album subject states"
on public.profile_album_subject_states
for select to authenticated
using (profile_id = auth.uid());

-- Authenticated users have no direct write grant or write policy. The setter
-- below is the only client write authority and always derives profile_id from
-- auth.uid().
revoke insert, update, delete on public.profile_album_subject_states
from authenticated;
grant select on public.profile_album_subject_states to authenticated;

create function public.set_my_album_subject_state(
  p_canonical_album_id uuid,
  p_has_listened boolean,
  p_default_rating numeric,
  p_is_loved boolean,
  p_want_to_listen boolean
)
returns public.profile_album_subject_states
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_has_listened boolean :=
    coalesce(p_has_listened, false) or p_default_rating is not null;
  v_is_loved boolean := coalesce(p_is_loved, false);
  v_want_to_listen boolean;
  v_state public.profile_album_subject_states%rowtype;
  v_now timestamptz;
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if not exists (
    select 1
    from public.canonical_albums
    where id = p_canonical_album_id
  ) then
    raise exception 'canonical album not found' using errcode = 'P0002';
  end if;
  if p_default_rating is not null and (
    p_default_rating < 0.5
    or p_default_rating > 5.0
    or mod(p_default_rating * 10, 5) <> 0
  ) then
    raise exception 'rating must be between 0.5 and 5.0 in half-star steps'
      using errcode = '22023';
  end if;

  v_want_to_listen := case
    when v_has_listened then false
    else coalesce(p_want_to_listen, false)
  end;

  perform pg_advisory_xact_lock(hashtextextended(
    v_actor_id::text || ':album:' || p_canonical_album_id::text,
    0
  ));

  -- Clearing every relationship deletes the shelf row. Return a normalized
  -- submitted-state snapshot so clients keep the same response shape whether
  -- or not a row existed before the clear.
  if not v_has_listened
    and p_default_rating is null
    and not v_is_loved
    and not v_want_to_listen
  then
    delete from public.profile_album_subject_states
    where profile_id = v_actor_id
      and canonical_album_id = p_canonical_album_id
    returning * into v_state;

    v_now := now();
    v_state.profile_id := v_actor_id;
    v_state.canonical_album_id := p_canonical_album_id;
    v_state.has_listened := false;
    v_state.default_rating := null;
    v_state.is_loved := false;
    v_state.want_to_listen := false;
    v_state.created_at := coalesce(v_state.created_at, v_now);
    v_state.updated_at := v_now;
    return v_state;
  end if;

  insert into public.profile_album_subject_states(
    profile_id,
    canonical_album_id,
    has_listened,
    default_rating,
    is_loved,
    want_to_listen
  ) values (
    v_actor_id,
    p_canonical_album_id,
    v_has_listened,
    p_default_rating,
    v_is_loved,
    v_want_to_listen
  )
  on conflict (profile_id, canonical_album_id) do update
  set has_listened = excluded.has_listened,
      default_rating = excluded.default_rating,
      is_loved = excluded.is_loved,
      want_to_listen = excluded.want_to_listen
  returning * into v_state;

  return v_state;
end;
$$;

-- One keyset contract serves the owner shelves. Filtering happens before the
-- limit so a Ratings page is always filled with rated releases rather than a
-- sparse client-side projection of the all-state page.
create function public.list_my_album_subject_states(
  p_before_updated_at timestamptz default null,
  p_before_canonical_album_id uuid default null,
  p_limit integer default 50,
  p_scope text default 'all'
)
returns setof public.profile_album_subject_states
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_scope text := lower(btrim(coalesce(p_scope, '')));
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'album-state page size must be between 1 and 100'
      using errcode = '22023';
  end if;
  if (p_before_updated_at is null) <>
    (p_before_canonical_album_id is null)
  then
    raise exception 'album-state cursor timestamp and canonical album id must be provided together'
      using errcode = '22023';
  end if;
  if v_scope not in ('all', 'rated', 'listened', 'loved', 'want_to_listen') then
    raise exception 'album-state scope must be all, rated, listened, loved, or want_to_listen'
      using errcode = '22023';
  end if;

  return query
  select state.*
  from public.profile_album_subject_states state
  where state.profile_id = auth.uid()
    and case v_scope
      when 'rated' then state.default_rating is not null
      when 'listened' then state.has_listened
      when 'loved' then state.is_loved
      when 'want_to_listen' then state.want_to_listen
      else true
    end
    and (
      p_before_updated_at is null
      or state.updated_at < p_before_updated_at
      or (
        state.updated_at = p_before_updated_at
        and state.canonical_album_id < p_before_canonical_album_id
      )
    )
  order by state.updated_at desc, state.canonical_album_id desc
  limit p_limit;
end;
$$;

-- Album detail summarizes reviews visible to the caller. SECURITY INVOKER is
-- essential here: music_reviews RLS prevents private/followers-only opinions
-- from leaking through an otherwise anonymous count or histogram.
create function public.get_canonical_album_state_aggregate(
  p_canonical_album_id uuid
)
returns table (
  canonical_album_id uuid,
  rating_count bigint,
  average_rating numeric,
  listened_count bigint,
  loved_count bigint,
  want_to_listen_count bigint
)
language plpgsql
stable
security invoker
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if not exists (
    select 1
    from public.canonical_albums album
    where album.id = p_canonical_album_id
  ) then
    raise exception 'canonical album not found' using errcode = 'P0002';
  end if;

  return query
  select
    p_canonical_album_id,
    count(*),
    round(avg(review.rating), 2),
    count(distinct review.profile_id),
    count(*) filter (where review.is_loved),
    0::bigint
  from public.music_reviews review
  where review.subject_kind = 'album'
    and review.canonical_album_id = p_canonical_album_id
    and review.deleted_at is null;
end;
$$;

-- Always return all ten half-star buckets, including zeros, so clients can
-- render a stable histogram without manufacturing missing bins.
create function public.list_canonical_album_rating_distribution(
  p_canonical_album_id uuid
)
returns table (
  rating numeric,
  rating_count bigint
)
language plpgsql
stable
security invoker
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if not exists (
    select 1
    from public.canonical_albums album
    where album.id = p_canonical_album_id
  ) then
    raise exception 'canonical album not found' using errcode = 'P0002';
  end if;

  return query
  select
    bucket.step::numeric / 2,
    count(review.id)
  from generate_series(1, 10) as bucket(step)
  left join public.music_reviews review
    on review.subject_kind = 'album'
   and review.canonical_album_id = p_canonical_album_id
   and review.deleted_at is null
   and review.rating = bucket.step::numeric / 2
  group by bucket.step
  order by bucket.step;
end;
$$;

revoke all on function public.set_my_album_subject_state(
  uuid, boolean, numeric, boolean, boolean
) from public;
revoke all on function public.list_my_album_subject_states(
  timestamptz, uuid, integer, text
) from public;
revoke all on function public.get_canonical_album_state_aggregate(uuid)
from public;
revoke all on function public.list_canonical_album_rating_distribution(uuid)
from public;

grant execute on function public.set_my_album_subject_state(
  uuid, boolean, numeric, boolean, boolean
) to authenticated;
grant execute on function public.list_my_album_subject_states(
  timestamptz, uuid, integer, text
) to authenticated;
grant execute on function public.get_canonical_album_state_aggregate(uuid)
to authenticated;
grant execute on function public.list_canonical_album_rating_distribution(uuid)
to authenticated;
