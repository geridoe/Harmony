-- Canonical album identity is release identity, not a title/artist guess.
-- Existing album reviews keep their authored provider snapshots while gaining
-- a nullable canonical link. Legacy rows are backfilled only from exact
-- provider identity; cross-provider resolution requires a service-attested
-- UPC/EAN.

create table public.canonical_albums (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(btrim(title)) between 1 and 500),
  artist text check (
    artist is null or char_length(btrim(artist)) between 1 and 500
  ),
  release_date date,
  upc text check (upc is null or upc ~ '^[0-9]{12,13}$'),
  album_type text check (
    album_type is null or album_type in ('album', 'single', 'ep', 'compilation')
  ),
  total_tracks integer check (total_tracks is null or total_tracks > 0),
  artwork_url text check (
    artwork_url is null
    or (
      char_length(artwork_url) <= 2000
      and lower(artwork_url) ~ '^https://[^[:space:]/?#]+([/?#][^[:space:]]*)?$'
    )
  ),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.provider_albums (
  id uuid primary key default gen_random_uuid(),
  canonical_album_id uuid not null
    references public.canonical_albums(id) on delete cascade,
  provider public.music_provider not null,
  provider_album_id text not null
    check (char_length(btrim(provider_album_id)) between 1 and 500),
  storefront text not null check (storefront ~ '^(global|[a-z]{2})$'),
  deep_link text,
  availability public.track_availability not null default 'playable',
  identity_basis text not null default 'provider'
    check (identity_basis in ('provider', 'upc')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint provider_albums_identity_unique
    unique (provider, provider_album_id, storefront),
  constraint provider_albums_deep_link_valid check (
    deep_link is null
    or (
      char_length(deep_link) <= 2000
      and (
        (
          provider = 'spotify'
          and lower(deep_link) ~ '^https://open[.]spotify[.]com/album/[^/?#[:space:]]+([/?#][^[:space:]]*)?$'
        )
        or
        (
          provider = 'apple_music'
          and lower(deep_link) ~ '^https://music[.]apple[.]com/[^[:space:]]*/album/[^[:space:]]+$'
        )
      )
    )
  )
);

create unique index canonical_albums_upc_unique
  on public.canonical_albums(upc)
  where upc is not null;
create index canonical_albums_title_artist_idx
  on public.canonical_albums(lower(title), lower(artist));
create index provider_albums_canonical_idx
  on public.provider_albums(canonical_album_id, provider, storefront);

create trigger canonical_albums_updated_at
before update on public.canonical_albums
for each row execute function public.set_updated_at();
create trigger provider_albums_updated_at
before update on public.provider_albums
for each row execute function public.set_updated_at();

alter table public.canonical_albums enable row level security;
alter table public.provider_albums enable row level security;

create policy "signed-in users read canonical albums"
on public.canonical_albums
for select to authenticated
using (true);
create policy "signed-in users read provider album mappings"
on public.provider_albums
for select to authenticated
using (true);

revoke insert, update, delete on
  public.canonical_albums,
  public.provider_albums
from authenticated;
grant select on
  public.canonical_albums,
  public.provider_albums
to authenticated;

create function public.normalize_album_upc(p_upc text)
returns text
language sql
immutable
parallel safe
return nullif(regexp_replace(btrim(coalesce(p_upc, '')), '[ -]', '', 'g'), '');

create function public.infer_provider_album_storefront(
  p_provider public.music_provider,
  p_deep_link text
)
returns text
language sql
immutable
parallel safe
as $$
  select case
    when p_provider = 'spotify' then 'global'
    when p_provider = 'apple_music' then coalesce(
      substring(lower(btrim(coalesce(p_deep_link, '')))
        from '^https://music[.]apple[.]com/([a-z]{2})/'),
      'us'
    )
    else 'us'
  end;
$$;

-- Strict authority used by enriched callers. Provider IDs remain opaque and
-- case-sensitive. Exact provider identity wins. UPC/EAN is the only current
-- cross-provider merge key; title/artist metadata is presentation, never an
-- identity fallback. Ordinary authenticated clients cannot attest UPC/EAN;
-- that evidence is accepted only from trusted service-role ingestion.
create function public.resolve_harmony_album_v2(
  p_provider public.music_provider,
  p_provider_id text,
  p_title text,
  p_artist text,
  p_artwork_url text,
  p_deep_link text,
  p_upc text,
  p_release_date date,
  p_total_tracks integer,
  p_album_type text,
  p_storefront text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_provider_id text := nullif(btrim(coalesce(p_provider_id, '')), '');
  v_title text := nullif(btrim(coalesce(p_title, '')), '');
  v_artist text := nullif(btrim(coalesce(p_artist, '')), '');
  v_artwork_url text := nullif(btrim(coalesce(p_artwork_url, '')), '');
  v_deep_link text := nullif(btrim(coalesce(p_deep_link, '')), '');
  v_upc text := public.normalize_album_upc(p_upc);
  v_album_type text := nullif(lower(btrim(coalesce(p_album_type, ''))), '');
  v_storefront text := lower(nullif(btrim(coalesce(p_storefront, '')), ''));
  v_canonical_album_id uuid;
  v_upc_album_id uuid;
  v_existing_upc text;
  v_identity_basis text := 'provider';
  v_is_authoritative boolean := coalesce(auth.role(), '') = 'service_role';
begin
  if auth.uid() is null and coalesce(auth.role(), '') <> 'service_role' then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if p_provider is null then
    raise exception 'an album provider is required' using errcode = '22023';
  end if;
  if v_provider_id is null or char_length(v_provider_id) > 500 then
    raise exception 'a provider album identifier between 1 and 500 characters is required'
      using errcode = '22023';
  end if;
  if v_title is null or char_length(v_title) > 500 then
    raise exception 'an album title between 1 and 500 characters is required'
      using errcode = '22023';
  end if;
  if v_artist is not null and char_length(v_artist) > 500 then
    raise exception 'an album artist must not exceed 500 characters'
      using errcode = '22023';
  end if;
  if v_storefront is null or v_storefront !~ '^(global|[a-z]{2})$' then
    raise exception 'storefront must be global or a two-letter country code'
      using errcode = '22023';
  end if;
  if v_upc is not null and v_upc !~ '^[0-9]{12,13}$' then
    raise exception 'album UPC/EAN must contain 12 or 13 digits'
      using errcode = '22023';
  end if;
  if v_upc is not null and not v_is_authoritative then
    raise exception 'authoritative album identity evidence is required'
      using errcode = '42501', detail = 'album_upc_attestation_required';
  end if;
  if p_total_tracks is not null and p_total_tracks <= 0 then
    raise exception 'album track count must be positive' using errcode = '22023';
  end if;
  if v_album_type is not null
    and v_album_type not in ('album', 'single', 'ep', 'compilation')
  then
    raise exception 'album type is unsupported' using errcode = '22023';
  end if;
  if v_artwork_url is not null and (
    char_length(v_artwork_url) > 2000
    or lower(v_artwork_url) !~ '^https://[^[:space:]/?#]+([/?#][^[:space:]]*)?$'
  ) then
    raise exception 'album artwork must be an HTTPS URL no longer than 2000 characters'
      using errcode = '22023';
  end if;
  if v_deep_link is not null and (
    char_length(v_deep_link) > 2000
    or (
      p_provider = 'spotify'
      and lower(v_deep_link) !~ '^https://open[.]spotify[.]com/album/[^/?#[:space:]]+([/?#][^[:space:]]*)?$'
    )
    or (
      p_provider = 'apple_music'
      and lower(v_deep_link) !~ '^https://music[.]apple[.]com/[^[:space:]]*/album/[^[:space:]]+$'
    )
  ) then
    raise exception 'album deep link does not match its music provider'
      using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'provider-album:' || p_provider::text || ':' || v_provider_id || ':' || v_storefront,
    0
  ));

  select mapping.canonical_album_id
    into v_canonical_album_id
  from public.provider_albums mapping
  where mapping.provider = p_provider
    and mapping.provider_album_id = v_provider_id
    and mapping.storefront = v_storefront;

  if found then
    select album.upc into v_existing_upc
    from public.canonical_albums album
    where album.id = v_canonical_album_id
    for update;

    if v_upc is not null then
      perform pg_advisory_xact_lock(hashtextextended('album-upc:' || v_upc, 0));
      if v_existing_upc is not null and v_existing_upc <> v_upc then
        raise exception 'provider album identity conflicts with its existing UPC/EAN'
          using errcode = '22023', detail = 'canonical_album_identity_conflict';
      end if;
      select id into v_upc_album_id
      from public.canonical_albums
      where upc = v_upc and id <> v_canonical_album_id;
      if found then
        raise exception 'UPC/EAN already belongs to another canonical album'
          using errcode = '22023', detail = 'canonical_album_identity_conflict';
      end if;
    end if;

    update public.canonical_albums
    set artist = coalesce(artist, v_artist),
        release_date = coalesce(release_date, p_release_date),
        upc = coalesce(upc, v_upc),
        album_type = coalesce(album_type, v_album_type),
        total_tracks = coalesce(total_tracks, p_total_tracks),
        artwork_url = coalesce(artwork_url, v_artwork_url)
    where id = v_canonical_album_id;

    update public.provider_albums
    set deep_link = coalesce(deep_link, v_deep_link),
        availability = 'playable'
    where provider = p_provider
      and provider_album_id = v_provider_id
      and storefront = v_storefront;
    return v_canonical_album_id;
  end if;

  if v_upc is not null then
    perform pg_advisory_xact_lock(hashtextextended('album-upc:' || v_upc, 0));
    select id into v_canonical_album_id
    from public.canonical_albums
    where upc = v_upc;
    if found then
      v_identity_basis := 'upc';
    end if;
  end if;

  if v_canonical_album_id is null then
    insert into public.canonical_albums(
      title, artist, release_date, upc, album_type, total_tracks, artwork_url
    ) values (
      v_title, v_artist, p_release_date, v_upc, v_album_type,
      p_total_tracks, v_artwork_url
    ) returning id into v_canonical_album_id;
  else
    update public.canonical_albums
    set artist = coalesce(artist, v_artist),
        release_date = coalesce(release_date, p_release_date),
        album_type = coalesce(album_type, v_album_type),
        total_tracks = coalesce(total_tracks, p_total_tracks),
        artwork_url = coalesce(artwork_url, v_artwork_url)
    where id = v_canonical_album_id;
  end if;

  insert into public.provider_albums(
    canonical_album_id, provider, provider_album_id, storefront, deep_link,
    availability, identity_basis
  ) values (
    v_canonical_album_id, p_provider, v_provider_id, v_storefront, v_deep_link,
    'playable', v_identity_basis
  );
  return v_canonical_album_id;
