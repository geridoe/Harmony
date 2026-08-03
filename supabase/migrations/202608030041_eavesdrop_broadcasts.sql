-- Stable, permission-aware identity and conversation for short-lived
-- now-listening cards. Audio and provider credentials never enter this model.

do $$ begin
  create type public.listening_broadcast_reaction_kind
    as enum ('heart', 'fire', 'headphones');
exception when duplicate_object then null;
end $$;

create table public.listening_broadcasts (
  id uuid primary key default gen_random_uuid(),
  host_profile_id uuid not null references public.profiles(id) on delete cascade,
  visibility public.social_visibility not null default 'followers',
  started_at timestamptz not null,
  expires_at timestamptz not null,
  ended_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (expires_at > started_at),
  check (ended_at is null or ended_at >= started_at)
);

create index listening_broadcasts_host_started_idx
  on public.listening_broadcasts(host_profile_id, started_at desc);
create index listening_broadcasts_active_idx
  on public.listening_broadcasts(expires_at)
  where ended_at is null;

create trigger listening_broadcasts_updated_at
before update on public.listening_broadcasts
for each row execute function public.set_updated_at();

alter table public.listening_presence add column broadcast_id uuid;

insert into public.listening_broadcasts(
  id, host_profile_id, visibility, started_at, expires_at, ended_at
)
select
  gen_random_uuid(), presence.profile_id, presence.visibility,
  presence.started_at, presence.expires_at,
  case when presence.expires_at <= now() then presence.expires_at else null end
from public.listening_presence presence;

update public.listening_presence presence
set broadcast_id = broadcast.id
from public.listening_broadcasts broadcast
where broadcast.host_profile_id = presence.profile_id
  and broadcast.started_at = presence.started_at
  and broadcast.expires_at = presence.expires_at;

alter table public.listening_presence
  alter column broadcast_id set not null,
  add constraint listening_presence_broadcast_unique unique (broadcast_id),
  add constraint listening_presence_broadcast_fkey
    foreign key (broadcast_id) references public.listening_broadcasts(id)
    on delete cascade;

