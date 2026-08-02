#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
plist="$repo_root/Harmony/Info.plist"
supabase_url="$(/usr/libexec/PlistBuddy -c 'Print :SupabaseURL' "$plist")"
publishable_key="$(/usr/libexec/PlistBuddy -c 'Print :SupabasePublishableKey' "$plist")"
smoke_tmp="$(mktemp -d)"
conductor_token=""
collaborator_token=""
stage="initialization"

report_failure() {
  printf 'Harmony live smoke failed during: %s\n' "$stage" >&2
}

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
trap report_failure ERR

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

rpc_status() {
  local token="$1"
  local function_name="$2"
  local body="$3"
  local output_file="$4"
  curl --silent --show-error \
    -X POST "$supabase_url/rest/v1/rpc/$function_name" \
    -H "apikey: $publishable_key" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    --data "$body" \
    -o "$output_file" \
    -w '%{http_code}'
}

rest_get() {
  local token="$1"
  local path="$2"
  local output_file="$3"
  curl --silent --show-error --fail-with-body \
    "$supabase_url/rest/v1/$path" \
    -H "apikey: $publishable_key" \
    -H "Authorization: Bearer $token" \
    -o "$output_file"
}

new_uuid() {
  uuidgen | tr '[:upper:]' '[:lower:]'
}

stage="anonymous authentication"
conductor_token="$(anonymous_token "$smoke_tmp/conductor-auth.json")"
collaborator_token="$(anonymous_token "$smoke_tmp/collaborator-auth.json")"
conductor_id="$(jq -er '.user.id' "$smoke_tmp/conductor-auth.json")"
collaborator_id="$(jq -er '.user.id' "$smoke_tmp/collaborator-auth.json")"
invite_code="SMK$(printf '%05d' "$((RANDOM % 100000))")"

stage="session creation and join"
rpc "$conductor_token" create_session \
  "{\"p_title\":\"Harmony live smoke\",\"p_invite_code\":\"$invite_code\",\"p_playback_mode\":\"queue_only\",\"p_allow_collaborator_invites\":true,\"p_expires_at\":null}" \
  "$smoke_tmp/session.json"
session_id="$(jq -er 'if type == "array" then .[0].id else .id end' "$smoke_tmp/session.json")"
jq -e 'if type == "array" then .[0].playback_mode == "queue_only" else .playback_mode == "queue_only" end' "$smoke_tmp/session.json" >/dev/null

rpc "$collaborator_token" join_session_by_invite \
  "{\"p_invite_code\":\"$invite_code\"}" \
  "$smoke_tmp/join.json"
joined_id="$(jq -er 'if type == "array" then .[0].id else .id end' "$smoke_tmp/join.json")"
[[ "$joined_id" == "$session_id" ]]

rest_get "$collaborator_token" \
  "session_members?select=profile_id,role&session_id=eq.$session_id" \
  "$smoke_tmp/members.json"
[[ "$(jq 'length' "$smoke_tmp/members.json")" -eq 2 ]]
jq -e --arg actor "$conductor_id" '.[] | select(.profile_id == $actor and .role == "conductor")' "$smoke_tmp/members.json" >/dev/null
jq -e --arg actor "$collaborator_id" '.[] | select(.profile_id == $actor and .role == "collaborator")' "$smoke_tmp/members.json" >/dev/null

stage="invite permission enforcement"
collaborator_invite_permission_status="$(rpc_status "$collaborator_token" set_harmony_collaborator_invites \
  "{\"p_session_id\":\"$session_id\",\"p_allow_collaborator_invites\":false}" \
  "$smoke_tmp/collaborator-invite-permission.json")"
[[ "$collaborator_invite_permission_status" == "400" || "$collaborator_invite_permission_status" == "403" ]]
rpc "$conductor_token" set_harmony_collaborator_invites \
  "{\"p_session_id\":\"$session_id\",\"p_allow_collaborator_invites\":false}" \
  "$smoke_tmp/conductor-invite-permission.json"
jq -e 'if type == "array" then .[0].allow_collaborator_invites == false else .allow_collaborator_invites == false end' "$smoke_tmp/conductor-invite-permission.json" >/dev/null

stage="catalog lookup"
rest_get "$conductor_token" \
  'canonical_tracks?select=id&order=created_at.asc&limit=2' \
  "$smoke_tmp/tracks.json"
[[ "$(jq 'length' "$smoke_tmp/tracks.json")" -eq 2 ]]
track_one="$(jq -er '.[0].id' "$smoke_tmp/tracks.json")"
track_two="$(jq -er '.[1].id' "$smoke_tmp/tracks.json")"

stage="Conductor add and idempotent replay"
conductor_add_command="$(new_uuid)"
rpc "$conductor_token" apply_queue_command \
  "{\"p_session_id\":\"$session_id\",\"p_command_id\":\"$conductor_add_command\",\"p_expected_revision\":0,\"p_type\":\"add\",\"p_payload\":{\"canonical_track_id\":\"$track_one\"}}" \
  "$smoke_tmp/conductor-add.json"
jq -e '.status == "applied" and .idempotent == false and .revision == 1' "$smoke_tmp/conductor-add.json" >/dev/null

rpc "$conductor_token" apply_queue_command \
  "{\"p_session_id\":\"$session_id\",\"p_command_id\":\"$conductor_add_command\",\"p_expected_revision\":0,\"p_type\":\"add\",\"p_payload\":{\"canonical_track_id\":\"$track_one\"}}" \
  "$smoke_tmp/conductor-add-replay.json"
jq -e '.status == "applied" and .idempotent == true and .revision == 1' "$smoke_tmp/conductor-add-replay.json" >/dev/null

