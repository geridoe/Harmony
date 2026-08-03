create table public.social_notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  actor_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('follow_request', 'follow_accepted', 'review_comment', 'review_reaction')),
  review_id uuid references public.music_reviews(id) on delete cascade,
  created_at timestamptz not null default now(),
  read_at timestamptz,
  check (recipient_id <> actor_id)
);

create index social_notifications_recipient_created_idx
  on public.social_notifications(recipient_id, created_at desc);

alter table public.social_notifications enable row level security;
create policy "recipients view unblocked social notifications" on public.social_notifications
for select to authenticated using (
  recipient_id = auth.uid()
  and not public.social_accounts_are_blocked(recipient_id, actor_id)
);
revoke insert, update, delete on public.social_notifications from authenticated;

create function public.notify_social_follow_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' and new.state = 'requested' then
    insert into public.social_notifications(recipient_id, actor_id, kind)
    values (new.followed_id, new.follower_id, 'follow_request');
  elsif tg_op = 'UPDATE' and old.state = 'requested' and new.state = 'accepted' then
    insert into public.social_notifications(recipient_id, actor_id, kind)
    values (new.follower_id, new.followed_id, 'follow_accepted');
  end if;
  return new;
end;
$$;
create trigger social_follows_notify after insert or update of state on public.social_follows
for each row execute function public.notify_social_follow_change();

create function public.notify_review_comment()
returns trigger language plpgsql security definer set search_path = public as $$
declare owner_id uuid;
begin
  select profile_id into owner_id from public.music_reviews where id = new.review_id and deleted_at is null;
  if owner_id is not null and owner_id <> new.author_id then
    insert into public.social_notifications(recipient_id, actor_id, kind, review_id)
    values (owner_id, new.author_id, 'review_comment', new.review_id);
  end if;
  return new;
end;
$$;
create trigger review_comments_notify after insert on public.review_comments
for each row execute function public.notify_review_comment();

create function public.notify_review_reaction()
returns trigger language plpgsql security definer set search_path = public as $$
declare owner_id uuid;
begin
  select profile_id into owner_id from public.music_reviews where id = new.review_id and deleted_at is null;
  if owner_id is not null and owner_id <> new.profile_id then
    insert into public.social_notifications(recipient_id, actor_id, kind, review_id)
    values (owner_id, new.profile_id, 'review_reaction', new.review_id);
  end if;
  return new;
end;
$$;
create trigger review_reactions_notify after insert on public.review_reactions
for each row execute function public.notify_review_reaction();

create function public.mark_social_notifications_read(p_notification_id uuid default null)
returns integer language plpgsql security definer set search_path = public as $$
declare affected integer;
begin
  if auth.uid() is null then raise exception 'authentication required' using errcode = '28000'; end if;
  update public.social_notifications
    set read_at = coalesce(read_at, now())
    where recipient_id = auth.uid()
      and (p_notification_id is null or id = p_notification_id);
  get diagnostics affected = row_count;
  return affected;
end;
$$;

revoke all on function public.mark_social_notifications_read(uuid) from public;
grant execute on function public.mark_social_notifications_read(uuid) to authenticated;

alter publication supabase_realtime add table public.social_notifications;
