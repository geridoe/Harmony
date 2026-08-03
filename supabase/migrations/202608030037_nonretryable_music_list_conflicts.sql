-- PostgREST/Supabase may retry SQLSTATE 40001 as a transaction failure. A
-- deliberate optimistic-concurrency rejection is not transient: expose it as
-- HTTP 409 while keeping the stable detail consumed by installed clients.
do $$
declare
  v_signature regprocedure;
  v_definition text;
  v_updated_definition text;
begin
  foreach v_signature in array array[
    'public.save_music_list(text,text,text[],boolean,public.social_visibility,jsonb,uuid,bigint)'::regprocedure,
    'public.add_music_list_entry(uuid,uuid,text,bigint)'::regprocedure,
    'public.update_music_list_entry_note(uuid,text,bigint)'::regprocedure,
    'public.remove_music_list_entry(uuid,bigint)'::regprocedure,
    'public.reorder_music_list_entries(uuid,uuid[],bigint)'::regprocedure
  ]
  loop
    v_definition := pg_get_functiondef(v_signature);
    v_updated_definition := replace(v_definition, '''40001''', '''PT409''');
    if v_updated_definition = v_definition then
      raise exception 'expected revision conflict SQLSTATE was not found in %', v_signature;
    end if;
    execute v_updated_definition;
  end loop;
end;
$$;
