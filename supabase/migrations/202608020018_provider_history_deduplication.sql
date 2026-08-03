create unique index if not exists listening_history_provider_play_unique
  on public.listening_history_entries (profile_id, provider, provider_track_id, played_at)
  where source = 'provider_import' and provider_track_id is not null;
