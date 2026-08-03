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

function_status() {
  local token="$1"
  local function_name="$2"
  local body="$3"
  local output_file="$4"
  curl --silent --show-error \
    -X POST "$supabase_url/functions/v1/$function_name" \
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

rest_patch() {
  local token="$1"
  local path="$2"
  local body="$3"
  local output_file="$4"
  curl --silent --show-error --fail-with-body \
    -X PATCH "$supabase_url/rest/v1/$path" \
    -H "apikey: $publishable_key" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -H "Prefer: return=representation" \
    --data "$body" \
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

stage="social Realtime delivery"
realtime_node="${HARMONY_NODE_BINARY:-$(command -v node || true)}"
if [[ -n "$realtime_node" ]]; then
  HARMONY_SUPABASE_URL="$supabase_url" \
  HARMONY_PUBLISHABLE_KEY="$publishable_key" \
  HARMONY_OBSERVER_TOKEN="$conductor_token" \
  HARMONY_ACTOR_TOKEN="$collaborator_token" \
  HARMONY_OBSERVER_ID="$conductor_id" \
  HARMONY_ACTOR_ID="$collaborator_id" \
    "$realtime_node" "$repo_root/supabase/tests/realtime_smoke.mjs"
else
  printf 'Harmony Realtime smoke skipped: set HARMONY_NODE_BINARY to Node.js 22 or newer\n'
fi

stage="Spotify history import authentication boundary"
spotify_history_status="$(function_status "$conductor_token" spotify-history-import '{}' "$smoke_tmp/spotify-history.json")"
[[ "$spotify_history_status" == "404" ]]
jq -e '.error == "spotify_not_connected"' "$smoke_tmp/spotify-history.json" >/dev/null
spotify_presence_status="$(function_status "$conductor_token" spotify-now-listening '{}' "$smoke_tmp/spotify-presence.json")"
[[ "$spotify_presence_status" == "404" ]]
jq -e '.error == "spotify_not_connected"' "$smoke_tmp/spotify-presence.json" >/dev/null

stage="private profile defaults and account settings"
rest_get "$conductor_token" \
  "profile_social_settings?select=profile_id,live_visibility,history_visibility,reviews_visibility,record_harmony_plays&profile_id=eq.$conductor_id" \
  "$smoke_tmp/private-settings.json"
jq -e 'length == 1 and .[0].live_visibility == "private" and .[0].history_visibility == "private" and .[0].reviews_visibility == "private" and .[0].record_harmony_plays == false' "$smoke_tmp/private-settings.json" >/dev/null
rest_patch "$conductor_token" \
  "profiles?id=eq.$conductor_id" \
  '{"display_name":"Harmony Smoke Conductor"}' \
  "$smoke_tmp/profile-update.json"
jq -e 'length == 1 and .[0].display_name == "Harmony Smoke Conductor"' "$smoke_tmp/profile-update.json" >/dev/null
rest_patch "$conductor_token" \
  "profile_social_settings?profile_id=eq.$conductor_id" \
  '{"live_visibility":"followers","history_visibility":"private","reviews_visibility":"followers","record_harmony_plays":true}' \
  "$smoke_tmp/settings-update.json"
jq -e 'length == 1 and .[0].live_visibility == "followers" and .[0].history_visibility == "private" and .[0].reviews_visibility == "followers" and .[0].record_harmony_plays == true' "$smoke_tmp/settings-update.json" >/dev/null

stage="social follow enforcement"
rpc "$conductor_token" request_social_follow \
  "{\"p_profile_id\":\"$collaborator_id\"}" \
  "$smoke_tmp/follow-request.json"
rest_get "$collaborator_token" \
  "social_notifications?select=id,kind,actor_id,read_at&kind=eq.follow_request&actor_id=eq.$conductor_id&order=created_at.desc&limit=1" \
  "$smoke_tmp/follow-notification.json"
follow_notification_id="$(jq -er '.[0].id' "$smoke_tmp/follow-notification.json")"
jq -e --arg actor "$conductor_id" 'length == 1 and .[0].kind == "follow_request" and .[0].actor_id == $actor and .[0].read_at == null' "$smoke_tmp/follow-notification.json" >/dev/null
rest_get "$collaborator_token" \
  "social_notifications?select=id,kind,created_at,read_at,actor:profiles!social_notifications_actor_id_fkey(display_name),review:music_reviews!social_notifications_review_id_fkey(subject_title,canonical_tracks(title,artist,album,duration_ms,artwork_url,is_explicit))&id=eq.$follow_notification_id" \
  "$smoke_tmp/follow-notification-client-shape.json"
jq -e 'length == 1 and .[0].actor.display_name == "Harmony Smoke Conductor" and .[0].review == null' "$smoke_tmp/follow-notification-client-shape.json" >/dev/null
rpc "$collaborator_token" respond_to_social_follow \
  "{\"p_requester_id\":\"$conductor_id\",\"p_accept\":true}" \
  "$smoke_tmp/follow-accept.json"
rest_get "$conductor_token" \
  "social_notifications?select=id,kind,actor_id&kind=eq.follow_accepted&actor_id=eq.$collaborator_id&order=created_at.desc&limit=1" \
  "$smoke_tmp/accepted-notification.json"
jq -e --arg actor "$collaborator_id" 'length == 1 and .[0].kind == "follow_accepted" and .[0].actor_id == $actor' "$smoke_tmp/accepted-notification.json" >/dev/null
rpc "$collaborator_token" mark_social_notifications_read \
  "{\"p_notification_id\":\"$follow_notification_id\"}" \
  "$smoke_tmp/notification-read.json"
[[ "$(jq -er '.' "$smoke_tmp/notification-read.json")" == "1" ]]
rest_get "$conductor_token" \
  "social_follows?select=follower_id,followed_id,state&follower_id=eq.$conductor_id&followed_id=eq.$collaborator_id" \
  "$smoke_tmp/follows.json"
jq -e 'length == 1 and .[0].state == "accepted"' "$smoke_tmp/follows.json" >/dev/null

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

stage="recent-session visibility"
rest_get "$collaborator_token" \
  'sessions?select=id,title,ended_at,expires_at,playback_mode&order=created_at.desc&limit=20' \
  "$smoke_tmp/recent-sessions.json"
jq -e --arg session "$session_id" '.[] | select(.id == $session)' "$smoke_tmp/recent-sessions.json" >/dev/null

stage="provider track canonicalization"
rpc "$conductor_token" resolve_harmony_track \
  '{"p_provider":"apple_music","p_provider_id":"harmony-smoke-apple-track","p_title":"Harmony Smoke Track","p_artist":"Harmony Test Artist","p_album":"Harmony Test Album","p_duration_ms":180000,"p_artwork_url":null,"p_is_explicit":false,"p_deep_link":null}' \
  "$smoke_tmp/canonical-track.json"
canonical_track_id="$(jq -er '.' "$smoke_tmp/canonical-track.json")"
rpc "$conductor_token" resolve_harmony_track \
  '{"p_provider":"apple_music","p_provider_id":"harmony-smoke-apple-track","p_title":"Changed display title","p_artist":"Changed display artist","p_album":null,"p_duration_ms":181000,"p_artwork_url":null,"p_is_explicit":false,"p_deep_link":null}' \
  "$smoke_tmp/canonical-track-repeat.json"
[[ "$(jq -er '.' "$smoke_tmp/canonical-track-repeat.json")" == "$canonical_track_id" ]]

stage="follower listening visibility"
presence_expires_at="$(date -u -v+5M '+%Y-%m-%dT%H:%M:%SZ')"
rpc "$collaborator_token" publish_listening_presence \
  "{\"p_canonical_track_id\":\"$canonical_track_id\",\"p_provider\":\"apple_music\",\"p_provider_track_id\":\"harmony-smoke-apple-track\",\"p_provider_deep_link\":null,\"p_status\":\"listening\",\"p_visibility\":\"followers\",\"p_started_at\":\"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\",\"p_expires_at\":\"$presence_expires_at\"}" \
  "$smoke_tmp/presence.json"
rest_get "$conductor_token" \
  "listening_presence?select=profile_id,canonical_track_id,status&profile_id=eq.$collaborator_id" \
  "$smoke_tmp/follower-presence.json"
jq -e --arg profile "$collaborator_id" --arg track "$canonical_track_id" 'length == 1 and .[0].profile_id == $profile and .[0].canonical_track_id == $track and .[0].status == "listening"' "$smoke_tmp/follower-presence.json" >/dev/null
rpc "$collaborator_token" record_listening_history \
  "{\"p_canonical_track_id\":\"$canonical_track_id\",\"p_provider\":\"apple_music\",\"p_provider_track_id\":\"harmony-smoke-apple-track\",\"p_played_at\":\"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\",\"p_source\":\"manual\",\"p_visibility\":\"followers\"}" \
  "$smoke_tmp/history.json"
history_entry_id="$(jq -er 'if type == "array" then .[0].id else .id end' "$smoke_tmp/history.json")"
rest_get "$conductor_token" \
  "listening_history_entries?select=profile_id,canonical_track_id&profile_id=eq.$collaborator_id" \
  "$smoke_tmp/follower-history.json"
jq -e --arg profile "$collaborator_id" --arg track "$canonical_track_id" 'length == 1 and .[0].profile_id == $profile and .[0].canonical_track_id == $track' "$smoke_tmp/follower-history.json" >/dev/null
rest_get "$conductor_token" \
  "listening_history_entries?select=id,profile_id,played_at,source,visibility,canonical_tracks(title,artist,album,duration_ms,artwork_url,is_explicit),profiles(display_name)&id=eq.$history_entry_id" \
  "$smoke_tmp/history-detail.json"
jq -e 'length == 1 and .[0].canonical_tracks.title == "Harmony Smoke Track" and (.[] | .profiles.display_name | length) > 0' "$smoke_tmp/history-detail.json" >/dev/null

stage="follower music reviews"
rpc "$collaborator_token" create_music_review \
  "{\"p_subject_kind\":\"track\",\"p_canonical_track_id\":\"$canonical_track_id\",\"p_provider\":\"apple_music\",\"p_provider_subject_id\":null,\"p_rating\":4.5,\"p_body\":\"A great Harmony smoke review.\",\"p_visibility\":\"followers\",\"p_contains_spoilers\":false}" \
  "$smoke_tmp/review.json"
review_id="$(jq -er 'if type == "array" then .[0].id else .id end' "$smoke_tmp/review.json")"
rest_get "$conductor_token" \
  "music_reviews?select=id,profile_id,subject_kind,subject_title,subject_artist,rating,body&id=eq.$review_id" \
  "$smoke_tmp/follower-review.json"
jq -e --arg profile "$collaborator_id" 'length == 1 and .[0].profile_id == $profile and .[0].subject_kind == "track" and .[0].subject_title == "Harmony Smoke Track" and .[0].rating == 4.5' "$smoke_tmp/follower-review.json" >/dev/null
invalid_album_link_status="$(rpc_status "$collaborator_token" create_music_review \
  '{"p_subject_kind":"album","p_provider":"spotify","p_provider_subject_id":"spotify:album:invalid","p_subject_title":"Invalid Link Album","p_subject_deep_link":"https://example.com/not-spotify","p_rating":3.0}' \
  "$smoke_tmp/invalid-album-link.json")"
[[ "$invalid_album_link_status" == "400" ]]
rpc "$collaborator_token" create_music_review \
  '{"p_subject_kind":"album","p_provider":"spotify","p_provider_subject_id":"spotify:album:harmony-smoke","p_subject_title":"Harmony Smoke Album","p_subject_artist":"Harmony Test Artist","p_subject_artwork_url":"https://example.com/harmony-smoke.jpg","p_subject_deep_link":"https://open.spotify.com/album/harmony-smoke","p_rating":4.0,"p_body":"An album diary entry.","p_visibility":"followers","p_contains_spoilers":false}' \
  "$smoke_tmp/album-review.json"
album_review_id="$(jq -er 'if type == "array" then .[0].id else .id end' "$smoke_tmp/album-review.json")"
rest_get "$conductor_token" \
  "music_reviews?select=id,subject_kind,subject_title,subject_artist,subject_deep_link&id=eq.$album_review_id" \
  "$smoke_tmp/follower-album-review.json"
jq -e 'length == 1 and .[0].subject_kind == "album" and .[0].subject_title == "Harmony Smoke Album" and .[0].subject_artist == "Harmony Test Artist"' "$smoke_tmp/follower-album-review.json" >/dev/null
rpc "$conductor_token" add_review_comment \
  "{\"p_review_id\":\"$review_id\",\"p_body\":\"Agreed.\"}" \
  "$smoke_tmp/review-comment.json"
comment_id="$(jq -er 'if type == "array" then .[0].id else .id end' "$smoke_tmp/review-comment.json")"
rpc "$conductor_token" toggle_review_reaction \
  "{\"p_review_id\":\"$review_id\",\"p_kind\":\"heart\"}" \
  "$smoke_tmp/review-reaction.json"
[[ "$(jq -er '.' "$smoke_tmp/review-reaction.json")" == "true" ]]
rest_get "$collaborator_token" \
  "social_notifications?select=kind,actor_id,review_id&actor_id=eq.$conductor_id&review_id=eq.$review_id&order=created_at.asc" \
  "$smoke_tmp/review-notifications.json"
jq -e 'length == 2 and ([.[].kind] | sort) == ["review_comment","review_reaction"]' "$smoke_tmp/review-notifications.json" >/dev/null
rest_get "$conductor_token" \
  "music_reviews?select=id,review_comments(id,author_id,body,created_at,profiles(display_name)),review_reactions(profile_id,kind)&id=eq.$review_id" \
  "$smoke_tmp/review-social-detail.json"
jq -e 'length == 1 and (.[] | .review_comments | length) == 1 and (.[] | .review_reactions | length) == 1' "$smoke_tmp/review-social-detail.json" >/dev/null
unauthorized_review_update_status="$(rpc_status "$conductor_token" update_music_review \
  "{\"p_review_id\":\"$review_id\",\"p_rating\":1.0,\"p_body\":\"Not mine\",\"p_visibility\":\"private\",\"p_contains_spoilers\":false}" \
  "$smoke_tmp/unauthorized-review-update.json")"
[[ "$unauthorized_review_update_status" == "400" || "$unauthorized_review_update_status" == "404" ]]
rpc "$collaborator_token" update_music_review \
  "{\"p_review_id\":\"$review_id\",\"p_rating\":5.0,\"p_body\":\"Updated Harmony smoke review.\",\"p_visibility\":\"followers\",\"p_contains_spoilers\":false}" \
  "$smoke_tmp/review-update.json"
rest_get "$conductor_token" \
  "music_reviews?select=id,rating,body&id=eq.$review_id" \
  "$smoke_tmp/updated-review.json"
jq -e 'length == 1 and .[0].rating == 5.0 and .[0].body == "Updated Harmony smoke review."' "$smoke_tmp/updated-review.json" >/dev/null
rpc "$conductor_token" delete_review_comment \
  "{\"p_comment_id\":\"$comment_id\"}" \
  "$smoke_tmp/comment-delete.json"
[[ "$(jq -er '.' "$smoke_tmp/comment-delete.json")" == "true" ]]
rest_get "$conductor_token" \
  "review_comments?select=id&id=eq.$comment_id" \
  "$smoke_tmp/deleted-comment.json"
[[ "$(jq 'length' "$smoke_tmp/deleted-comment.json")" -eq 0 ]]

stage="social block enforcement"
rpc "$collaborator_token" block_social_profile \
  "{\"p_profile_id\":\"$conductor_id\"}" \
  "$smoke_tmp/block.json"
rest_get "$conductor_token" \
  "listening_presence?select=profile_id&profile_id=eq.$collaborator_id" \
  "$smoke_tmp/blocked-presence.json"
[[ "$(jq 'length' "$smoke_tmp/blocked-presence.json")" -eq 0 ]]
rest_get "$conductor_token" \
  "listening_history_entries?select=id&id=eq.$history_entry_id" \
  "$smoke_tmp/blocked-history.json"
[[ "$(jq 'length' "$smoke_tmp/blocked-history.json")" -eq 0 ]]
rest_get "$conductor_token" \
  "music_reviews?select=id&id=eq.$review_id" \
  "$smoke_tmp/blocked-review.json"
[[ "$(jq 'length' "$smoke_tmp/blocked-review.json")" -eq 0 ]]
rest_get "$conductor_token" \
  "music_reviews?select=id&id=eq.$album_review_id" \
  "$smoke_tmp/blocked-album-review.json"
[[ "$(jq 'length' "$smoke_tmp/blocked-album-review.json")" -eq 0 ]]
rest_get "$collaborator_token" \
  "social_notifications?select=id&actor_id=eq.$conductor_id" \
  "$smoke_tmp/blocked-notifications.json"
[[ "$(jq 'length' "$smoke_tmp/blocked-notifications.json")" -eq 0 ]]
blocked_follow_status="$(rpc_status "$conductor_token" request_social_follow \
  "{\"p_profile_id\":\"$collaborator_id\"}" \
  "$smoke_tmp/blocked-follow.json")"
[[ "$blocked_follow_status" == "400" || "$blocked_follow_status" == "403" ]]
rpc "$collaborator_token" unblock_social_profile \
  "{\"p_profile_id\":\"$conductor_id\"}" \
  "$smoke_tmp/unblock.json"
[[ "$(jq -er '.' "$smoke_tmp/unblock.json")" == "true" ]]
rpc "$conductor_token" request_social_follow \
  "{\"p_profile_id\":\"$collaborator_id\"}" \
  "$smoke_tmp/refollow.json"
rpc "$conductor_token" remove_social_follow \
  "{\"p_profile_id\":\"$collaborator_id\"}" \
  "$smoke_tmp/unfollow.json"
[[ "$(jq -er '.' "$smoke_tmp/unfollow.json")" == "true" ]]
rpc "$collaborator_token" delete_listening_history_entry \
  "{\"p_entry_id\":\"$history_entry_id\"}" \
  "$smoke_tmp/history-delete.json"
[[ "$(jq -er '.' "$smoke_tmp/history-delete.json")" == "true" ]]
rest_get "$collaborator_token" \
  "listening_history_entries?select=id&id=eq.$history_entry_id" \
  "$smoke_tmp/deleted-history.json"
[[ "$(jq 'length' "$smoke_tmp/deleted-history.json")" -eq 0 ]]
rpc "$collaborator_token" delete_music_review \
  "{\"p_review_id\":\"$review_id\"}" \
  "$smoke_tmp/review-delete.json"
[[ "$(jq -er '.' "$smoke_tmp/review-delete.json")" == "true" ]]
rest_get "$collaborator_token" \
  "music_reviews?select=id&id=eq.$review_id" \
  "$smoke_tmp/deleted-review.json"
[[ "$(jq 'length' "$smoke_tmp/deleted-review.json")" -eq 0 ]]
rpc "$collaborator_token" delete_music_review \
  "{\"p_review_id\":\"$album_review_id\"}" \
  "$smoke_tmp/album-review-delete.json"
[[ "$(jq -er '.' "$smoke_tmp/album-review-delete.json")" == "true" ]]

stage="expired session rejection"
expired_invite_code="EXP$(printf '%05d' "$((RANDOM % 100000))")"
expired_at="$(date -u -v-1H '+%Y-%m-%dT%H:%M:%SZ')"
rpc "$conductor_token" create_session \
  "{\"p_title\":\"Expired Harmony smoke\",\"p_invite_code\":\"$expired_invite_code\",\"p_playback_mode\":\"queue_only\",\"p_allow_collaborator_invites\":false,\"p_expires_at\":\"$expired_at\"}" \
  "$smoke_tmp/expired-session.json"
expired_join_status="$(rpc_status "$collaborator_token" join_session_by_invite \
  "{\"p_invite_code\":\"$expired_invite_code\"}" \
  "$smoke_tmp/expired-join.json")"
[[ "$expired_join_status" == "400" || "$expired_join_status" == "404" ]]

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