end;
$$;

-- Convenience wrapper for provider-snapshot callers. It intentionally has no
-- metadata matcher: absent UPC means a new provider-scoped canonical release.
create function public.resolve_harmony_album(
  p_provider public.music_provider,
  p_provider_id text,
  p_title text,
  p_artist text default null,
  p_artwork_url text default null,
  p_deep_link text default null
)
returns uuid
language sql
security definer
set search_path = public
return public.resolve_harmony_album_v2(
  p_provider,
  p_provider_id,
  p_title,
  p_artist,
  p_artwork_url,
  p_deep_link,
  null,
  null,
  null,
  null,
  public.infer_provider_album_storefront(p_provider, p_deep_link)
);

alter table public.music_reviews
  add column canonical_album_id uuid
    references public.canonical_albums(id) on delete restrict;

-- Backfill every usable legacy album review, including private, blocked,
-- deleted, and duplicate reviews. Exact provider identity is the sole grouping
-- key. Snapshot metadata, review timestamps, and durable public IDs stay put.
alter table public.music_reviews disable trigger music_reviews_updated_at;
do $$
declare
  v_review record;
  v_storefront text;
  v_canonical_album_id uuid;
  v_artwork_url text;
  v_deep_link text;
begin
  for v_review in
    select review.*
    from public.music_reviews review
    where review.subject_kind = 'album'
      and review.provider is not null
      and nullif(btrim(coalesce(review.provider_subject_id, '')), '') is not null
      and char_length(btrim(review.provider_subject_id)) <= 500
      and nullif(btrim(coalesce(review.subject_title, '')), '') is not null
    order by review.created_at, review.id
  loop
    v_storefront := public.infer_provider_album_storefront(
      v_review.provider,
      v_review.subject_deep_link
    );
    select mapping.canonical_album_id into v_canonical_album_id
    from public.provider_albums mapping
    where mapping.provider = v_review.provider
      and mapping.provider_album_id = btrim(v_review.provider_subject_id)
      and mapping.storefront = v_storefront;

    if not found then
      v_artwork_url := case
        when char_length(btrim(coalesce(v_review.subject_artwork_url, ''))) <= 2000
          and lower(btrim(coalesce(v_review.subject_artwork_url, '')))
            ~ '^https://[^[:space:]/?#]+([/?#][^[:space:]]*)?$'
        then btrim(v_review.subject_artwork_url)
        else null
      end;
      v_deep_link := case
        when v_review.provider = 'spotify'
          and lower(btrim(coalesce(v_review.subject_deep_link, '')))
            ~ '^https://open[.]spotify[.]com/album/[^/?#[:space:]]+([/?#][^[:space:]]*)?$'
        then btrim(v_review.subject_deep_link)
        when v_review.provider = 'apple_music'
          and lower(btrim(coalesce(v_review.subject_deep_link, '')))
            ~ '^https://music[.]apple[.]com/[^[:space:]]*/album/[^[:space:]]+$'
        then btrim(v_review.subject_deep_link)
        else null
      end;

      insert into public.canonical_albums(title, artist, artwork_url)
      values (
        btrim(v_review.subject_title),
        nullif(btrim(coalesce(v_review.subject_artist, '')), ''),
        v_artwork_url
      ) returning id into v_canonical_album_id;

      insert into public.provider_albums(
        canonical_album_id, provider, provider_album_id, storefront, deep_link,
        availability, identity_basis
      ) values (
        v_canonical_album_id,
        v_review.provider,
        btrim(v_review.provider_subject_id),
        v_storefront,
        v_deep_link,
        'playable',
        'provider'
      );
    end if;

    update public.music_reviews
    set canonical_album_id = v_canonical_album_id
    where id = v_review.id;
  end loop;
