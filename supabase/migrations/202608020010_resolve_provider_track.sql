-- Resolve a provider catalog item to Harmony's canonical queue identity.
-- This allows a queue item discovered in any supported provider to be added
-- before a cross-provider matcher has enriched it with other service IDs.
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
begin
  if v_actor_id is null then raise exception 'authentication required' using errcode = '28000'; end if;
  if p_provider_id is null or char_length(trim(p_provider_id)) = 0 or char_length(p_provider_id) > 500 then
    raise exception 'a provider track identifier is required' using errcode = '22023';
  end if;
  if p_title is null or char_length(trim(p_title)) not between 1 and 500 then
    raise exception 'a track title between 1 and 500 characters is required' using errcode = '22023';
  end if;
  if p_artist is null or char_length(trim(p_artist)) not between 1 and 500 then
    raise exception 'an artist between 1 and 500 characters is required' using errcode = '22023';
  end if;
  if p_duration_ms is not null and p_duration_ms <= 0 then
    raise exception 'duration must be positive' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_provider::text || ':' || p_provider_id, 0));
  select canonical_track_id into v_canonical_track_id
  from public.provider_tracks
  where provider = p_provider and provider_id = p_provider_id and storefront = 'us';
  if found then return v_canonical_track_id; end if;

  select id into v_canonical_track_id
  from public.canonical_tracks
  where lower(title) = lower(trim(p_title)) and lower(artist) = lower(trim(p_artist))
  order by created_at
  limit 1;
  if not found then
    insert into public.canonical_tracks(title, artist, album, duration_ms, artwork_url, is_explicit)
    values (trim(p_title), trim(p_artist), nullif(trim(coalesce(p_album, '')), ''), p_duration_ms, nullif(trim(coalesce(p_artwork_url, '')), ''), coalesce(p_is_explicit, false))
    returning id into v_canonical_track_id;
  end if;

  insert into public.provider_tracks(canonical_track_id, provider, provider_id, storefront, deep_link, availability, match_confidence)
  values (v_canonical_track_id, p_provider, p_provider_id, 'us', nullif(trim(coalesce(p_deep_link, '')), ''), 'playable', 1.0);
  return v_canonical_track_id;
end;
$$;

grant execute on function public.resolve_harmony_track(public.music_provider, text, text, text, text, integer, text, boolean, text) to authenticated;
