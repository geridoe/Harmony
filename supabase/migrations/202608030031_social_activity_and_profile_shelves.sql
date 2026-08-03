-- Profile taste shelves remain private until their owner opts into follower
-- visibility. Existing settings PATCH clients remain compatible because they
-- may omit this new column.
alter table public.profile_social_settings
  add column shelf_visibility public.social_visibility not null default 'private',
  add constraint profile_social_settings_shelf_visibility_nonpublic check (
    shelf_visibility in ('private', 'followers')
  );

do $$ begin
  create type public.social_activity_kind as enum ('diary_logged', 'review_published');
exception when duplicate_object then null;
end $$;

-- Events retain only durable identity and publication time. Feed reads resolve
-- the current object and re-check its current visibility, so a private/deleted
-- object disappears without rewriting the append-only event.
create table public.social_activity_events (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid not null references public.profiles(id) on delete cascade,
  kind public.social_activity_kind not null,
  diary_entry_id uuid,
  review_id uuid,
  published_at timestamptz not null default now(),
  check (
    (kind = 'diary_logged' and diary_entry_id is not null and review_id is null)
    or
    (kind = 'review_published' and review_id is not null and diary_entry_id is null)
  )
);

create unique index social_activity_diary_object_unique
  on public.social_activity_events(diary_entry_id)
  where diary_entry_id is not null;
create unique index social_activity_review_object_unique
  on public.social_activity_events(review_id)
  where review_id is not null;
create index social_activity_feed_page_idx
  on public.social_activity_events(published_at desc, id desc);
create index social_activity_actor_page_idx
  on public.social_activity_events(actor_id, published_at desc, id desc);
create index profile_active_reviews_page_idx
  on public.music_reviews(profile_id, created_at desc, id desc)
  where deleted_at is null;
create index profile_loved_tracks_page_idx
  on public.profile_track_subject_states(profile_id, updated_at desc, canonical_track_id desc)
  where is_loved;

alter table public.social_activity_events enable row level security;
revoke insert, update, delete on public.social_activity_events from authenticated;

create policy "view current followed social activity"
on public.social_activity_events
for select to authenticated
using (
  not public.social_accounts_are_blocked(auth.uid(), actor_id)
  and (
    actor_id = auth.uid()
    or exists (
      select 1 from public.social_follows follow
      where follow.follower_id = auth.uid()
        and follow.followed_id = actor_id
        and follow.state = 'accepted'
    )
  )
  and (
    (
      kind = 'diary_logged'
      and exists (
        select 1 from public.listening_history_entries entry
        where entry.id = diary_entry_id
          and entry.profile_id = actor_id
          and entry.source = 'manual'
          and entry.visibility = 'followers'
      )
    )
    or
    (
      kind = 'review_published'
      and exists (
        select 1 from public.music_reviews review
        where review.id = review_id
          and review.profile_id = actor_id
          and review.deleted_at is null
          and review.visibility = 'followers'
      )
    )
  )
);

create function public.emit_diary_social_activity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.source = 'manual'
     and new.visibility = 'followers'
     and (
       tg_op = 'INSERT'
       or (tg_op = 'UPDATE' and old.visibility = 'private')
     ) then
    insert into public.social_activity_events(actor_id, kind, diary_entry_id)
    values (new.profile_id, 'diary_logged', new.id)
    on conflict (diary_entry_id) where diary_entry_id is not null do nothing;
  end if;
  return new;
end;
$$;

create trigger listening_history_emit_social_activity_insert
after insert on public.listening_history_entries
for each row execute function public.emit_diary_social_activity();
create trigger listening_history_emit_social_activity_visibility
after update of visibility on public.listening_history_entries
for each row execute function public.emit_diary_social_activity();

create function public.emit_review_social_activity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.deleted_at is null
     and new.visibility = 'followers'
     and (
       tg_op = 'INSERT'
       or (tg_op = 'UPDATE' and old.visibility = 'private')
     ) then
    insert into public.social_activity_events(actor_id, kind, review_id)
    values (new.profile_id, 'review_published', new.id)
    on conflict (review_id) where review_id is not null do nothing;
  end if;
  return new;
end;
$$;

create trigger music_reviews_emit_social_activity_insert
after insert on public.music_reviews
for each row execute function public.emit_review_social_activity();
create trigger music_reviews_emit_social_activity_visibility
after update of visibility on public.music_reviews
for each row execute function public.emit_review_social_activity();

create function public.list_following_activity(
  p_before_published_at timestamptz default null,
  p_before_id uuid default null,
  p_limit integer default 50
)
returns setof public.social_activity_events
language plpgsql
stable
security invoker
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'activity page size must be between 1 and 100' using errcode = '22023';
  end if;
  if (p_before_published_at is null) <> (p_before_id is null) then
    raise exception 'activity cursor timestamp and id must be provided together'
      using errcode = '22023';
  end if;

  return query
  select event.*
  from public.social_activity_events event
  where (
    p_before_published_at is null
    or event.published_at < p_before_published_at
    or (event.published_at = p_before_published_at and event.id < p_before_id)
  )
  order by event.published_at desc, event.id desc
  limit p_limit;