end;
$$;
alter table public.music_reviews enable trigger music_reviews_updated_at;

alter table public.music_reviews
  drop constraint if exists music_reviews_check;
alter table public.music_reviews
  add constraint music_reviews_subject_identity_valid check (
    (
      subject_kind = 'track'
      and canonical_track_id is not null
      and canonical_album_id is null
    )
    or
    (
      subject_kind = 'album'
      and canonical_track_id is null
      and (canonical_album_id is not null or provider_subject_id is not null)
    )
  );

create index music_reviews_canonical_album_page_idx
  on public.music_reviews(canonical_album_id, created_at desc, id desc)
  where canonical_album_id is not null and deleted_at is null;

-- Replace the installed 13-argument function with one extended contract.
-- Every appended argument defaults, so old named JSON payloads remain valid
-- and PostgREST sees only one create_music_review candidate.
drop function public.create_music_review(
  public.review_subject_kind, uuid, public.music_provider, text, text, text,
  text, text, numeric, text, public.social_visibility, boolean, boolean
);

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
  p_contains_spoilers boolean default false,
  p_is_loved boolean default false,
  p_canonical_album_id uuid default null,
  p_provider_storefront text default null,
  p_album_upc text default null,
  p_album_release_date date default null,
  p_album_total_tracks integer default null,
  p_album_type text default null
)
returns public.music_reviews
language plpgsql
security definer
set search_path = public
as $$
declare
  v_review public.music_reviews%rowtype;
  v_canonical_album_id uuid := p_canonical_album_id;
  v_resolved_album_id uuid;
  v_title text := nullif(btrim(coalesce(p_subject_title, '')), '');
  v_artist text := nullif(btrim(coalesce(p_subject_artist, '')), '');
  v_artwork text := nullif(btrim(coalesce(p_subject_artwork_url, '')), '');
  v_deep_link text := nullif(btrim(coalesce(p_subject_deep_link, '')), '');
  v_provider_id text := nullif(btrim(coalesce(p_provider_subject_id, '')), '');
  v_provider public.music_provider := p_provider;
  v_storefront text;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;

  if p_subject_kind = 'track' then
    if p_canonical_album_id is not null then
      raise exception 'track reviews cannot reference a canonical album'
        using errcode = '22023';
    end if;
    if p_canonical_track_id is null or not exists (
      select 1 from public.canonical_tracks where id = p_canonical_track_id
    ) then
      raise exception 'canonical track not found' using errcode = 'P0002';
    end if;
    select coalesce(v_title, title), coalesce(v_artist, artist),
           coalesce(v_artwork, artwork_url)
      into v_title, v_artist, v_artwork
    from public.canonical_tracks
    where id = p_canonical_track_id;
  else
    if p_canonical_track_id is not null then
      raise exception 'album reviews cannot reference a canonical track'
        using errcode = '22023';
    end if;

    if v_provider is not null or v_provider_id is not null then
      if v_provider is null or v_provider_id is null or v_title is null then
        raise exception 'an album provider, identifier, and title are required'
          using errcode = '22023';
      end if;
      v_storefront := coalesce(
        lower(nullif(btrim(coalesce(p_provider_storefront, '')), '')),
        public.infer_provider_album_storefront(v_provider, v_deep_link)
      );
      v_resolved_album_id := public.resolve_harmony_album_v2(
        v_provider,
        v_provider_id,
        v_title,
        v_artist,
        v_artwork,
        v_deep_link,
        p_album_upc,
        p_album_release_date,
        p_album_total_tracks,
        p_album_type,
        v_storefront
      );
      if v_canonical_album_id is not null
        and v_canonical_album_id <> v_resolved_album_id
      then
        raise exception 'canonical album does not own the supplied provider mapping'
          using errcode = '22023', detail = 'canonical_album_identity_conflict';
      end if;
      v_canonical_album_id := v_resolved_album_id;
    elsif v_canonical_album_id is null then
      raise exception 'a canonical album or provider album identity is required'
        using errcode = '22023';
    end if;

    select coalesce(v_title, album.title),
           coalesce(v_artist, album.artist),
           coalesce(v_artwork, album.artwork_url)
      into v_title, v_artist, v_artwork
    from public.canonical_albums album
    where album.id = v_canonical_album_id;
    if not found then
      raise exception 'canonical album not found' using errcode = 'P0002';
    end if;

    if v_provider is null then
      select mapping.provider, mapping.provider_album_id, mapping.deep_link
        into v_provider, v_provider_id, v_deep_link
      from public.provider_albums mapping
      where mapping.canonical_album_id = v_canonical_album_id
      order by
        case mapping.availability when 'playable' then 0 when 'open_in_provider' then 1 else 2 end,
        mapping.provider::text,
        mapping.storefront,
        mapping.created_at,
        mapping.id
      limit 1;
    end if;
  end if;

  if v_artwork is not null and lower(v_artwork) not like 'https://%' then
    raise exception 'review artwork must use HTTPS' using errcode = '22023';
  end if;
  if v_deep_link is not null and (
    (v_provider = 'spotify' and lower(v_deep_link) not like 'https://open.spotify.com/%')
    or
    (v_provider = 'apple_music' and lower(v_deep_link) not like 'https://music.apple.com/%')
  ) then
    raise exception 'review provider link is invalid' using errcode = '22023';
  end if;

  insert into public.music_reviews(
    profile_id, subject_kind, canonical_track_id, canonical_album_id,
    provider, provider_subject_id, subject_title, subject_artist,
    subject_artwork_url, subject_deep_link, rating, body, visibility,
    contains_spoilers, is_loved
  ) values (
    auth.uid(), p_subject_kind, p_canonical_track_id, v_canonical_album_id,
    v_provider, v_provider_id, v_title, v_artist, v_artwork, v_deep_link,
    p_rating, p_body, p_visibility, p_contains_spoilers,
    coalesce(p_is_loved, false)
  ) returning * into v_review;
  return v_review;
