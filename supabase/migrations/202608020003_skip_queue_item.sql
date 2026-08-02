-- Advance the canonical Harmony queue as one idempotent Conductor command.
-- Provider playback remains a device-side effect after this transaction commits.
create or replace function public.skip_queue_item(
  p_session_id uuid,
  p_command_id uuid,
  p_expected_revision bigint
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_id uuid := auth.uid();
  v_session public.sessions%rowtype;
  v_role public.session_role;
  v_existing public.queue_events%rowtype;
  v_skipped_item_id uuid;
  v_new_revision bigint;
begin
  if v_actor_id is null then raise exception 'authentication required' using errcode = '28000'; end if;
  if p_command_id is null then raise exception 'command_id is required' using errcode = '22023'; end if;
  if p_expected_revision is null or p_expected_revision < 0 then
    raise exception 'a non-negative expected_revision is required' using errcode = '22023';
  end if;

  select * into v_existing
  from public.queue_events
  where session_id = p_session_id and command_id = p_command_id;
  if found then
    if v_existing.actor_id <> v_actor_id then
      raise exception 'command id already belongs to another user' using errcode = '42501';
    end if;
    return jsonb_build_object(
      'status', 'applied', 'idempotent', true,
      'revision', v_existing.revision, 'event_id', v_existing.id
    );
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_session_id::text, 0));
  select * into v_session from public.sessions where id = p_session_id for update;
  if not found or v_session.ended_at is not null or
     (v_session.expires_at is not null and v_session.expires_at <= now()) then
    raise exception 'session not available' using errcode = 'P0002';
  end if;
  select role into v_role from public.session_members
  where session_id = p_session_id and profile_id = v_actor_id;
  if not found or v_role <> 'conductor' then
    raise exception 'only the conductor controls playback' using errcode = '42501';
  end if;
  if p_expected_revision <> v_session.queue_revision then
    return jsonb_build_object('status', 'conflict', 'revision', v_session.queue_revision);
  end if;

  select id into v_skipped_item_id
  from public.queue_items
  where session_id = p_session_id
  order by position
  limit 1
  for update;
  if v_skipped_item_id is null then
    raise exception 'queue is empty' using errcode = 'P0002';
  end if;
  delete from public.queue_items where id = v_skipped_item_id;

  v_new_revision := v_session.queue_revision + 1;
  update public.sessions
  set queue_revision = v_new_revision,
      playback_state = jsonb_build_object('status', 'playing')
  where id = p_session_id;
  insert into public.queue_events(session_id, revision, command_id, actor_id, type, payload)
  values (
    p_session_id, v_new_revision, p_command_id, v_actor_id, 'skip',
    jsonb_build_object('skipped_queue_item_id', v_skipped_item_id)
  );

  return jsonb_build_object(
    'status', 'applied', 'idempotent', false,
    'revision', v_new_revision, 'skipped_queue_item_id', v_skipped_item_id
  );
end;
$$;

grant execute on function public.skip_queue_item(uuid, uuid, bigint) to authenticated;