end;
$$;

create function public.list_profile_listening_diary(
  p_profile_id uuid,
  p_before_played_at timestamptz default null,
  p_before_id uuid default null,
  p_limit integer default 50
)
returns setof public.listening_history_entries
language plpgsql
stable
security invoker
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'profile diary page size must be between 1 and 100' using errcode = '22023';
  end if;
  if (p_before_played_at is null) <> (p_before_id is null) then
    raise exception 'profile diary cursor timestamp and id must be provided together'
      using errcode = '22023';
  end if;

  return query
  select entry.*
  from public.listening_history_entries entry
  where entry.profile_id = p_profile_id
    and entry.source = 'manual'
    and (
      p_profile_id = auth.uid()
      or (
        not public.social_accounts_are_blocked(auth.uid(), p_profile_id)
        and public.is_accepted_follower(p_profile_id)
      )
    )
    and public.can_view_social(entry.profile_id, entry.visibility)
    and (
      p_before_played_at is null
      or entry.played_at < p_before_played_at
      or (entry.played_at = p_before_played_at and entry.id < p_before_id)
    )
  order by entry.played_at desc, entry.id desc
  limit p_limit;
end;
$$;

create function public.list_profile_music_reviews(
  p_profile_id uuid,
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
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'profile review page size must be between 1 and 100' using errcode = '22023';
  end if;
  if (p_before_created_at is null) <> (p_before_id is null) then
    raise exception 'profile review cursor timestamp and id must be provided together'
      using errcode = '22023';
  end if;

  return query
  select review.*
  from public.music_reviews review
  where review.profile_id = p_profile_id
    and review.deleted_at is null
    and (
      p_profile_id = auth.uid()
      or (
        not public.social_accounts_are_blocked(auth.uid(), p_profile_id)
        and public.is_accepted_follower(p_profile_id)
      )
    )
    and public.can_view_social(review.profile_id, review.visibility)
    and (
      p_before_created_at is null
      or review.created_at < p_before_created_at
      or (review.created_at = p_before_created_at and review.id < p_before_id)
    )
  order by review.created_at desc, review.id desc
  limit p_limit;
end;
$$;

create function public.list_profile_loved_tracks(
  p_profile_id uuid,
  p_before_updated_at timestamptz default null,
  p_before_canonical_track_id uuid default null,
  p_limit integer default 50
)
returns setof public.profile_track_subject_states
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if p_limit is null or p_limit < 1 or p_limit > 100 then
    raise exception 'Loved page size must be between 1 and 100' using errcode = '22023';
  end if;
  if (p_before_updated_at is null) <> (p_before_canonical_track_id is null) then
    raise exception 'Loved cursor timestamp and canonical track id must be provided together'
      using errcode = '22023';
  end if;

  return query
  select state.*
  from public.profile_track_subject_states state
  join public.profile_social_settings settings on settings.profile_id = state.profile_id
  where state.profile_id = p_profile_id
    and state.is_loved
    and (
      p_profile_id = auth.uid()
      or (
        settings.shelf_visibility = 'followers'
        and not public.social_accounts_are_blocked(auth.uid(), p_profile_id)
        and public.is_accepted_follower(p_profile_id)
      )
    )
    and (
      p_before_updated_at is null
      or state.updated_at < p_before_updated_at
      or (
        state.updated_at = p_before_updated_at
        and state.canonical_track_id < p_before_canonical_track_id
      )
    )
  order by state.updated_at desc, state.canonical_track_id desc
  limit p_limit;
end;
$$;

revoke all on function public.emit_diary_social_activity() from public;
revoke all on function public.emit_review_social_activity() from public;
revoke all on function public.list_following_activity(timestamptz, uuid, integer) from public;
revoke all on function public.list_profile_listening_diary(uuid, timestamptz, uuid, integer) from public;
revoke all on function public.list_profile_music_reviews(uuid, timestamptz, uuid, integer) from public;
revoke all on function public.list_profile_loved_tracks(uuid, timestamptz, uuid, integer) from public;
grant execute on function public.list_following_activity(timestamptz, uuid, integer) to authenticated;
grant execute on function public.list_profile_listening_diary(uuid, timestamptz, uuid, integer) to authenticated;
grant execute on function public.list_profile_music_reviews(uuid, timestamptz, uuid, integer) to authenticated;
grant execute on function public.list_profile_loved_tracks(uuid, timestamptz, uuid, integer) to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'social_activity_events'
  ) then
    alter publication supabase_realtime add table public.social_activity_events;
  end if;
end;
$$;