end;
$$;

create function public.get_canonical_album(p_canonical_album_id uuid)
returns public.canonical_albums
language plpgsql
stable
security invoker
set search_path = public
as $$
declare
  v_album public.canonical_albums%rowtype;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  select * into v_album
  from public.canonical_albums
  where id = p_canonical_album_id;
  if not found then
    raise exception 'canonical album not found' using errcode = 'P0002';
  end if;
  return v_album;
end;
$$;

create function public.list_canonical_album_reviews(
  p_canonical_album_id uuid,
  p_before_created_at timestamptz default null,
  p_before_id uuid default null,
  p_limit integer default 50
)
returns setof public.music_reviews
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
    select 1 from public.canonical_albums where id = p_canonical_album_id
  ) then
    raise exception 'canonical album not found' using errcode = 'P0002';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'album review page size must be between 1 and 100'
      using errcode = '22023';
  end if;
  if (p_before_created_at is null) <> (p_before_id is null) then
    raise exception 'album review cursor timestamp and id must be provided together'
      using errcode = '22023';
  end if;

  return query
  select review.*
  from public.music_reviews review
  where review.subject_kind = 'album'
    and review.canonical_album_id = p_canonical_album_id
    and review.deleted_at is null
    and (
      p_before_created_at is null
      or review.created_at < p_before_created_at
      or (review.created_at = p_before_created_at and review.id < p_before_id)
    )
  order by review.created_at desc, review.id desc
  limit p_limit;
