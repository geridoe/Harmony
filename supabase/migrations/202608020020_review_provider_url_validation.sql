create or replace function public.create_music_review(
  p_subject_kind public.review_subject_kind,
  p_canonical_track_id uuid default null,
  p_provider public.music_provider default null,
  p_provider_subject_id text default null,
  p_subject_title text default null,
  p_subject_artist text default null,
  p_subject_artwork_url text default null,
  p_subject_deep_link text default null,
  p_rating numeric default 3.0,
  p_body text default '',
  p_visibility public.social_visibility default 'followers',
  p_contains_spoilers boolean default false
) returns public.music_reviews language plpgsql security definer set search_path = public as $$
declare
  v_review public.music_reviews%rowtype;
  v_title text := nullif(trim(coalesce(p_subject_title, '')), '');
  v_artist text := nullif(trim(coalesce(p_subject_artist, '')), '');
  v_artwork text := nullif(trim(coalesce(p_subject_artwork_url, '')), '');
  v_deep_link text := nullif(trim(coalesce(p_subject_deep_link, '')), '');
begin
  if auth.uid() is null then raise exception 'authentication required' using errcode = '28000'; end if;
  if p_subject_kind = 'track' then
    if p_canonical_track_id is null or not exists (select 1 from public.canonical_tracks where id = p_canonical_track_id) then
      raise exception 'canonical track not found' using errcode = 'P0002';
    end if;
    select coalesce(v_title, title), coalesce(v_artist, artist), coalesce(v_artwork, artwork_url)
      into v_title, v_artist, v_artwork
      from public.canonical_tracks where id = p_canonical_track_id;
  elsif char_length(trim(coalesce(p_provider_subject_id, ''))) = 0 or p_provider is null or v_title is null then
    raise exception 'an album provider, identifier, and title are required' using errcode = '22023';
  end if;
  if v_artwork is not null and lower(v_artwork) not like 'https://%' then
    raise exception 'review artwork must use HTTPS' using errcode = '22023';
  end if;
  if v_deep_link is not null and (
    (p_provider = 'spotify' and lower(v_deep_link) not like 'https://open.spotify.com/%') or
    (p_provider = 'apple_music' and lower(v_deep_link) not like 'https://music.apple.com/%')
  ) then
    raise exception 'review provider link is invalid' using errcode = '22023';
  end if;

  insert into public.music_reviews(
    profile_id, subject_kind, canonical_track_id, provider, provider_subject_id,
    subject_title, subject_artist, subject_artwork_url, subject_deep_link,
    rating, body, visibility, contains_spoilers
  ) values (
    auth.uid(), p_subject_kind, p_canonical_track_id, p_provider,
    nullif(trim(coalesce(p_provider_subject_id, '')), ''),
    v_title, v_artist, v_artwork, v_deep_link,
    p_rating, p_body, p_visibility, p_contains_spoilers
  ) returning * into v_review;
  return v_review;
end;
$$;
