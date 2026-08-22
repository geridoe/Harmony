-- Cache Spotify access tokens server-side so normal catalog and playback
-- requests do not spend an OAuth refresh request each time. These columns stay
-- on the private base table and are intentionally omitted from the
-- provider_connection_statuses client view.
alter table public.provider_connections
  add column if not exists encrypted_access_token text,
  add column if not exists access_token_expires_at timestamptz,
  add column if not exists token_refresh_started_at timestamptz;

-- A short lease collapses simultaneous cache misses into one refresh in normal
-- operation. A crashed Edge Function cannot strand the connection: another
-- invocation may take the lease after 15 seconds.
create or replace function public.claim_spotify_token_refresh(
  p_profile_id uuid,
  p_safe_until timestamptz
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_updated_count bigint := 0;
begin
  update public.provider_connections
  set token_refresh_started_at = clock_timestamp()
  where profile_id = p_profile_id
    and provider = 'spotify'
    and encrypted_refresh_token is not null
    and (
      encrypted_access_token is null
      or access_token_expires_at is null
      or access_token_expires_at <= p_safe_until
    )
    and (
      token_refresh_started_at is null
      or token_refresh_started_at < clock_timestamp() - interval '15 seconds'
    );

  get diagnostics v_updated_count = row_count;
  return v_updated_count > 0;
end;
$$;

revoke all on function public.claim_spotify_token_refresh(uuid, timestamptz)
  from public, anon, authenticated;
grant execute on function public.claim_spotify_token_refresh(uuid, timestamptz)
  to service_role;

comment on column public.provider_connections.encrypted_access_token is
  'AES-GCM encrypted short-lived provider access token; service role only.';
comment on function public.claim_spotify_token_refresh(uuid, timestamptz) is
  'Claims a stale Spotify access-token refresh lease for a trusted service.';