end;
$$;

revoke all on function public.normalize_album_upc(text) from public;
revoke all on function public.infer_provider_album_storefront(public.music_provider, text) from public;
revoke all on function public.resolve_harmony_album_v2(
  public.music_provider, text, text, text, text, text, text, date, integer, text, text
) from public;
revoke all on function public.resolve_harmony_album(
  public.music_provider, text, text, text, text, text
) from public;
revoke all on function public.create_music_review(
  public.review_subject_kind, uuid, public.music_provider, text, text, text,
  text, text, numeric, text, public.social_visibility, boolean, boolean, uuid,
  text, text, date, integer, text
) from public;
revoke all on function public.get_canonical_album(uuid) from public;
revoke all on function public.list_canonical_album_reviews(
  uuid, timestamptz, uuid, integer
) from public;

grant execute on function public.resolve_harmony_album_v2(
  public.music_provider, text, text, text, text, text, text, date, integer, text, text
) to authenticated, service_role;
grant execute on function public.resolve_harmony_album(
  public.music_provider, text, text, text, text, text
) to authenticated, service_role;
grant execute on function public.create_music_review(
  public.review_subject_kind, uuid, public.music_provider, text, text, text,
  text, text, numeric, text, public.social_visibility, boolean, boolean, uuid,
  text, text, date, integer, text
) to authenticated;
grant execute on function public.get_canonical_album(uuid) to authenticated;
grant execute on function public.list_canonical_album_reviews(
  uuid, timestamptz, uuid, integer
) to authenticated;
