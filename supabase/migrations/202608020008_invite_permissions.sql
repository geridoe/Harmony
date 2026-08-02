-- The Conductor controls whether collaborators may reveal/share the room code
-- in Harmony. Direct session writes stay revoked; this is the only mutation
-- boundary exposed to authenticated clients.
create or replace function public.set_harmony_collaborator_invites(
  p_session_id uuid,
  p_allow_collaborator_invites boolean
)
returns public.sessions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_session public.sessions%rowtype;
begin
  if v_actor_id is null then
    raise exception 'authentication required' using errcode = '28000';
  end if;

  select * into v_session
  from public.sessions
  where id = p_session_id
  for update;
  if not found or v_session.ended_at is not null or
     (v_session.expires_at is not null and v_session.expires_at <= now()) then
    raise exception 'session not available' using errcode = 'P0002';
  end if;
  if v_session.conductor_id <> v_actor_id then
    raise exception 'only the conductor may update invite permissions' using errcode = '42501';
  end if;

  update public.sessions
  set allow_collaborator_invites = p_allow_collaborator_invites
  where id = p_session_id
  returning * into v_session;
  return v_session;
end;
$$;

grant execute on function public.set_harmony_collaborator_invites(uuid, boolean) to authenticated;
