do $$ begin
  create type public.review_subject_kind as enum ('track', 'album');
exception when duplicate_object then null;
end $$;
do $$ begin
  create type public.review_reaction_kind as enum ('heart', 'fire', 'laugh', 'thinking');
exception when duplicate_object then null;
end $$;

create table public.music_reviews (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  subject_kind public.review_subject_kind not null,
  canonical_track_id uuid references public.canonical_tracks(id) on delete set null,
  provider public.music_provider,
  provider_subject_id text,
  rating numeric(2,1) not null check (rating >= 0.5 and rating <= 5.0 and mod(rating * 10, 5) = 0),
  body text not null default '' check (char_length(body) <= 4000),
  visibility public.social_visibility not null default 'followers',
  contains_spoilers boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  check ((subject_kind = 'track' and canonical_track_id is not null) or (subject_kind = 'album' and provider_subject_id is not null))
);
create table public.review_comments (
  id uuid primary key default gen_random_uuid(),
  review_id uuid not null references public.music_reviews(id) on delete cascade,
  author_id uuid not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(trim(body)) between 1 and 2000),
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);
create table public.review_reactions (
  review_id uuid not null references public.music_reviews(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  kind public.review_reaction_kind not null,
  created_at timestamptz not null default now(),
  primary key (review_id, profile_id, kind)
);
create index music_reviews_profile_created_idx on public.music_reviews(profile_id, created_at desc);
create index review_comments_review_created_idx on public.review_comments(review_id, created_at);
create trigger music_reviews_updated_at before update on public.music_reviews for each row execute function public.set_updated_at();

create or replace function public.can_view_music_review(p_review_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.music_reviews
    where id = p_review_id and deleted_at is null and public.can_view_social(profile_id, visibility)
  );
$$;

alter table public.music_reviews enable row level security;
alter table public.review_comments enable row level security;
alter table public.review_reactions enable row level security;
create policy "view consented music reviews" on public.music_reviews for select to authenticated using (deleted_at is null and public.can_view_social(profile_id, visibility));
create policy "view comments on visible reviews" on public.review_comments for select to authenticated using (deleted_at is null and public.can_view_music_review(review_id));
create policy "view reactions on visible reviews" on public.review_reactions for select to authenticated using (public.can_view_music_review(review_id));
revoke insert, update, delete on public.music_reviews, public.review_comments, public.review_reactions from authenticated;

create or replace function public.create_music_review(
  p_subject_kind public.review_subject_kind,
  p_canonical_track_id uuid default null,
  p_provider public.music_provider default null,
  p_provider_subject_id text default null,
  p_rating numeric default 3.0,
  p_body text default '',
  p_visibility public.social_visibility default 'followers',
  p_contains_spoilers boolean default false
) returns public.music_reviews language plpgsql security definer set search_path = public as $$
declare v_review public.music_reviews%rowtype;
begin
  if auth.uid() is null then raise exception 'authentication required' using errcode = '28000'; end if;
  if p_subject_kind = 'track' and (p_canonical_track_id is null or not exists (select 1 from public.canonical_tracks where id = p_canonical_track_id)) then raise exception 'canonical track not found' using errcode = 'P0002'; end if;
  if p_subject_kind = 'album' and char_length(trim(coalesce(p_provider_subject_id, ''))) = 0 then raise exception 'an album provider identifier is required' using errcode = '22023'; end if;
  insert into public.music_reviews(profile_id, subject_kind, canonical_track_id, provider, provider_subject_id, rating, body, visibility, contains_spoilers)
  values (auth.uid(), p_subject_kind, p_canonical_track_id, p_provider, nullif(trim(coalesce(p_provider_subject_id, '')), ''), p_rating, p_body, p_visibility, p_contains_spoilers)
  returning * into v_review;
  return v_review;
end;
$$;

create or replace function public.add_review_comment(p_review_id uuid, p_body text)
returns public.review_comments language plpgsql security definer set search_path = public as $$
declare v_comment public.review_comments%rowtype;
begin
  if auth.uid() is null then raise exception 'authentication required' using errcode = '28000'; end if;
  if not public.can_view_music_review(p_review_id) then raise exception 'review unavailable' using errcode = '42501'; end if;
  insert into public.review_comments(review_id, author_id, body) values (p_review_id, auth.uid(), trim(p_body)) returning * into v_comment;
  return v_comment;
end;
$$;

create or replace function public.toggle_review_reaction(p_review_id uuid, p_kind public.review_reaction_kind)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'authentication required' using errcode = '28000'; end if;
  if not public.can_view_music_review(p_review_id) then raise exception 'review unavailable' using errcode = '42501'; end if;
  delete from public.review_reactions where review_id = p_review_id and profile_id = auth.uid() and kind = p_kind;
  if found then return false; end if;
  insert into public.review_reactions(review_id, profile_id, kind) values (p_review_id, auth.uid(), p_kind);
  return true;
end;
$$;

revoke all on function public.can_view_music_review(uuid) from public;
grant execute on function public.can_view_music_review(uuid), public.create_music_review(public.review_subject_kind, uuid, public.music_provider, text, numeric, text, public.social_visibility, boolean), public.add_review_comment(uuid, text), public.toggle_review_reaction(uuid, public.review_reaction_kind) to authenticated;
