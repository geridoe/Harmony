-- Social publishing must begin off. Earlier development builds exposed review
-- visibility before there was a user-facing privacy choice, so reset those
-- settings and existing prototype reviews to the safe default.
alter table public.profile_social_settings
  alter column reviews_visibility set default 'private';

update public.profile_social_settings
set reviews_visibility = 'private'
where reviews_visibility <> 'private';

update public.music_reviews
set visibility = 'private'
where visibility <> 'private';
