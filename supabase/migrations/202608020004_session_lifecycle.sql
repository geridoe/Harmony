create or replace function public.end_harmony_session(p_session_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'authentication required' using errcode = '28000'; end if;
  update public.sessions
  set ended_at = now()
  where id = p_session_id and conductor_id = auth.uid() and ended_at is null;
  if not found then raise exception 'only the conductor may end an active session' using errcode = '42501'; end if;
end;
$$;

create or replace function public.leave_harmony_session(p_session_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role public.session_role;
begin
  if auth.uid() is null then raise exception 'authentication required' using errcode = '28000'; end if;
  select role into v_role from public.session_members
  where session_id = p_session_id and profile_id = auth.uid();
  if not found then return; end if;
  if v_role = 'conductor' then
    raise exception 'the conductor must end the session' using errcode = '42501';
  end if;
  delete from public.session_members
  where session_id = p_session_id and profile_id = auth.uid();
end;
$$;

grant execute on function public.end_harmony_session(uuid) to authenticated;
grant execute on function public.leave_harmony_session(uuid) to authenticated;
