-- A small deterministic catalog for the personal-project MVP. Production
-- catalog records will be created by provider search/matching services.
insert into public.canonical_tracks (title, artist, album, duration_ms)
select source.title, source.artist, source.album, source.duration_ms
from (values
  ('Afterglow', 'Wolves at Noon', 'Motion Blur', 221000),
  ('Neon Coast', 'Daya Rose', 'Neon Coast', 194000),
  ('Seventeen', 'The Ferns', 'Paper Rooms', 248000),
  ('Switchback', 'KITE CLUB', 'Switchback', 203000),
  ('Blue Hour', 'Eloise Harbor', 'Slow Light', 216000)
) as source(title, artist, album, duration_ms)
where not exists (
  select 1 from public.canonical_tracks existing
  where existing.title = source.title and existing.artist = source.artist
);
