-- A member profile is an authenticated social destination, not a shortcut
-- around the visibility rules of each underlying object. Counts below are
-- calculated from the viewer-visible rows, and current ratings get their own
-- explicit consent because track/album subject-state tables are owner-only.

alter table public.profile_social_settings
  add column rating_visibility public.social_visibility not null default 'private',
  add constraint profile_social_settings_rating_visibility_nonpublic check (
    rating_visibility in ('private', 'followers')
  );

create index profile_track_subject_states_profile_rated_idx
  on public.profile_track_subject_states(
    profile_id,
    updated_at desc,
    canonical_track_id desc
  )
  where default_rating is not null;

create index profile_album_subject_states_profile_loved_idx
  on public.profile_album_subject_states(
    profile_id,
    updated_at desc,
    canonical_album_id desc
  )
  where is_loved;

create type public.member_profile_overview as (
  profile_id uuid,
  display_name text,
  avatar_url text,
  is_self boolean,
  viewer_follows boolean,
  follows_viewer boolean,
  outgoing_follow_state public.follow_state,
  incoming_follow_state public.follow_state,
  written_review_count bigint,
  diary_entry_count bigint,
  loved_music_count bigint,
  music_list_count bigint,
  rating_count bigint,
  average_rating numeric,
  ratings_visible boolean
);

revoke all on type public.member_profile_overview from public;
grant usage on type public.member_profile_overview to authenticated;

create function public.get_member_profile_overview(
  p_profile_id uuid
)
returns public.member_profile_overview
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_profile public.profiles%rowtype;
  v_settings public.profile_social_settings%rowtype;
  v_viewer_follows boolean;
  v_follows_viewer boolean;
  v_outgoing_follow_state public.follow_state;
  v_incoming_follow_state public.follow_state;
  v_ratings_visible boolean;
  v_result public.member_profile_overview;
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if p_profile_id is null then
    raise exception 'profile id is required' using errcode = '22004';
  end if;

  select profile.* into v_profile
  from public.profiles profile
  where profile.id = p_profile_id;
  if not found
     or public.social_accounts_are_blocked(v_actor_id, p_profile_id) then
    raise exception 'profile unavailable' using errcode = '42501';
  end if;

  select settings.* into v_settings
  from public.profile_social_settings settings
  where settings.profile_id = p_profile_id;
  if not found then
    raise exception 'profile unavailable' using errcode = '42501';
  end if;

  select follow_edge.state
  into v_outgoing_follow_state
  from public.social_follows follow_edge
  where follow_edge.follower_id = v_actor_id
    and follow_edge.followed_id = p_profile_id;
  v_viewer_follows := coalesce(v_outgoing_follow_state = 'accepted', false);

  select follow_edge.state
  into v_incoming_follow_state
  from public.social_follows follow_edge
  where follow_edge.follower_id = p_profile_id
    and follow_edge.followed_id = v_actor_id;
  v_follows_viewer := coalesce(v_incoming_follow_state = 'accepted', false);

  v_ratings_visible := p_profile_id = v_actor_id
    or (
      v_settings.rating_visibility = 'followers'
      and v_viewer_follows
    );

  select row(
    v_profile.id,
    v_profile.display_name,
    v_profile.avatar_url,
    v_profile.id = v_actor_id,
    v_viewer_follows,
    v_follows_viewer,
    v_outgoing_follow_state,
    v_incoming_follow_state,
    (
      select count(*)
      from public.music_reviews review
      where review.profile_id = p_profile_id
        and review.deleted_at is null
        and nullif(btrim(review.body), '') is not null
        and public.can_view_social(review.profile_id, review.visibility)
    ),
    (
      select count(*)
      from public.listening_history_entries entry
      where entry.profile_id = p_profile_id
        and entry.source = 'manual'
        and public.can_view_social(entry.profile_id, entry.visibility)
    ),
    (
      select case
        when p_profile_id = v_actor_id
          or (v_settings.shelf_visibility = 'followers' and v_viewer_follows)
        then
          (select count(*) from public.profile_track_subject_states state
           where state.profile_id = p_profile_id and state.is_loved)
          +
          (select count(*) from public.profile_album_subject_states state
           where state.profile_id = p_profile_id and state.is_loved)
        else 0
      end
    ),
    (
      select count(*)
      from public.music_lists list
      where list.owner_id = p_profile_id
        and list.deleted_at is null
        and public.can_view_social(list.owner_id, list.visibility)
    ),
    case when v_ratings_visible then (
      (select count(*)
       from public.profile_track_subject_states state
       where state.profile_id = p_profile_id
         and state.default_rating is not null)
      +
      (select count(*)
       from public.profile_album_subject_states state
       where state.profile_id = p_profile_id
         and state.default_rating is not null)
    ) else 0 end,
    case when v_ratings_visible then (
      select round(avg(owner_rating.rating), 2)
      from (
        select state.default_rating as rating
        from public.profile_track_subject_states state
        where state.profile_id = p_profile_id
          and state.default_rating is not null
        union all
        select state.default_rating
        from public.profile_album_subject_states state
        where state.profile_id = p_profile_id
          and state.default_rating is not null
      ) owner_rating
    ) else null end,
    v_ratings_visible
  )::public.member_profile_overview into v_result;

  return v_result;
