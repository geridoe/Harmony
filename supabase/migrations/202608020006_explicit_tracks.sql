alter table public.canonical_tracks
add column if not exists is_explicit boolean not null default false;
