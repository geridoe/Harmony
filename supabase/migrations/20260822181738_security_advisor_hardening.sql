-- Remove inherited unauthenticated access from privileged public functions.
-- Supabase anonymous *accounts* still use the authenticated database role, so
-- this preserves the current guest product while closing the unauthenticated
-- Data API surface reported by the security advisor.
do $$
declare
  function_record record;
begin
  for function_record in
    select p.oid::regprocedure as signature
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prosecdef
  loop
    execute format('revoke execute on function %s from public, anon', function_record.signature);
    execute format('grant execute on function %s to authenticated', function_record.signature);
  end loop;
end;
$$;

-- Trigger entry points and maintenance helpers are never client RPCs.
do $$
declare
  function_record record;
begin
  for function_record in
    select p.oid::regprocedure as signature
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prorettype = 'trigger'::regtype
  loop
    execute format('revoke execute on function %s from authenticated, anon, public', function_record.signature);
  end loop;
end;
$$;

revoke execute on function public.consume_account_rate_limit(text, integer, interval)
  from authenticated, anon, public;
revoke execute on function public.cleanup_expired_listening_shares()
  from authenticated, anon, public;
revoke execute on function public.perform_production_cleanup(integer)
  from authenticated, anon, public;

-- Read the view with the caller's privileges and underlying RLS policies.
alter view public.provider_connection_statuses set (security_invoker = true);

-- Immutable normalizers do not access relations, but pinning an empty search
-- path prevents later name-resolution changes and clears advisor warnings.
alter function public.normalize_track_identity_text(text) set search_path = '';
alter function public.normalize_album_upc(text) set search_path = '';
alter function public.infer_provider_album_storefront(public.music_provider, text)
  set search_path = '';
