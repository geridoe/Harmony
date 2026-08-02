-- Privacy-first social graph. Listening activity and reviews will use these
-- helpers so visibility is enforced in Postgres rather than only in SwiftUI.
do $$ begin
  create type public.social_visibility as enum ('private', 'followers', 'public');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type public.follow_state as enum ('requested', 'accepted');
exception when duplicate_object then null;
end $$;

create table if not exists public.profile_social_settings (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  live_visibility public.social_visibility not null default 'private',
  history_visibility public.social_visibility not null default 'private',
  reviews_visibility public.social_visibility not null default 'followers',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.social_follows (
  follower_id uuid not null references public.profiles(id) on delete cascade,
  followed_id uuid not null references public.profiles(id) on delete cascade,
  state public.follow_state not null default 'requested',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (follower_id, followed_id),
  check (follower_id <> followed_id)
);

create table if not exists public.profile_blocks (
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);

insert into public.profile_social_settings(profile_id)
select id from public.profiles
on conflict (profile_id) do nothing;

create trigger profile_social_settings_updated_at before update on public.profile_social_settings
for each row execute function public.set_updated_at();
create trigger social_follows_updated_at before update on public.social_follows
for each row execute function public.set_updated_at();

create or replace function public.create_profile_social_settings()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profile_social_settings(profile_id) values (new.id)
  on conflict (profile_id) do nothing;
  return new;
end;
$$;
create trigger profiles_create_social_settings after insert on public.profiles
for each row execute function public.create_profile_social_settings();

alter table public.profile_social_settings enable row level security;
alter table public.social_follows enable row level security;
alter table public.profile_blocks enable row level security;

create policy "users read their social settings" on public.profile_social_settings
for select to authenticated using (profile_id = auth.uid());
create policy "users update their social settings" on public.profile_social_settings
for update to authenticated using (profile_id = auth.uid()) with check (profile_id = auth.uid());
create policy "people read their own follow edges" on public.social_follows
for select to authenticated using (follower_id = auth.uid() or followed_id = auth.uid());
create policy "users read their own blocks" on public.profile_blocks
for select to authenticated using (blocker_id = auth.uid());

revoke insert, update, delete on public.social_follows, public.profile_blocks from authenticated;

create or replace function public.social_accounts_are_blocked(p_left_id uuid, p_right_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profile_blocks
    where (blocker_id = p_left_id and blocked_id = p_right_id)
       or (blocker_id = p_right_id and blocked_id = p_left_id)
  );
$$;

create or replace function public.is_accepted_follower(p_owner_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.social_follows
    where follower_id = auth.uid() and followed_id = p_owner_id and state = 'accepted'
  );
$$;

create or replace function public.can_view_social(p_owner_id uuid, p_visibility public.social_visibility)
returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() = p_owner_id
      or (
        not public.social_accounts_are_blocked(auth.uid(), p_owner_id)
        and (p_visibility = 'public' or (p_visibility = 'followers' and public.is_accepted_follower(p_owner_id)))
      );
$$;

create or replace function public.request_social_follow(p_profile_id uuid)
returns public.social_follows
language plpgsql security definer set search_path = public as $$
declare
  v_actor_id uuid := auth.uid();
  v_follow public.social_follows%rowtype;
begin
  if v_actor_id is null then raise exception 'authentication required' using errcode = '28000'; end if;
  if p_profile_id is null or p_profile_id = v_actor_id then raise exception 'choose another profile' using errcode = '22023'; end if;
  if not exists (select 1 from public.profiles where id = p_profile_id) then raise exception 'profile not found' using errcode = 'P0002'; end if;
  if public.social_accounts_are_blocked(v_actor_id, p_profile_id) then raise exception 'this profile is unavailable' using errcode = '42501'; end if;
  insert into public.social_follows(follower_id, followed_id, state)
  values (v_actor_id, p_profile_id, 'requested')
  on conflict (follower_id, followed_id) do update set state = public.social_follows.state
  returning * into v_follow;
  return v_follow;
end;
$$;

create or replace function public.respond_to_social_follow(p_requester_id uuid, p_accept boolean)
returns boolean
language plpgsql security definer set search_path = public as $$
declare v_actor_id uuid := auth.uid();
begin
  if v_actor_id is null then raise exception 'authentication required' using errcode = '28000'; end if;
  if p_accept then
    update public.social_follows set state = 'accepted'
    where follower_id = p_requester_id and followed_id = v_actor_id and state = 'requested';
    if not found then raise exception 'follow request not found' using errcode = 'P0002'; end if;
  else
    delete from public.social_follows where follower_id = p_requester_id and followed_id = v_actor_id;
  end if;
  return true;
end;
$$;

create or replace function public.remove_social_follow(p_profile_id uuid)
returns boolean
language plpgsql security definer set search_path = public as $$
declare v_actor_id uuid := auth.uid();
begin
  if v_actor_id is null then raise exception 'authentication required' using errcode = '28000'; end if;
  delete from public.social_follows
  where (follower_id = v_actor_id and followed_id = p_profile_id)
     or (follower_id = p_profile_id and followed_id = v_actor_id);
  return true;
end;
$$;

create or replace function public.block_social_profile(p_profile_id uuid)
returns boolean
language plpgsql security definer set search_path = public as $$
declare v_actor_id uuid := auth.uid();
begin
  if v_actor_id is null then raise exception 'authentication required' using errcode = '28000'; end if;
  if p_profile_id is null or p_profile_id = v_actor_id then raise exception 'choose another profile' using errcode = '22023'; end if;
  insert into public.profile_blocks(blocker_id, blocked_id) values (v_actor_id, p_profile_id) on conflict do nothing;
  delete from public.social_follows
  where (follower_id = v_actor_id and followed_id = p_profile_id)
     or (follower_id = p_profile_id and followed_id = v_actor_id);
  return true;
end;
$$;

revoke all on function public.social_accounts_are_blocked(uuid, uuid), public.is_accepted_follower(uuid), public.can_view_social(uuid, public.social_visibility) from public;
grant execute on function public.social_accounts_are_blocked(uuid, uuid), public.is_accepted_follower(uuid), public.can_view_social(uuid, public.social_visibility) to authenticated;
grant execute on function public.request_social_follow(uuid), public.respond_to_social_follow(uuid, boolean), public.remove_social_follow(uuid), public.block_social_profile(uuid) to authenticated;
