-- Queue-only rooms must not accept playback mutations, even from a client
-- that bypasses Harmony's UI.
create or replace function public.apply_queue_command(
  p_session_id uuid,
  p_command_id uuid,
  p_expected_revision bigint,
  p_type public.queue_command_type,
  p_payload jsonb default '{}'::jsonb
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
  v_item public.queue_items%rowtype;
  v_new_revision bigint;
  v_position double precision;
  v_track_id uuid;
  v_target_item_id uuid;
begin
  if v_actor_id is null then raise exception 'authentication required' using errcode = '28000'; end if;
  if p_command_id is null then raise exception 'command_id is required' using errcode = '22023'; end if;
  if p_expected_revision is null or p_expected_revision < 0 then raise exception 'a non-negative expected_revision is required' using errcode = '22023'; end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then raise exception 'payload must be an object' using errcode = '22023'; end if;

  select * into v_existing from public.queue_events where session_id = p_session_id and command_id = p_command_id;
  if found then
    if v_existing.actor_id <> v_actor_id then raise exception 'command id already belongs to another user' using errcode = '42501'; end if;
    return jsonb_build_object('status', 'applied', 'idempotent', true, 'revision', v_existing.revision, 'event_id', v_existing.id);
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_session_id::text, 0));
  select * into v_session from public.sessions where id = p_session_id for update;
  if not found or v_session.ended_at is not null or (v_session.expires_at is not null and v_session.expires_at <= now()) then
    raise exception 'session not available' using errcode = 'P0002';
  end if;
  select role into v_role from public.session_members where session_id = p_session_id and profile_id = v_actor_id;
  if not found then raise exception 'not a session member' using errcode = '42501'; end if;
  if p_expected_revision <> v_session.queue_revision then
    return jsonb_build_object('status', 'conflict', 'revision', v_session.queue_revision);
  end if;

  if p_type = 'add' then
    v_track_id := nullif(p_payload ->> 'canonical_track_id', '')::uuid;
    if v_track_id is null or not exists (select 1 from public.canonical_tracks where id = v_track_id) then
      raise exception 'a valid canonical_track_id is required' using errcode = '22023';
    end if;
    select coalesce(max(position), 0) + 1024 into v_position from public.queue_items where session_id = p_session_id;
    insert into public.queue_items(session_id, canonical_track_id, added_by, position)
    values (p_session_id, v_track_id, v_actor_id, v_position);
  elsif p_type = 'move' then
    if v_role <> 'conductor' then raise exception 'only the conductor may move queue items' using errcode = '42501'; end if;
    v_target_item_id := nullif(p_payload ->> 'queue_item_id', '')::uuid;
    v_position := (p_payload ->> 'position')::double precision;
    if v_target_item_id is null or v_position is null then raise exception 'queue_item_id and position are required' using errcode = '22023'; end if;
    update public.queue_items set position = v_position where id = v_target_item_id and session_id = p_session_id;
    if not found then raise exception 'queue item not found' using errcode = 'P0002'; end if;
  elsif p_type = 'remove' then
    v_target_item_id := nullif(p_payload ->> 'queue_item_id', '')::uuid;
    select * into v_item from public.queue_items where id = v_target_item_id and session_id = p_session_id for update;
    if not found then raise exception 'queue item not found' using errcode = 'P0002'; end if;
    if v_role <> 'conductor' and v_item.added_by <> v_actor_id then raise exception 'may only remove your own queue item' using errcode = '42501'; end if;
    delete from public.queue_items where id = v_target_item_id;
  elsif p_type in ('play', 'pause', 'skip') then
    if v_session.playback_mode = 'queue_only' then raise exception 'queue-only sessions do not control playback' using errcode = '42501'; end if;
    if v_role <> 'conductor' then raise exception 'only the conductor controls playback' using errcode = '42501'; end if;
    update public.sessions set playback_state = p_payload where id = p_session_id;
  else
    raise exception 'unsupported command' using errcode = '22023';
  end if;

  v_new_revision := v_session.queue_revision + 1;
  update public.sessions set queue_revision = v_new_revision where id = p_session_id;
  insert into public.queue_events(session_id, revision, command_id, actor_id, type, payload)
  values (p_session_id, v_new_revision, p_command_id, v_actor_id, p_type, p_payload);
  return jsonb_build_object('status', 'applied', 'idempotent', false, 'revision', v_new_revision);
end;
$$;

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
  if p_expected_revision is null or p_expected_revision < 0 then raise exception 'a non-negative expected_revision is required' using errcode = '22023'; end if;
  select * into v_existing from public.queue_events where session_id = p_session_id and command_id = p_command_id;
  if found then
    if v_existing.actor_id <> v_actor_id then raise exception 'command id already belongs to another user' using errcode = '42501'; end if;
    return jsonb_build_object('status', 'applied', 'idempotent', true, 'revision', v_existing.revision, 'skipped_queue_item_id', v_existing.payload ->> 'skipped_queue_item_id');
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_session_id::text, 0));
  select * into v_session from public.sessions where id = p_session_id for update;
  if not found or v_session.ended_at is not null or (v_session.expires_at is not null and v_session.expires_at <= now()) then
    raise exception 'session not available' using errcode = 'P0002';
  end if;
  if v_session.playback_mode = 'queue_only' then raise exception 'queue-only sessions do not control playback' using errcode = '42501'; end if;
  select role into v_role from public.session_members where session_id = p_session_id and profile_id = v_actor_id;
  if not found or v_role <> 'conductor' then raise exception 'only the conductor controls playback' using errcode = '42501'; end if;
  if p_expected_revision <> v_session.queue_revision then return jsonb_build_object('status', 'conflict', 'revision', v_session.queue_revision); end if;
  select id into v_skipped_item_id from public.queue_items where session_id = p_session_id order by position limit 1 for update;
  if v_skipped_item_id is null then raise exception 'queue is empty' using errcode = 'P0002'; end if;
  delete from public.queue_items where id = v_skipped_item_id;
  v_new_revision := v_session.queue_revision + 1;
  update public.sessions set queue_revision = v_new_revision, playback_state = jsonb_build_object('status', 'playing') where id = p_session_id;
  insert into public.queue_events(session_id, revision, command_id, actor_id, type, payload)
  values (p_session_id, v_new_revision, p_command_id, v_actor_id, 'skip', jsonb_build_object('skipped_queue_item_id', v_skipped_item_id));
  return jsonb_build_object('status', 'applied', 'idempotent', false, 'revision', v_new_revision, 'skipped_queue_item_id', v_skipped_item_id);
end;
$$;