end;
$$;

create type public.public_profile_rating as (
  profile_id uuid,
  subject_kind public.review_subject_kind,
  subject_id uuid,
  rating numeric,
  updated_at timestamptz,
  subject jsonb
);

revoke all on type public.public_profile_rating from public;
grant usage on type public.public_profile_rating to authenticated;

create function public.list_profile_ratings(
  p_profile_id uuid,
  p_subject_kind text default null,
  p_before_updated_at timestamptz default null,
  p_before_subject_kind text default null,
  p_before_subject_id uuid default null,
  p_limit integer default 50
)
returns setof public.public_profile_rating
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_scope text := lower(coalesce(nullif(btrim(p_subject_kind), ''), 'all'));
  v_cursor_kind text := lower(nullif(btrim(p_before_subject_kind), ''));
  v_settings public.profile_social_settings%rowtype;
  v_viewer_follows boolean;
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if p_profile_id is null then
    raise exception 'profile id is required' using errcode = '22004';
  end if;
  if not exists (select 1 from public.profiles where id = p_profile_id)
     or public.social_accounts_are_blocked(v_actor_id, p_profile_id) then
    raise exception 'profile unavailable' using errcode = '42501';
  end if;
  if v_scope not in ('all', 'track', 'album') then
    raise exception 'profile rating subject kind must be all, track, or album'
      using errcode = '22023';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'profile rating page size must be between 1 and 100'
      using errcode = '22023';
  end if;
  if num_nonnulls(
    p_before_updated_at,
    p_before_subject_kind,
    p_before_subject_id
  ) not in (0, 3) then
    raise exception 'profile rating cursor timestamp, subject kind, and subject id must be provided together'
      using errcode = '22023';
  end if;
  if p_before_updated_at is not null and v_cursor_kind not in ('track', 'album') then
    raise exception 'profile rating cursor subject kind must be track or album'
      using errcode = '22023';
  end if;
  if p_before_updated_at is not null
     and v_scope <> 'all'
     and v_cursor_kind <> v_scope then
    raise exception 'profile rating cursor subject kind must match the requested scope'
      using errcode = '22023';
  end if;

  select settings.* into v_settings
  from public.profile_social_settings settings
  where settings.profile_id = p_profile_id;
  if not found then
    raise exception 'profile unavailable' using errcode = '42501';
  end if;

  select exists (
    select 1
    from public.social_follows follow_edge
    where follow_edge.follower_id = v_actor_id
      and follow_edge.followed_id = p_profile_id
      and follow_edge.state = 'accepted'
  ) into v_viewer_follows;

  -- A private Ratings shelf is represented by an empty authorized page. This
  -- does not leak how many owner-only subject-state rows exist.
  if p_profile_id <> v_actor_id and not (
    v_settings.rating_visibility = 'followers' and v_viewer_follows
  ) then
    return;
  end if;

  return query
  with rating_rows as (
    select
      state.profile_id,
      'track'::public.review_subject_kind as subject_kind,
      state.canonical_track_id as subject_id,
      state.default_rating as rating,
      state.updated_at,
      jsonb_build_object(
        'id', track.id,
        'title', track.title,
        'artist', track.artist,
        'album', track.album,
        'duration_ms', track.duration_ms,
        'artwork_url', track.artwork_url,
        'is_explicit', track.is_explicit,
        'provider_tracks', coalesce((
          select jsonb_agg(jsonb_build_object(
            'provider', mapping.provider,
            'provider_id', mapping.provider_id,
            'storefront', mapping.storefront,
            'deep_link', mapping.deep_link,
            'availability', mapping.availability
          ) order by mapping.provider::text, mapping.storefront, mapping.provider_id)
          from public.provider_tracks mapping
          where mapping.canonical_track_id = track.id
        ), '[]'::jsonb)
      ) as subject
    from public.profile_track_subject_states state
    join public.canonical_tracks track on track.id = state.canonical_track_id
    where state.profile_id = p_profile_id
      and state.default_rating is not null

    union all

    select
      state.profile_id,
      'album'::public.review_subject_kind,
      state.canonical_album_id,
      state.default_rating,
      state.updated_at,
      jsonb_build_object(
        'id', album.id,
        'title', album.title,
        'artist', album.artist,
        'release_date', album.release_date,
        'album_type', album.album_type,
        'total_tracks', album.total_tracks,
        'artwork_url', album.artwork_url,
        'upc', album.upc,
        'provider_albums', coalesce((
          select jsonb_agg(jsonb_build_object(
            'provider', mapping.provider,
            'provider_album_id', mapping.provider_album_id,
            'storefront', mapping.storefront,
            'deep_link', mapping.deep_link,
            'availability', mapping.availability,
            'identity_basis', mapping.identity_basis
          ) order by mapping.provider::text, mapping.storefront, mapping.provider_album_id)
          from public.provider_albums mapping
          where mapping.canonical_album_id = album.id
        ), '[]'::jsonb)
      )
    from public.profile_album_subject_states state
    join public.canonical_albums album on album.id = state.canonical_album_id
    where state.profile_id = p_profile_id
      and state.default_rating is not null
  )
  select
    rating_row.profile_id,
    rating_row.subject_kind,
    rating_row.subject_id,
    rating_row.rating,
    rating_row.updated_at,
    rating_row.subject
  from rating_rows rating_row
  where (v_scope = 'all' or rating_row.subject_kind::text = v_scope)
    and (
      p_before_updated_at is null
      or row(
        rating_row.updated_at,
        rating_row.subject_kind::text,
        rating_row.subject_id
      ) < row(
        p_before_updated_at,
        v_cursor_kind,
        p_before_subject_id
      )
    )
  order by
    rating_row.updated_at desc,
    rating_row.subject_kind::text desc,
    rating_row.subject_id desc
  limit p_limit;