stage="collaborator add"
collaborator_add_command="$(new_uuid)"
rpc "$collaborator_token" apply_queue_command \
  "{\"p_session_id\":\"$session_id\",\"p_command_id\":\"$collaborator_add_command\",\"p_expected_revision\":1,\"p_type\":\"add\",\"p_payload\":{\"canonical_track_id\":\"$track_two\"}}" \
  "$smoke_tmp/collaborator-add.json"
jq -e '.status == "applied" and .revision == 2' "$smoke_tmp/collaborator-add.json" >/dev/null

stage="queue ownership lookup"
rest_get "$conductor_token" \
  "queue_items?select=id,added_by,position&session_id=eq.$session_id&order=position.asc" \
  "$smoke_tmp/queue.json"
[[ "$(jq 'length' "$smoke_tmp/queue.json")" -eq 2 ]]
conductor_item_id="$(jq -er --arg actor "$conductor_id" '.[] | select(.added_by == $actor) | .id' "$smoke_tmp/queue.json")"
collaborator_item_id="$(jq -er --arg actor "$collaborator_id" '.[] | select(.added_by == $actor) | .id' "$smoke_tmp/queue.json")"

stage="collaborator permission rejection"
collaborator_move_status="$(rpc_status "$collaborator_token" apply_queue_command \
  "{\"p_session_id\":\"$session_id\",\"p_command_id\":\"$(new_uuid)\",\"p_expected_revision\":2,\"p_type\":\"move\",\"p_payload\":{\"queue_item_id\":\"$collaborator_item_id\",\"position\":512}}" \
  "$smoke_tmp/collaborator-move.json")"
[[ "$collaborator_move_status" == "400" || "$collaborator_move_status" == "403" ]]

collaborator_remove_other_status="$(rpc_status "$collaborator_token" apply_queue_command \
  "{\"p_session_id\":\"$session_id\",\"p_command_id\":\"$(new_uuid)\",\"p_expected_revision\":2,\"p_type\":\"remove\",\"p_payload\":{\"queue_item_id\":\"$conductor_item_id\"}}" \
  "$smoke_tmp/collaborator-remove-other.json")"
[[ "$collaborator_remove_other_status" == "400" || "$collaborator_remove_other_status" == "403" ]]

stage="revision conflict"
rpc "$conductor_token" apply_queue_command \
  "{\"p_session_id\":\"$session_id\",\"p_command_id\":\"$(new_uuid)\",\"p_expected_revision\":1,\"p_type\":\"move\",\"p_payload\":{\"queue_item_id\":\"$collaborator_item_id\",\"position\":512}}" \
  "$smoke_tmp/stale-move.json"
jq -e '.status == "conflict" and .revision == 2' "$smoke_tmp/stale-move.json" >/dev/null

stage="Conductor reorder"
rpc "$conductor_token" apply_queue_command \
  "{\"p_session_id\":\"$session_id\",\"p_command_id\":\"$(new_uuid)\",\"p_expected_revision\":2,\"p_type\":\"move\",\"p_payload\":{\"queue_item_id\":\"$collaborator_item_id\",\"position\":512}}" \
  "$smoke_tmp/conductor-move.json"
jq -e '.status == "applied" and .revision == 3' "$smoke_tmp/conductor-move.json" >/dev/null

stage="collaborator removes own item"
rpc "$collaborator_token" apply_queue_command \
  "{\"p_session_id\":\"$session_id\",\"p_command_id\":\"$(new_uuid)\",\"p_expected_revision\":3,\"p_type\":\"remove\",\"p_payload\":{\"queue_item_id\":\"$collaborator_item_id\"}}" \
  "$smoke_tmp/collaborator-remove-own.json"
jq -e '.status == "applied" and .revision == 4' "$smoke_tmp/collaborator-remove-own.json" >/dev/null

stage="collaborator playback rejection"
collaborator_play_status="$(rpc_status "$collaborator_token" apply_queue_command \
  "{\"p_session_id\":\"$session_id\",\"p_command_id\":\"$(new_uuid)\",\"p_expected_revision\":4,\"p_type\":\"play\",\"p_payload\":{\"status\":\"playing\"}}" \
  "$smoke_tmp/collaborator-play.json")"
[[ "$collaborator_play_status" == "400" || "$collaborator_play_status" == "403" ]]

stage="queue-only playback rejection"
conductor_play_status="$(rpc_status "$conductor_token" apply_queue_command \
  "{\"p_session_id\":\"$session_id\",\"p_command_id\":\"$(new_uuid)\",\"p_expected_revision\":4,\"p_type\":\"play\",\"p_payload\":{\"status\":\"playing\"}}" \
  "$smoke_tmp/conductor-play.json")"
[[ "$conductor_play_status" == "400" || "$conductor_play_status" == "403" ]]

stage="collaborator end rejection"
collaborator_end_status="$(curl --silent --show-error \
  -X POST "$supabase_url/rest/v1/rpc/end_harmony_session" \
  -H "apikey: $publishable_key" \
  -H "Authorization: Bearer $collaborator_token" \
  -H "Content-Type: application/json" \
  --data "{\"p_session_id\":\"$session_id\"}" \
  -o "$smoke_tmp/collaborator-end.json" \
  -w '%{http_code}')"
[[ "$collaborator_end_status" == "400" || "$collaborator_end_status" == "403" ]]

stage="Conductor end and cleanup"
rpc "$conductor_token" end_harmony_session \
  "{\"p_session_id\":\"$session_id\"}" \
  "$smoke_tmp/end.json"

cleanup_account "$collaborator_token"
collaborator_token=""
cleanup_account "$conductor_token"
conductor_token=""

printf 'Harmony live smoke passed: auth, invite permissions, collaboration roles, queue ownership, conflicts, idempotency, end, cleanup\n'
