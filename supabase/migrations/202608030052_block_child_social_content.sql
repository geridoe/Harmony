-- Blocking hides identity-bearing child content in both directions, even when
-- the viewer still owns/can view the parent review or listening broadcast.
-- Parent engagement totals remain exhaustive by product contract: aggregate
-- numbers are non-identity-bearing, while child rows and author identities are
-- filtered for each viewer.

create index if not exists profile_blocks_blocked_blocker_idx
  on public.profile_blocks(blocked_id, blocker_id);

drop policy if exists "view comments on visible reviews" on public.review_comments;
create policy "view unblocked comments on visible reviews"
on public.review_comments
for select to authenticated
using (
  deleted_at is null
  and public.can_view_music_review(review_id)
  and not public.social_accounts_are_blocked(auth.uid(), author_id)
);

drop policy if exists "view reactions on visible reviews" on public.review_reactions;
create policy "view unblocked reactions on visible reviews"
on public.review_reactions
for select to authenticated
using (
  public.can_view_music_review(review_id)
  and not public.social_accounts_are_blocked(auth.uid(), profile_id)
);

drop policy if exists "view comments on permitted listening broadcasts"
  on public.listening_broadcast_comments;
create policy "view unblocked comments on permitted listening broadcasts"
on public.listening_broadcast_comments
for select to authenticated
using (
  deleted_at is null
  and public.can_view_listening_broadcast(broadcast_id)
  and not public.social_accounts_are_blocked(auth.uid(), author_id)
);

drop policy if exists "view reactions on permitted listening broadcasts"
  on public.listening_broadcast_reactions;
create policy "view unblocked reactions on permitted listening broadcasts"
on public.listening_broadcast_reactions
for select to authenticated
using (
  public.can_view_listening_broadcast(broadcast_id)
  and not public.social_accounts_are_blocked(auth.uid(), profile_id)
);

-- Mutation RPCs already reject interaction across a block through their
-- parent visibility checks. Repeat the predicate in notification triggers so
-- future trusted writers and concurrent policy changes cannot manufacture a
-- blocked notification as a side effect.
create or replace function public.notify_review_comment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_owner_id uuid;
begin
  select profile_id into v_owner_id
  from public.music_reviews
  where id = new.review_id and deleted_at is null;

  if v_owner_id is not null
     and v_owner_id <> new.author_id
     and not public.social_accounts_are_blocked(v_owner_id, new.author_id) then
    insert into public.social_notifications(recipient_id, actor_id, kind, review_id)
    values (v_owner_id, new.author_id, 'review_comment', new.review_id);
  end if;
  return new;
end;
$$;

create or replace function public.notify_review_reaction()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_owner_id uuid;
begin
  select profile_id into v_owner_id
  from public.music_reviews
  where id = new.review_id and deleted_at is null;

  if v_owner_id is not null
     and v_owner_id <> new.profile_id
     and not public.social_accounts_are_blocked(v_owner_id, new.profile_id) then
    insert into public.social_notifications(recipient_id, actor_id, kind, review_id)
    values (v_owner_id, new.profile_id, 'review_reaction', new.review_id);
  end if;
  return new;
end;
$$;

create or replace function public.notify_listening_broadcast_comment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_host_id uuid;
begin
  select host_profile_id into v_host_id
  from public.listening_broadcasts
  where id = new.broadcast_id;

  if v_host_id is not null
     and v_host_id <> new.author_id
     and not public.social_accounts_are_blocked(v_host_id, new.author_id) then
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

create or replace function public.notify_listening_broadcast_reaction()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_host_id uuid;
begin
  select host_profile_id into v_host_id
  from public.listening_broadcasts
  where id = new.broadcast_id;

  if v_host_id is not null
     and v_host_id <> new.profile_id
     and not public.social_accounts_are_blocked(v_host_id, new.profile_id) then
    insert into public.social_notifications(
      recipient_id, actor_id, kind, listening_broadcast_id
    ) values (
      v_host_id, new.profile_id, 'listening_broadcast_reaction', new.broadcast_id
    );
  end if;
  return new;
end;
$$;

comment on function public.get_review_engagement(uuid) is
  'Returns exhaustive non-identity-bearing heart/comment totals plus caller-specific heart state. Child lists independently omit authors blocked in either direction, so a visible list may be shorter than its exhaustive total.';