create table public.listening_broadcast_comments (
  id uuid primary key default gen_random_uuid(),
  broadcast_id uuid not null
    references public.listening_broadcasts(id) on delete cascade,
  author_id uuid not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(btrim(body)) between 1 and 2000),
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table public.listening_broadcast_reactions (
  broadcast_id uuid not null
    references public.listening_broadcasts(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  kind public.listening_broadcast_reaction_kind not null,
  created_at timestamptz not null default now(),
  primary key (broadcast_id, profile_id, kind)
);

create index listening_broadcast_comments_page_idx
  on public.listening_broadcast_comments(broadcast_id, created_at, id)
  where deleted_at is null;

create function public.can_view_listening_broadcast(p_broadcast_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.listening_broadcasts broadcast
    where broadcast.id = p_broadcast_id
      and (
        broadcast.host_profile_id = auth.uid()
        or (
          broadcast.ended_at is null
          and broadcast.expires_at > now()
          and public.can_view_social(
            broadcast.host_profile_id,
            broadcast.visibility
          )
        )
      )
  );
$$;

alter table public.listening_broadcasts enable row level security;
alter table public.listening_broadcast_comments enable row level security;
alter table public.listening_broadcast_reactions enable row level security;

create policy "view permitted listening broadcasts"
on public.listening_broadcasts for select to authenticated
using (public.can_view_listening_broadcast(id));
create policy "view comments on permitted listening broadcasts"
on public.listening_broadcast_comments for select to authenticated
using (deleted_at is null and public.can_view_listening_broadcast(broadcast_id));
create policy "view reactions on permitted listening broadcasts"
on public.listening_broadcast_reactions for select to authenticated
using (public.can_view_listening_broadcast(broadcast_id));

revoke insert, update, delete on public.listening_broadcasts,
  public.listening_broadcast_comments, public.listening_broadcast_reactions
from authenticated;
grant select on public.listening_broadcasts,
  public.listening_broadcast_comments, public.listening_broadcast_reactions
to authenticated;

create function public.assign_listening_broadcast()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_reuse boolean := false;
begin
  if tg_op = 'UPDATE' then
    v_reuse := old.expires_at > now()
      and old.broadcast_id is not null
      and old.canonical_track_id is not distinct from new.canonical_track_id
      and old.provider is not distinct from new.provider
      and old.provider_track_id is not distinct from new.provider_track_id;
  end if;

  if v_reuse then
    new.broadcast_id := old.broadcast_id;
    update public.listening_broadcasts
    set visibility = new.visibility,
        expires_at = new.expires_at,
        ended_at = null
    where id = old.broadcast_id;
  else
    if tg_op = 'UPDATE' and old.broadcast_id is not null then
      update public.listening_broadcasts
      set ended_at = coalesce(ended_at, now())
      where id = old.broadcast_id;
    end if;
    insert into public.listening_broadcasts(
      host_profile_id, visibility, started_at, expires_at
    ) values (
      new.profile_id, new.visibility, new.started_at, new.expires_at
    ) returning id into new.broadcast_id;
  end if;
  return new;
end;
$$;

create function public.close_listening_broadcast()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.listening_broadcasts
  set ended_at = coalesce(ended_at, now())
  where id = old.broadcast_id;
  return old;
end;
$$;

create trigger listening_presence_assign_broadcast
before insert or update of canonical_track_id, provider, provider_track_id,
  visibility, started_at, expires_at
on public.listening_presence
for each row execute function public.assign_listening_broadcast();

create trigger listening_presence_close_broadcast
after delete on public.listening_presence
for each row execute function public.close_listening_broadcast();

create function public.add_listening_broadcast_comment(
  p_broadcast_id uuid,
  p_body text
)
returns public.listening_broadcast_comments
language plpgsql
security definer
set search_path = public
as $$
declare
  v_comment public.listening_broadcast_comments%rowtype;
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if not exists (
    select 1 from public.listening_broadcasts broadcast
    where broadcast.id = p_broadcast_id
      and broadcast.ended_at is null
      and broadcast.expires_at > now()
      and public.can_view_social(broadcast.host_profile_id, broadcast.visibility)
  ) then
    raise exception 'listening broadcast unavailable' using errcode = '42501';
  end if;
  insert into public.listening_broadcast_comments(broadcast_id, author_id, body)
  values (p_broadcast_id, auth.uid(), btrim(p_body))
  returning * into v_comment;
  return v_comment;
end;
$$;

create function public.delete_listening_broadcast_comment(p_comment_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  update public.listening_broadcast_comments comment
  set deleted_at = now()
  from public.listening_broadcasts broadcast
  where comment.id = p_comment_id
    and broadcast.id = comment.broadcast_id
    and comment.deleted_at is null
    and (comment.author_id = auth.uid() or broadcast.host_profile_id = auth.uid());
  return found;
end;
$$;

create function public.toggle_listening_broadcast_reaction(
  p_broadcast_id uuid,
  p_kind public.listening_broadcast_reaction_kind
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;
  if not exists (
    select 1 from public.listening_broadcasts broadcast
    where broadcast.id = p_broadcast_id
      and broadcast.ended_at is null
      and broadcast.expires_at > now()
      and public.can_view_social(broadcast.host_profile_id, broadcast.visibility)
  ) then
    raise exception 'listening broadcast unavailable' using errcode = '42501';
  end if;
  delete from public.listening_broadcast_reactions
  where broadcast_id = p_broadcast_id
    and profile_id = auth.uid()
    and kind = p_kind;
  if found then return false; end if;
  insert into public.listening_broadcast_reactions(broadcast_id, profile_id, kind)
  values (p_broadcast_id, auth.uid(), p_kind);
  return true;
end;
$$;

create function public.list_eavesdrop_broadcasts(
  p_broadcast_id uuid default null,
  p_viewer_provider public.music_provider default null,
  p_storefront text default 'us'
)
returns table (
  broadcast_id uuid,
  host_profile_id uuid,
  host_display_name text,
  status text,
  visibility public.social_visibility,
  canonical_track_id uuid,
  track_title text,
  track_artist text,
  track_album text,
  track_duration_ms integer,
  track_artwork_url text,
  track_is_explicit boolean,
  started_at timestamptz,
  expires_at timestamptz,
  updated_at timestamptz,
  source_provider text,
  source_deep_link text,
  viewer_provider text,
  viewer_provider_track_id text,
  viewer_provider_deep_link text,
  viewer_availability text
)
language sql
stable
security invoker
set search_path = public
as $$
  select
    broadcast.id,
    broadcast.host_profile_id,
    profile.display_name,
    presence.status::text,
    broadcast.visibility,
    presence.canonical_track_id,
    track.title,
    track.artist,
    track.album,
    track.duration_ms,
    track.artwork_url,
    track.is_explicit,
    broadcast.started_at,
    broadcast.expires_at,
    greatest(broadcast.updated_at, presence.updated_at),
    presence.provider::text,
    presence.provider_deep_link,
    mapping.provider::text,
    mapping.provider_id,
    mapping.deep_link,
    mapping.availability::text
  from public.listening_broadcasts broadcast
  join public.listening_presence presence
    on presence.broadcast_id = broadcast.id
  join public.profiles profile on profile.id = broadcast.host_profile_id
  left join public.canonical_tracks track on track.id = presence.canonical_track_id
  left join lateral (
    select provider_track.*
    from public.provider_tracks provider_track
    where provider_track.canonical_track_id = presence.canonical_track_id
      and provider_track.provider = p_viewer_provider
    order by
      (provider_track.storefront = lower(coalesce(p_storefront, 'us'))) desc,
      (provider_track.storefront = 'global') desc,
      provider_track.created_at desc
    limit 1
  ) mapping on true
  where broadcast.ended_at is null
    and broadcast.expires_at > now()
    and public.can_view_social(broadcast.host_profile_id, broadcast.visibility)
    and (p_broadcast_id is null or broadcast.id = p_broadcast_id)
  order by broadcast.updated_at desc, broadcast.id desc;
$$;

alter table public.social_notifications
  add column listening_broadcast_id uuid
    references public.listening_broadcasts(id) on delete cascade,
  add column listening_broadcast_comment_id uuid
    references public.listening_broadcast_comments(id) on delete cascade;
alter table public.social_notifications
  drop constraint if exists social_notifications_kind_check,
  drop constraint if exists social_notifications_object_shape;
alter table public.social_notifications
  add constraint social_notifications_kind_check check (
    kind in (
      'follow_request', 'follow_accepted', 'review_comment', 'review_reaction',
      'music_list_like', 'music_list_comment',
      'listening_broadcast_comment', 'listening_broadcast_reaction'
    )
  ),
  add constraint social_notifications_object_shape check (
    (kind in ('follow_request', 'follow_accepted')
      and review_id is null and music_list_id is null
      and music_list_comment_id is null and listening_broadcast_id is null
      and listening_broadcast_comment_id is null)
    or (kind in ('review_comment', 'review_reaction')
      and review_id is not null and music_list_id is null
      and music_list_comment_id is null and listening_broadcast_id is null
      and listening_broadcast_comment_id is null)
    or (kind = 'music_list_like' and review_id is null
      and music_list_id is not null and music_list_comment_id is null
      and listening_broadcast_id is null and listening_broadcast_comment_id is null)
    or (kind = 'music_list_comment' and review_id is null
      and music_list_id is not null and music_list_comment_id is not null
      and listening_broadcast_id is null and listening_broadcast_comment_id is null)
    or (kind = 'listening_broadcast_reaction' and review_id is null
      and music_list_id is null and music_list_comment_id is null
      and listening_broadcast_id is not null
      and listening_broadcast_comment_id is null)
    or (kind = 'listening_broadcast_comment' and review_id is null
      and music_list_id is null and music_list_comment_id is null
      and listening_broadcast_id is not null
      and listening_broadcast_comment_id is not null)
  );

create function public.notify_listening_broadcast_comment()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_host_id uuid;
begin
  select host_profile_id into v_host_id
  from public.listening_broadcasts where id = new.broadcast_id;
  if v_host_id is not null and v_host_id <> new.author_id then
    insert into public.social_notifications(
      recipient_id, actor_id, kind, listening_broadcast_id,
      listening_broadcast_comment_id
    ) values (
      v_host_id, new.author_id, 'listening_broadcast_comment',
      new.broadcast_id, new.id
    );
  end if;
  return new;
end;
$$;

create function public.notify_listening_broadcast_reaction()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_host_id uuid;
begin
  select host_profile_id into v_host_id
  from public.listening_broadcasts where id = new.broadcast_id;
  if v_host_id is not null and v_host_id <> new.profile_id then
    insert into public.social_notifications(
      recipient_id, actor_id, kind, listening_broadcast_id
    ) values (
      v_host_id, new.profile_id, 'listening_broadcast_reaction', new.broadcast_id
    );
  end if;
  return new;
end;
$$;

create trigger listening_broadcast_comments_notify
after insert on public.listening_broadcast_comments
for each row execute function public.notify_listening_broadcast_comment();
create trigger listening_broadcast_reactions_notify
after insert on public.listening_broadcast_reactions
for each row execute function public.notify_listening_broadcast_reaction();

alter publication supabase_realtime add table public.listening_broadcasts;
alter publication supabase_realtime add table public.listening_broadcast_comments;
alter publication supabase_realtime add table public.listening_broadcast_reactions;

revoke all on function public.can_view_listening_broadcast(uuid) from public;
revoke all on function public.add_listening_broadcast_comment(uuid, text) from public;
revoke all on function public.delete_listening_broadcast_comment(uuid) from public;
revoke all on function public.toggle_listening_broadcast_reaction(
  uuid, public.listening_broadcast_reaction_kind
) from public;
revoke all on function public.list_eavesdrop_broadcasts(
  uuid, public.music_provider, text
) from public;
grant execute on function public.can_view_listening_broadcast(uuid) to authenticated;
grant execute on function public.add_listening_broadcast_comment(uuid, text) to authenticated;
grant execute on function public.delete_listening_broadcast_comment(uuid) to authenticated;
grant execute on function public.toggle_listening_broadcast_reaction(
  uuid, public.listening_broadcast_reaction_kind
) to authenticated;
grant execute on function public.list_eavesdrop_broadcasts(
  uuid, public.music_provider, text
) to authenticated;
