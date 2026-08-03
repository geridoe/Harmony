alter table public.music_reviews
  add column if not exists subject_title text,
  add column if not exists subject_artist text,
  add column if not exists subject_artwork_url text,
  add column if not exists subject_deep_link text;

update public.music_reviews r
set subject_title = coalesce(r.subject_title, t.title),
    subject_artist = coalesce(r.subject_artist, t.artist),
    subject_artwork_url = coalesce(r.subject_artwork_url, t.artwork_url)
from public.canonical_tracks t
where r.canonical_track_id = t.id and r.subject_kind = 'track';

alter table public.music_reviews
  add constraint music_review_subject_title_length check (subject_title is null or char_length(subject_title) <= 500),
  add constraint music_review_subject_artist_length check (subject_artist is null or char_length(subject_artist) <= 500),
  add constraint music_review_subject_artwork_length check (subject_artwork_url is null or char_length(subject_artwork_url) <= 2000),
  add constraint music_review_subject_link_length check (subject_deep_link is null or char_length(subject_deep_link) <= 2000);

drop function if exists public.create_music_review(public.review_subject_kind, uuid, public.music_provider, text, numeric, text, public.social_visibility, boolean);

create function public.create_music_review(
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

  insert into public.music_reviews(
    profile_id, subject_kind, canonical_track_id, provider, provider_subject_id,
    subject_title, subject_artist, subject_artwork_url, subject_deep_link,
    rating, body, visibility, contains_spoilers
  ) values (
    auth.uid(), p_subject_kind, p_canonical_track_id, p_provider,
    nullif(trim(coalesce(p_provider_subject_id, '')), ''),
    v_title, v_artist, v_artwork, nullif(trim(coalesce(p_subject_deep_link, '')), ''),
    p_rating, p_body, p_visibility, p_contains_spoilers
  ) returning * into v_review;
  return v_review;
end;
$$;

revoke all on function public.create_music_review(public.review_subject_kind, uuid, public.music_provider, text, text, text, text, text, numeric, text, public.social_visibility, boolean) from public;
grant execute on function public.create_music_review(public.review_subject_kind, uuid, public.music_provider, text, text, text, text, text, numeric, text, public.social_visibility, boolean) to authenticated;
