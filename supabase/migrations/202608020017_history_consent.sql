-- Recording Harmony plays is a separate consent from choosing who can see
-- already-recorded history. It starts disabled for every account.
alter table public.profile_social_settings
  add column record_harmony_plays boolean not null default false;
