-- Remove all profile-owned Harmony data before deleting the corresponding
-- Supabase Auth user. Only the service role may invoke this cleanup boundary.
create or replace function public.delete_harmony_account_data(p_profile_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Sessions conducted by this profile cannot outlive their Conductor.
  delete from public.sessions where conductor_id = p_profile_id;

  -- Contributions to sessions conducted by other users must be removed before
  -- the profile row can cascade from auth.users.
  delete from public.queue_items where added_by = p_profile_id;
  delete from public.queue_events where actor_id = p_profile_id;
  delete from public.session_members where profile_id = p_profile_id;
  delete from public.provider_connections where profile_id = p_profile_id;
end;
$$;

revoke all on function public.delete_harmony_account_data(uuid) from public, anon, authenticated;
grant execute on function public.delete_harmony_account_data(uuid) to service_role;
