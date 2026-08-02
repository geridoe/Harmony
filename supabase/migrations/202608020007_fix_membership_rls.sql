-- Avoid recursive RLS evaluation when collaboration policies verify that the
-- current user belongs to a session. The helper exposes only a boolean for the
-- caller's own JWT identity and cannot be used to inspect another profile.
create or replace function public.is_session_member(p_session_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.session_members
    where session_id = p_session_id
      and profile_id = auth.uid()
  );
$$;

revoke all on function public.is_session_member(uuid) from public;
grant execute on function public.is_session_member(uuid) to authenticated;

drop policy if exists "members read their sessions" on public.sessions;
create policy "members read their sessions"
on public.sessions for select to authenticated
using (public.is_session_member(id));

drop policy if exists "members read session members" on public.session_members;
create policy "members read session members"
on public.session_members for select to authenticated
using (public.is_session_member(session_id));

drop policy if exists "members read queue items" on public.queue_items;
create policy "members read queue items"
on public.queue_items for select to authenticated
using (public.is_session_member(session_id));

drop policy if exists "members read queue events" on public.queue_events;
create policy "members read queue events"
on public.queue_events for select to authenticated
using (public.is_session_member(session_id));
