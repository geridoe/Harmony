-- Prevent invalid fractional-order values from corrupting queue ordering.
-- PostgreSQL accepts NaN and +/-Infinity as double precision literals, so a
-- simple NOT NULL constraint is not enough. This bounded comparison excludes
-- all three while preserving every finite position used by Harmony.
alter table public.queue_items
  add constraint queue_items_position_finite
  check (
    position > '-Infinity'::double precision
    and position < 'Infinity'::double precision
  );

-- Catalog resolution is callable by every authenticated client. Normalize and
-- validate its user-controlled metadata before it can become shared catalog
-- state or a link rendered by another client.
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
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_canonical_track_id uuid;
  v_provider_id text := nullif(trim(coalesce(p_provider_id, '')), '');
  v_title text := nullif(trim(coalesce(p_title, '')), '');
  v_artist text := nullif(trim(coalesce(p_artist, '')), '');
  v_album text := nullif(trim(coalesce(p_album, '')), '');
  v_artwork_url text := nullif(trim(coalesce(p_artwork_url, '')), '');
  v_deep_link text := nullif(trim(coalesce(p_deep_link, '')), '');
begin
  if v_actor_id is null then raise exception 'authentication required' using errcode = '28000'; end if;
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

  perform pg_advisory_xact_lock(hashtextextended(p_provider::text || ':' || v_provider_id, 0));
  select canonical_track_id into v_canonical_track_id
  from public.provider_tracks
  where provider = p_provider and provider_id = v_provider_id and storefront = 'us';
  if found then return v_canonical_track_id; end if;

  select id into v_canonical_track_id
  from public.canonical_tracks
  where lower(title) = lower(v_title) and lower(artist) = lower(v_artist)
  order by created_at
  limit 1;
  if not found then
    insert into public.canonical_tracks(title, artist, album, duration_ms, artwork_url, is_explicit)
    values (v_title, v_artist, v_album, p_duration_ms, v_artwork_url, coalesce(p_is_explicit, false))
    returning id into v_canonical_track_id;
  end if;

  insert into public.provider_tracks(canonical_track_id, provider, provider_id, storefront, deep_link, availability, match_confidence)
  values (v_canonical_track_id, p_provider, v_provider_id, 'us', v_deep_link, 'playable', 1.0);
  return v_canonical_track_id;
end;
$$;

revoke all on function public.resolve_harmony_track(public.music_provider, text, text, text, text, integer, text, boolean, text) from public;
grant execute on function public.resolve_harmony_track(public.music_provider, text, text, text, text, integer, text, boolean, text) to authenticated;
grant execute on function public.resolve_harmony_track(public.music_provider, text, text, text, text, integer, text, boolean, text) to service_role;