end;
$$;

create function public.get_profile_rating_distribution(
  p_profile_id uuid,
  p_subject_kind text default null
)
returns table (
  profile_id uuid,
  scope text,
  rating numeric,
  rating_count bigint,
  total_ratings bigint,
  average_rating numeric
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_scope text := lower(coalesce(nullif(btrim(p_subject_kind), ''), 'all'));
  v_settings public.profile_social_settings%rowtype;
  v_viewer_follows boolean;
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if p_profile_id is null then
    raise exception 'profile id is required' using errcode = '22004';
  end if;
  if not exists (select 1 from public.profiles where id = p_profile_id)
     or public.social_accounts_are_blocked(v_actor_id, p_profile_id) then
    raise exception 'profile unavailable' using errcode = '42501';
  end if;
  if v_scope not in ('all', 'track', 'album') then
    raise exception 'profile rating subject kind must be all, track, or album'
      using errcode = '22023';
  end if;

  select settings.* into v_settings
  from public.profile_social_settings settings
  where settings.profile_id = p_profile_id;
  if not found then
    raise exception 'profile unavailable' using errcode = '42501';
  end if;
  select exists (
    select 1
    from public.social_follows follow_edge
    where follow_edge.follower_id = v_actor_id
      and follow_edge.followed_id = p_profile_id
      and follow_edge.state = 'accepted'
  ) into v_viewer_follows;

  if p_profile_id <> v_actor_id and not (
    v_settings.rating_visibility = 'followers' and v_viewer_follows
  ) then
    return;
  end if;

  return query
  with owner_ratings as (
    select 'track'::text as subject_kind, state.default_rating as owner_rating
    from public.profile_track_subject_states state
    where state.profile_id = p_profile_id
      and state.default_rating is not null
    union all
    select 'album'::text, state.default_rating
    from public.profile_album_subject_states state
    where state.profile_id = p_profile_id
      and state.default_rating is not null
  ),
  scoped_ratings as (
    select owner_rating.owner_rating
    from owner_ratings owner_rating
    where v_scope = 'all' or owner_rating.subject_kind = v_scope
  ),
  summary as (
    select
      count(*)::bigint as total_ratings,
      round(avg(scoped_rating.owner_rating), 2)::numeric as average_rating
    from scoped_ratings scoped_rating
  ),
  buckets as (
    select (bucket * 0.5)::numeric as rating
    from generate_series(1, 10) bucket
  )
  select
    p_profile_id,
    v_scope,
    bucket.rating,
    count(scoped_rating.owner_rating)::bigint,
    summary.total_ratings,
    summary.average_rating
  from buckets bucket
  cross join summary
  left join scoped_ratings scoped_rating
    on scoped_rating.owner_rating = bucket.rating
  group by bucket.rating, summary.total_ratings, summary.average_rating
  order by bucket.rating;
end;
$$;

create type public.public_loved_music as (
  profile_id uuid,
  subject_kind public.review_subject_kind,
  subject_id uuid,
  updated_at timestamptz,
  subject jsonb
);

revoke all on type public.public_loved_music from public;
grant usage on type public.public_loved_music to authenticated;

create function public.list_profile_loved_music(
  p_profile_id uuid,
  p_subject_kind text default null,
  p_before_updated_at timestamptz default null,
  p_before_subject_kind text default null,
  p_before_subject_id uuid default null,
  p_limit integer default 50
)
returns setof public.public_loved_music
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_scope text := lower(coalesce(nullif(btrim(p_subject_kind), ''), 'all'));
  v_cursor_kind text := lower(nullif(btrim(p_before_subject_kind), ''));
  v_settings public.profile_social_settings%rowtype;
  v_viewer_follows boolean;
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if p_profile_id is null then
    raise exception 'profile id is required' using errcode = '22004';
  end if;
  if not exists (select 1 from public.profiles where id = p_profile_id)
     or public.social_accounts_are_blocked(v_actor_id, p_profile_id) then
    raise exception 'profile unavailable' using errcode = '42501';
  end if;
  if v_scope not in ('all', 'track', 'album') then
    raise exception 'Loved subject kind must be all, track, or album'
      using errcode = '22023';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'Loved page size must be between 1 and 100'
      using errcode = '22023';
  end if;
  if num_nonnulls(
    p_before_updated_at,
    p_before_subject_kind,
    p_before_subject_id
  ) not in (0, 3) then
    raise exception 'Loved cursor timestamp, subject kind, and subject id must be provided together'
      using errcode = '22023';
  end if;
  if p_before_updated_at is not null and v_cursor_kind not in ('track', 'album') then
    raise exception 'Loved cursor subject kind must be track or album'
      using errcode = '22023';
  end if;
  if p_before_updated_at is not null
     and v_scope <> 'all'
     and v_cursor_kind <> v_scope then
    raise exception 'Loved cursor subject kind must match the requested scope'
      using errcode = '22023';
  end if;

  select settings.* into v_settings
  from public.profile_social_settings settings
  where settings.profile_id = p_profile_id;
  if not found then
    raise exception 'profile unavailable' using errcode = '42501';
  end if;
  select exists (
    select 1
    from public.social_follows follow_edge
    where follow_edge.follower_id = v_actor_id
      and follow_edge.followed_id = p_profile_id
      and follow_edge.state = 'accepted'
  ) into v_viewer_follows;

  if p_profile_id <> v_actor_id and not (
    v_settings.shelf_visibility = 'followers' and v_viewer_follows
  ) then
    return;
  end if;

  return query
  with loved_rows as (
    select
      state.profile_id,
      'track'::public.review_subject_kind as subject_kind,
      state.canonical_track_id as subject_id,
      state.updated_at,
      jsonb_build_object(
        'id', track.id,
        'title', track.title,
        'artist', track.artist,
        'album', track.album,
        'duration_ms', track.duration_ms,
        'artwork_url', track.artwork_url,
        'is_explicit', track.is_explicit,
        'provider_tracks', coalesce((
          select jsonb_agg(jsonb_build_object(
            'provider', mapping.provider,
            'provider_id', mapping.provider_id,
            'storefront', mapping.storefront,
            'deep_link', mapping.deep_link,
            'availability', mapping.availability
          ) order by mapping.provider::text, mapping.storefront, mapping.provider_id)
          from public.provider_tracks mapping
          where mapping.canonical_track_id = track.id
        ), '[]'::jsonb)
      ) as subject
    from public.profile_track_subject_states state
    join public.canonical_tracks track on track.id = state.canonical_track_id
    where state.profile_id = p_profile_id
      and state.is_loved

    union all

    select
      state.profile_id,
      'album'::public.review_subject_kind,
      state.canonical_album_id,
      state.updated_at,
      jsonb_build_object(
        'id', album.id,
        'title', album.title,
        'artist', album.artist,
        'release_date', album.release_date,
        'album_type', album.album_type,
        'total_tracks', album.total_tracks,
        'artwork_url', album.artwork_url,
        'upc', album.upc,
        'provider_albums', coalesce((
          select jsonb_agg(jsonb_build_object(
            'provider', mapping.provider,
            'provider_album_id', mapping.provider_album_id,
            'storefront', mapping.storefront,
            'deep_link', mapping.deep_link,
            'availability', mapping.availability,
            'identity_basis', mapping.identity_basis
          ) order by mapping.provider::text, mapping.storefront, mapping.provider_album_id)
          from public.provider_albums mapping
          where mapping.canonical_album_id = album.id
        ), '[]'::jsonb)
      )
    from public.profile_album_subject_states state
    join public.canonical_albums album on album.id = state.canonical_album_id
    where state.profile_id = p_profile_id
      and state.is_loved
  )
  select
    loved_row.profile_id,
    loved_row.subject_kind,
    loved_row.subject_id,
    loved_row.updated_at,
    loved_row.subject
  from loved_rows loved_row
  where (v_scope = 'all' or loved_row.subject_kind::text = v_scope)
    and (
      p_before_updated_at is null
      or row(
        loved_row.updated_at,
        loved_row.subject_kind::text,
        loved_row.subject_id
      ) < row(
        p_before_updated_at,
        v_cursor_kind,
        p_before_subject_id
      )
    )
  order by
    loved_row.updated_at desc,
    loved_row.subject_kind::text desc,
    loved_row.subject_id desc
  limit p_limit;
end;
$$;

revoke all on function public.get_member_profile_overview(uuid) from public;
revoke all on function public.list_profile_ratings(
  uuid, text, timestamptz, text, uuid, integer
) from public;
revoke all on function public.get_profile_rating_distribution(uuid, text) from public;
revoke all on function public.list_profile_loved_music(
  uuid, text, timestamptz, text, uuid, integer
) from public;
grant execute on function public.get_member_profile_overview(uuid) to authenticated;
grant execute on function public.list_profile_ratings(
  uuid, text, timestamptz, text, uuid, integer
) to authenticated;
grant execute on function public.get_profile_rating_distribution(uuid, text)
  to authenticated;
grant execute on function public.list_profile_loved_music(
  uuid, text, timestamptz, text, uuid, integer
) to authenticated;

comment on column public.profile_social_settings.rating_visibility is
  'Controls whether accepted followers may view current track/album ratings. Private by default and independent from review, Diary, and Loved shelf visibility.';
comment on function public.get_member_profile_overview(uuid) is
  'Returns one authenticated, block-safe member profile summary whose counts include only rows visible to the viewer; missing and blocked profiles raise explicit errors.';
comment on function public.list_profile_ratings(
  uuid, text, timestamptz, text, uuid, integer
) is
  'Returns a keyset page of narrow current rating projections for the owner or an accepted follower when rating_visibility is followers; never exposes other subject-state flags.';
comment on function public.get_profile_rating_distribution(uuid, text) is
  'Returns all ten half-star buckets and exhaustive summary for a visible member Ratings shelf; a private shelf returns no rows.';
comment on function public.list_profile_loved_music(
  uuid, text, timestamptz, text, uuid, integer
) is
  'Returns a keyset page of narrow Loved track/album projections under shelf_visibility without exposing other owner subject-state flags.';
