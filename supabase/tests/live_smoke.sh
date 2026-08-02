#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
plist="$repo_root/Harmony/Info.plist"
supabase_url="$(/usr/libexec/PlistBuddy -c 'Print :SupabaseURL' "$plist")"
publishable_key="$(/usr/libexec/PlistBuddy -c 'Print :SupabasePublishableKey' "$plist")"
smoke_tmp="$(mktemp -d)"
conductor_token=""
collaborator_token=""

cleanup_account() {
  local token="$1"
  if [[ -n "$token" ]]; then
    curl --silent --show-error --fail-with-body \
      -X POST "$supabase_url/functions/v1/delete-account" \
      -H "apikey: $publishable_key" \
      -H "Authorization: Bearer $token" \
      -o /dev/null
  fi
}

cleanup() {
  cleanup_account "$collaborator_token" || true
  cleanup_account "$conductor_token" || true
  rm -rf "$smoke_tmp"
}
trap cleanup EXIT

anonymous_token() {
  local response_file="$1"
  curl --silent --show-error --fail-with-body \
    -X POST "$supabase_url/auth/v1/signup" \
    -H "apikey: $publishable_key" \
    -H "Content-Type: application/json" \
    --data '{"data":{"test_source":"harmony_live_smoke"}}' \
    -o "$response_file"
  jq -er '.access_token' "$response_file"
}

rpc() {
  local token="$1"
  local function_name="$2"
  local body="$3"
  local output_file="$4"
  curl --silent --show-error --fail-with-body \
    -X POST "$supabase_url/rest/v1/rpc/$function_name" \
    -H "apikey: $publishable_key" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    --data "$body" \
    -o "$output_file"
}

conductor_token="$(anonymous_token "$smoke_tmp/conductor-auth.json")"
collaborator_token="$(anonymous_token "$smoke_tmp/collaborator-auth.json")"
invite_code="SMK$(printf '%05d' "$((RANDOM % 100000))")"

rpc "$conductor_token" create_session \
  "{\"p_title\":\"Harmony live smoke\",\"p_invite_code\":\"$invite_code\",\"p_playback_mode\":\"queue_only\",\"p_allow_collaborator_invites\":true,\"p_expires_at\":null}" \
  "$smoke_tmp/session.json"
session_id="$(jq -er 'if type == "array" then .[0].id else .id end' "$smoke_tmp/session.json")"

rpc "$collaborator_token" join_session_by_invite \
  "{\"p_invite_code\":\"$invite_code\"}" \
  "$smoke_tmp/join.json"
joined_id="$(jq -er 'if type == "array" then .[0].id else .id end' "$smoke_tmp/join.json")"
[[ "$joined_id" == "$session_id" ]]

collaborator_end_status="$(curl --silent --show-error \
  -X POST "$supabase_url/rest/v1/rpc/end_harmony_session" \
  -H "apikey: $publishable_key" \
  -H "Authorization: Bearer $collaborator_token" \
  -H "Content-Type: application/json" \
  --data "{\"p_session_id\":\"$session_id\"}" \
  -o "$smoke_tmp/collaborator-end.json" \
  -w '%{http_code}')"
[[ "$collaborator_end_status" == "400" || "$collaborator_end_status" == "403" ]]

rpc "$conductor_token" end_harmony_session \
  "{\"p_session_id\":\"$session_id\"}" \
  "$smoke_tmp/end.json"

cleanup_account "$collaborator_token"
collaborator_token=""
cleanup_account "$conductor_token"
conductor_token=""

printf 'Harmony live smoke passed: anonymous auth, create, join, role enforcement, end, cleanup\n'
