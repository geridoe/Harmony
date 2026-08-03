-- Canonical identity must represent a recording, not merely a title/artist
-- string. Preserve the installed-client RPC while moving updated callers to a
-- versioned, storefront- and ISRC-aware contract.

alter table public.provider_tracks
  drop constraint if exists provider_tracks_canonical_track_id_provider_storefront_key;

create function public.normalize_track_identity_text(p_value text)
returns text
language sql
immutable
parallel safe
return nullif(regexp_replace(lower(trim(p_value)), '[[:space:]]+', ' ', 'g'), '');

create index canonical_tracks_metadata_identity_idx
  on public.canonical_tracks(
    public.normalize_track_identity_text(title),
    public.normalize_track_identity_text(artist),
    public.normalize_track_identity_text(album),
    duration_ms
  )
  where isrc is null and album is not null and duration_ms is not null;

create function public.resolve_harmony_track_v2(
  p_provider public.music_provider,
  p_provider_id text,
  p_title text,
  p_artist text,
  p_album text,
  p_duration_ms integer,
  p_artwork_url text,
  p_is_explicit boolean,
  p_deep_link text,
  p_isrc text,
  p_storefront text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_canonical_track_id uuid;
  v_provider_id text := nullif(trim(coalesce(p_provider_id, '')), '');
  v_title text := nullif(trim(coalesce(p_title, '')), '');
  v_artist text := nullif(trim(coalesce(p_artist, '')), '');
  v_album text := nullif(trim(coalesce(p_album, '')), '');
  v_artwork_url text := nullif(trim(coalesce(p_artwork_url, '')), '');
  v_deep_link text := nullif(trim(coalesce(p_deep_link, '')), '');
  v_isrc text := nullif(upper(regexp_replace(trim(coalesce(p_isrc, '')), '[ -]', '', 'g')), '');
  v_storefront text := lower(nullif(trim(coalesce(p_storefront, '')), ''));
  v_candidate_ids uuid[];
  v_candidate_duration integer;
  v_match_confidence numeric(4,3) := 1.000;
begin
  if auth.uid() is null and coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if p_provider is null then
    raise exception 'a music provider is required' using errcode = '22023';
  end if;
  if v_provider_id is null or char_length(v_provider_id) > 500 then
    raise exception 'a provider track identifier between 1 and 500 characters is required' using errcode = '22023';
  end if;
  if v_title is null or char_length(v_title) > 500 then
    raise exception 'a track title between 1 and 500 characters is required' using errcode = '22023';
  end if;
  if v_artist is null or char_length(v_artist) > 500 then
    raise exception 'an artist between 1 and 500 characters is required' using errcode = '22023';
  end if;
  if v_album is not null and char_length(v_album) > 500 then
    raise exception 'an album must not exceed 500 characters' using errcode = '22023';
  end if;
  if p_duration_ms is not null and p_duration_ms <= 0 then
    raise exception 'duration must be positive' using errcode = '22023';
  end if;
  if v_storefront is null or v_storefront !~ '^(global|[a-z]{2})$' then
    raise exception 'storefront must be global or a two-letter country code' using errcode = '22023';
  end if;
  if v_isrc is not null and v_isrc !~ '^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$' then
    raise exception 'ISRC is malformed' using errcode = '22023';
  end if;
  if v_artwork_url is not null and (
    char_length(v_artwork_url) > 2000
    or lower(v_artwork_url) !~ '^https://[^[:space:]/?#]+([/?#][^[:space:]]*)?$'
  ) then
    raise exception 'artwork must be an HTTPS URL no longer than 2000 characters' using errcode = '22023';
  end if;
  if v_deep_link is not null and (
    char_length(v_deep_link) > 2000
    or (p_provider = 'spotify' and lower(v_deep_link) !~ '^https://open[.]spotify[.]com/track/[^/?#[:space:]]+([/?#][^[:space:]]*)?$')
    or (p_provider = 'apple_music' and lower(v_deep_link) !~ '^https://music[.]apple[.]com/[^[:space:]]+$')
  ) then
    raise exception 'deep link does not match its music provider' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('provider:' || p_provider::text || ':' || v_provider_id || ':' || v_storefront, 0)
  );

  select canonical_track_id into v_canonical_track_id
  from public.provider_tracks
  where provider = p_provider
    and provider_id = v_provider_id
    and storefront = v_storefront;
  if found then
    update public.canonical_tracks
    set artwork_url = coalesce(artwork_url, v_artwork_url),
        is_explicit = is_explicit or coalesce(p_is_explicit, false)
    where id = v_canonical_track_id;
    return v_canonical_track_id;
  end if;

  if v_isrc is not null then
    perform pg_advisory_xact_lock(hashtextextended('isrc:' || v_isrc, 0));
    select array_agg(id order by created_at, id), min(duration_ms)
      into v_candidate_ids, v_candidate_duration
    from public.canonical_tracks
    where isrc = v_isrc;

    if coalesce(cardinality(v_candidate_ids), 0) > 1 then
      raise exception 'multiple canonical tracks already use this ISRC'
        using errcode = 'P0003', detail = 'canonical_track_identity_conflict';
    elsif cardinality(v_candidate_ids) = 1 then
      if p_duration_ms is not null
        and v_candidate_duration is not null
        and abs(p_duration_ms - v_candidate_duration) > 5000
      then
        raise exception 'ISRC duration conflicts with the existing recording'
          using errcode = '22023', detail = 'canonical_track_identity_conflict';
      end if;
      v_canonical_track_id := v_candidate_ids[1];
    end if;
  elsif v_album is not null and p_duration_ms is not null then
    perform pg_advisory_xact_lock(hashtextextended(
      'metadata:' || public.normalize_track_identity_text(v_title) || ':' ||
      public.normalize_track_identity_text(v_artist) || ':' ||
      public.normalize_track_identity_text(v_album),
      0
    ));
    select array_agg(id order by created_at, id)
      into v_candidate_ids
    from public.canonical_tracks track
    where track.isrc is null
      and public.normalize_track_identity_text(track.title) = public.normalize_track_identity_text(v_title)
      and public.normalize_track_identity_text(track.artist) = public.normalize_track_identity_text(v_artist)
      and public.normalize_track_identity_text(track.album) = public.normalize_track_identity_text(v_album)
      and track.duration_ms is not null
      and abs(track.duration_ms - p_duration_ms) <= 2000;
    if cardinality(v_candidate_ids) = 1 then
      v_canonical_track_id := v_candidate_ids[1];
      v_match_confidence := 0.850;
    end if;
  end if;

  if v_canonical_track_id is null then
    insert into public.canonical_tracks(
      title, artist, album, duration_ms, isrc, artwork_url, is_explicit
    ) values (
      v_title, v_artist, v_album, p_duration_ms, v_isrc, v_artwork_url,
      coalesce(p_is_explicit, false)
    ) returning id into v_canonical_track_id;
  else
    update public.canonical_tracks
    set artwork_url = coalesce(artwork_url, v_artwork_url),
        is_explicit = is_explicit or coalesce(p_is_explicit, false),
        isrc = coalesce(isrc, v_isrc)
    where id = v_canonical_track_id;
  end if;

  insert into public.provider_tracks(
    canonical_track_id, provider, provider_id, storefront, deep_link,
    availability, match_confidence
  ) values (
    v_canonical_track_id, p_provider, v_provider_id, v_storefront, v_deep_link,
    'playable', v_match_confidence
  );
  return v_canonical_track_id;
end;
$$;

create or replace function public.resolve_harmony_track(
  p_provider public.music_provider,
  p_provider_id text,
  p_title text,
  p_artist text,
  p_album text default null,
  p_duration_ms integer default null,
  p_artwork_url text default null,
  p_is_explicit boolean default false,
  p_deep_link text default null
)
returns uuid
language sql
security definer
set search_path = public
return public.resolve_harmony_track_v2(
  p_provider, p_provider_id, p_title, p_artist, p_album, p_duration_ms,
  p_artwork_url, p_is_explicit, p_deep_link, null,
  case when p_provider = 'spotify' then 'global' else 'us' end
);

revoke all on function public.normalize_track_identity_text(text) from public;
revoke all on function public.resolve_harmony_track_v2(public.music_provider, text, text, text, text, integer, text, boolean, text, text, text) from public;
revoke all on function public.resolve_harmony_track(public.music_provider, text, text, text, text, integer, text, boolean, text) from public;
grant execute on function public.resolve_harmony_track_v2(public.music_provider, text, text, text, text, integer, text, boolean, text, text, text) to authenticated, service_role;
grant execute on function public.resolve_harmony_track(public.music_provider, text, text, text, text, integer, text, boolean, text) to authenticated, service_role;
