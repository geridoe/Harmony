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
  if [[ "${HARMONY_KEEP_SMOKE_ARTIFACTS:-0}" == "1" ]]; then
    printf 'Smoke artifacts retained at: %s\n' "$smoke_tmp" >&2
  fi
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
  if [[ "${HARMONY_KEEP_SMOKE_ARTIFACTS:-0}" != "1" ]]; then
    rm -rf "$smoke_tmp"
  fi
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

rest_patch_status() {
  local token="$1"
  local path="$2"
  local body="$3"
  local output_file="$4"
  curl --silent --show-error \
    -X PATCH "$supabase_url/rest/v1/$path" \
    -H "apikey: $publishable_key" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -H "Prefer: return=representation" \
    --data "$body" \
    -o "$output_file" \
    -w '%{http_code}'
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
  "profile_social_settings?select=profile_id,live_visibility,history_visibility,reviews_visibility,shelf_visibility,record_harmony_plays&profile_id=eq.$conductor_id" \
  "$smoke_tmp/private-settings.json"
jq -e 'length == 1 and .[0].live_visibility == "private" and .[0].history_visibility == "private" and .[0].reviews_visibility == "private" and .[0].shelf_visibility == "private" and .[0].record_harmony_plays == false' "$smoke_tmp/private-settings.json" >/dev/null
rest_patch "$conductor_token" \
  "profiles?id=eq.$conductor_id" \
  '{"display_name":"Harmony Smoke Conductor"}' \
  "$smoke_tmp/profile-update.json"
jq -e 'length == 1 and .[0].display_name == "Harmony Smoke Conductor"' "$smoke_tmp/profile-update.json" >/dev/null
rest_patch "$conductor_token" \
  "profile_social_settings?profile_id=eq.$conductor_id" \
  '{"live_visibility":"followers","history_visibility":"private","reviews_visibility":"followers","shelf_visibility":"followers","record_harmony_plays":true}' \
  "$smoke_tmp/settings-update.json"
jq -e 'length == 1 and .[0].live_visibility == "followers" and .[0].history_visibility == "private" and .[0].reviews_visibility == "followers" and .[0].shelf_visibility == "followers" and .[0].record_harmony_plays == true' "$smoke_tmp/settings-update.json" >/dev/null

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
invalid_catalog_artwork_status="$(rpc_status "$conductor_token" resolve_harmony_track \
  '{"p_provider":"spotify","p_provider_id":"spotify:track:harmony-invalid-artwork","p_title":"Invalid Artwork Track","p_artist":"Harmony Test Artist","p_artwork_url":"http://example.com/not-secure.jpg","p_deep_link":"https://open.spotify.com/track/harmony-invalid-artwork"}' \
  "$smoke_tmp/invalid-catalog-artwork.json")"
[[ "$invalid_catalog_artwork_status" == "400" ]]
invalid_catalog_link_status="$(rpc_status "$conductor_token" resolve_harmony_track \
  '{"p_provider":"spotify","p_provider_id":"spotify:track:harmony-invalid-link","p_title":"Invalid Link Track","p_artist":"Harmony Test Artist","p_artwork_url":"https://example.com/secure.jpg","p_deep_link":"https://open.spotify.com.evil.example/track/harmony-invalid-link"}' \
  "$smoke_tmp/invalid-catalog-link.json")"
[[ "$invalid_catalog_link_status" == "400" ]]
rpc "$conductor_token" resolve_harmony_track \
  '{"p_provider":"spotify","p_provider_id":"spotify:track:harmony-smoke-valid-url","p_title":"Harmony Spotify URL Smoke","p_artist":"Harmony Test Artist","p_album":"Harmony Test Album","p_duration_ms":180000,"p_artwork_url":"https://i.scdn.co/image/harmony-smoke","p_is_explicit":false,"p_deep_link":"https://open.spotify.com/track/harmony-smoke-valid-url"}' \
  "$smoke_tmp/spotify-url-track.json"
spotify_url_track_id="$(jq -er '.' "$smoke_tmp/spotify-url-track.json")"
rpc "$conductor_token" resolve_harmony_track \
  '{"p_provider":"apple_music","p_provider_id":"harmony-smoke-apple-track","p_title":"Harmony Smoke Track","p_artist":"Harmony Test Artist","p_album":"Harmony Test Album","p_duration_ms":180000,"p_artwork_url":"https://is1-ssl.mzstatic.com/image/thumb/harmony-smoke/300x300.jpg","p_is_explicit":false,"p_deep_link":"https://music.apple.com/us/song/harmony-smoke/123456789"}' \
  "$smoke_tmp/canonical-track.json"
canonical_track_id="$(jq -er '.' "$smoke_tmp/canonical-track.json")"
rpc "$conductor_token" resolve_harmony_track \
  '{"p_provider":"apple_music","p_provider_id":"harmony-smoke-apple-track","p_title":"Changed display title","p_artist":"Changed display artist","p_album":null,"p_duration_ms":181000,"p_artwork_url":null,"p_is_explicit":false,"p_deep_link":null}' \
  "$smoke_tmp/canonical-track-repeat.json"
[[ "$(jq -er '.' "$smoke_tmp/canonical-track-repeat.json")" == "$canonical_track_id" ]]

invalid_isrc_status="$(rpc_status "$conductor_token" resolve_harmony_track_v2 \
  '{"p_provider":"spotify","p_provider_id":"spotify:track:harmony-invalid-isrc","p_title":"Invalid ISRC","p_artist":"Harmony Test Artist","p_album":"Identity","p_duration_ms":180000,"p_artwork_url":null,"p_is_explicit":false,"p_deep_link":null,"p_isrc":"not-an-isrc","p_storefront":"global"}' \
  "$smoke_tmp/invalid-isrc.json")"
[[ "$invalid_isrc_status" == "400" ]]
invalid_storefront_status="$(rpc_status "$conductor_token" resolve_harmony_track_v2 \
  '{"p_provider":"spotify","p_provider_id":"spotify:track:harmony-invalid-storefront","p_title":"Invalid Storefront","p_artist":"Harmony Test Artist","p_album":"Identity","p_duration_ms":180000,"p_artwork_url":null,"p_is_explicit":false,"p_deep_link":null,"p_isrc":null,"p_storefront":"north-america"}' \
  "$smoke_tmp/invalid-storefront.json")"
[[ "$invalid_storefront_status" == "400" ]]

rpc "$conductor_token" resolve_harmony_track_v2 \
  '{"p_provider":"spotify","p_provider_id":"spotify:track:harmony-cross-isrc","p_title":"Cross Provider Recording","p_artist":"Harmony Identity","p_album":"Original Album","p_duration_ms":180000,"p_artwork_url":null,"p_is_explicit":false,"p_deep_link":"https://open.spotify.com/track/harmony-cross-isrc","p_isrc":"QZHAR2600101","p_storefront":"global"}' \
  "$smoke_tmp/cross-isrc-spotify.json"
cross_isrc_track_id="$(jq -er '.' "$smoke_tmp/cross-isrc-spotify.json")"
rpc "$conductor_token" resolve_harmony_track_v2 \
  '{"p_provider":"apple_music","p_provider_id":"harmony-cross-isrc-apple","p_title":"Cross Provider Recording","p_artist":"Harmony Identity","p_album":"Compilation Album","p_duration_ms":181000,"p_artwork_url":null,"p_is_explicit":false,"p_deep_link":"https://music.apple.com/us/song/harmony-cross-isrc/90101","p_isrc":"qz-har-26-00101","p_storefront":"us"}' \
  "$smoke_tmp/cross-isrc-apple.json"
[[ "$(jq -er '.' "$smoke_tmp/cross-isrc-apple.json")" == "$cross_isrc_track_id" ]]
rpc "$conductor_token" resolve_harmony_track_v2 \
  '{"p_provider":"spotify","p_provider_id":"spotify:track:harmony-cross-isrc-alt","p_title":"Cross Provider Recording","p_artist":"Harmony Identity","p_album":"Deluxe Album","p_duration_ms":180500,"p_artwork_url":null,"p_is_explicit":false,"p_deep_link":"https://open.spotify.com/track/harmony-cross-isrc-alt","p_isrc":"QZHAR2600101","p_storefront":"global"}' \
  "$smoke_tmp/cross-isrc-spotify-alt.json"
[[ "$(jq -er '.' "$smoke_tmp/cross-isrc-spotify-alt.json")" == "$cross_isrc_track_id" ]]
rest_get "$conductor_token" \
  "provider_tracks?select=provider,provider_id,storefront&canonical_track_id=eq.$cross_isrc_track_id" \
  "$smoke_tmp/cross-isrc-mappings.json"
jq -e 'length == 3' "$smoke_tmp/cross-isrc-mappings.json" >/dev/null

rpc "$conductor_token" resolve_harmony_track_v2 \
  '{"p_provider":"spotify","p_provider_id":"spotify:track:harmony-variant-studio","p_title":"Same Name","p_artist":"Harmony Versions","p_album":"Studio","p_duration_ms":180000,"p_artwork_url":null,"p_is_explicit":false,"p_deep_link":null,"p_isrc":"QZHAR2600201","p_storefront":"global"}' \
  "$smoke_tmp/variant-studio.json"
rpc "$conductor_token" resolve_harmony_track_v2 \
  '{"p_provider":"spotify","p_provider_id":"spotify:track:harmony-variant-live","p_title":"Same Name","p_artist":"Harmony Versions","p_album":"Live","p_duration_ms":205000,"p_artwork_url":null,"p_is_explicit":false,"p_deep_link":null,"p_isrc":"QZHAR2600202","p_storefront":"global"}' \
  "$smoke_tmp/variant-live.json"
[[ "$(jq -er '.' "$smoke_tmp/variant-studio.json")" != "$(jq -er '.' "$smoke_tmp/variant-live.json")" ]]

rpc "$conductor_token" resolve_harmony_track_v2 \
  '{"p_provider":"spotify","p_provider_id":"spotify:track:harmony-metadata-match","p_title":"  Metadata   Match  ","p_artist":"Harmony Identity","p_album":"Shared Album","p_duration_ms":180000,"p_artwork_url":null,"p_is_explicit":false,"p_deep_link":null,"p_isrc":null,"p_storefront":"global"}' \
  "$smoke_tmp/metadata-match-spotify.json"
metadata_match_track_id="$(jq -er '.' "$smoke_tmp/metadata-match-spotify.json")"
rpc "$conductor_token" resolve_harmony_track_v2 \
  '{"p_provider":"apple_music","p_provider_id":"harmony-metadata-match-apple","p_title":"metadata match","p_artist":"harmony identity","p_album":"shared album","p_duration_ms":181999,"p_artwork_url":null,"p_is_explicit":false,"p_deep_link":null,"p_isrc":null,"p_storefront":"us"}' \
  "$smoke_tmp/metadata-match-apple.json"
[[ "$(jq -er '.' "$smoke_tmp/metadata-match-apple.json")" == "$metadata_match_track_id" ]]
rpc "$conductor_token" resolve_harmony_track_v2 \
  '{"p_provider":"apple_music","p_provider_id":"harmony-metadata-missing-album","p_title":"Metadata Match","p_artist":"Harmony Identity","p_album":null,"p_duration_ms":180000,"p_artwork_url":null,"p_is_explicit":false,"p_deep_link":null,"p_isrc":null,"p_storefront":"us"}' \
  "$smoke_tmp/metadata-missing-album.json"
[[ "$(jq -er '.' "$smoke_tmp/metadata-missing-album.json")" != "$metadata_match_track_id" ]]

canonical_pids=()
for canonical_index in 1 2 3 4; do
  rpc "$conductor_token" resolve_harmony_track_v2 \
    "{\"p_provider\":\"spotify\",\"p_provider_id\":\"spotify:track:harmony-concurrent-$canonical_index\",\"p_title\":\"Concurrent Recording\",\"p_artist\":\"Harmony Identity\",\"p_album\":\"Concurrency\",\"p_duration_ms\":180000,\"p_artwork_url\":null,\"p_is_explicit\":false,\"p_deep_link\":null,\"p_isrc\":\"QZHAR2600102\",\"p_storefront\":\"global\"}" \
    "$smoke_tmp/concurrent-canonical-$canonical_index.json" &
  canonical_pids+=("$!")
done
for canonical_pid in "${canonical_pids[@]}"; do wait "$canonical_pid"; done
jq -s -e 'unique | length == 1' "$smoke_tmp"/concurrent-canonical-*.json >/dev/null

stage="follower listening visibility"
presence_expires_at="$(date -u -v+5M '+%Y-%m-%dT%H:%M:%SZ')"
rpc "$collaborator_token" publish_listening_presence \
  "{\"p_canonical_track_id\":\"$cross_isrc_track_id\",\"p_provider\":\"apple_music\",\"p_provider_track_id\":\"harmony-cross-isrc-apple\",\"p_provider_deep_link\":\"https://music.apple.com/us/song/harmony-cross-isrc/90101\",\"p_status\":\"listening\",\"p_visibility\":\"followers\",\"p_started_at\":\"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\",\"p_expires_at\":\"$presence_expires_at\"}" \
  "$smoke_tmp/presence.json"
rest_get "$conductor_token" \
  "listening_presence?select=profile_id,broadcast_id,canonical_track_id,status&profile_id=eq.$collaborator_id" \
  "$smoke_tmp/follower-presence.json"
jq -e --arg profile "$collaborator_id" --arg track "$cross_isrc_track_id" 'length == 1 and .[0].profile_id == $profile and .[0].canonical_track_id == $track and .[0].status == "listening"' "$smoke_tmp/follower-presence.json" >/dev/null
listening_broadcast_id="$(jq -er '.[0].broadcast_id' "$smoke_tmp/follower-presence.json")"
rpc "$conductor_token" list_eavesdrop_broadcasts \
  "{\"p_broadcast_id\":\"$listening_broadcast_id\",\"p_viewer_provider\":\"spotify\",\"p_storefront\":\"global\"}" \
  "$smoke_tmp/eavesdrop-cross-provider.json"
jq -e --arg broadcast "$listening_broadcast_id" --arg host "$collaborator_id" '
  length == 1 and .[0].broadcast_id == $broadcast
  and .[0].host_profile_id == $host
  and .[0].source_provider == "apple_music"
  and .[0].viewer_provider == "spotify"
  and (.[] | .viewer_provider_track_id | length) > 0
' "$smoke_tmp/eavesdrop-cross-provider.json" >/dev/null
rpc "$conductor_token" add_listening_broadcast_comment \
  "{\"p_broadcast_id\":\"$listening_broadcast_id\",\"p_body\":\"This transition is perfect.\"}" \
  "$smoke_tmp/eavesdrop-comment.json"
listening_comment_id="$(jq -er 'if type == "array" then .[0].id else .id end' "$smoke_tmp/eavesdrop-comment.json")"
rpc "$conductor_token" toggle_listening_broadcast_reaction \
  "{\"p_broadcast_id\":\"$listening_broadcast_id\",\"p_kind\":\"headphones\"}" \
  "$smoke_tmp/eavesdrop-reaction.json"
[[ "$(jq -er '.' "$smoke_tmp/eavesdrop-reaction.json")" == "true" ]]
rest_get "$collaborator_token" \
  "social_notifications?select=kind,listening_broadcast_id,listening_broadcast_comment_id&listening_broadcast_id=eq.$listening_broadcast_id" \
  "$smoke_tmp/eavesdrop-notifications.json"
jq -e --arg comment "$listening_comment_id" '
  any(.[]; .kind == "listening_broadcast_comment" and .listening_broadcast_comment_id == $comment)
  and any(.[]; .kind == "listening_broadcast_reaction")
' "$smoke_tmp/eavesdrop-notifications.json" >/dev/null
presence_refresh_expires_at="$(date -u -v+6M '+%Y-%m-%dT%H:%M:%SZ')"
rpc "$collaborator_token" publish_listening_presence \
  "{\"p_canonical_track_id\":\"$cross_isrc_track_id\",\"p_provider\":\"apple_music\",\"p_provider_track_id\":\"harmony-cross-isrc-apple\",\"p_provider_deep_link\":\"https://music.apple.com/us/song/harmony-cross-isrc/90101\",\"p_status\":\"listening\",\"p_visibility\":\"followers\",\"p_started_at\":\"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\",\"p_expires_at\":\"$presence_refresh_expires_at\"}" \
  "$smoke_tmp/refreshed-presence.json"
rest_get "$collaborator_token" \
  "listening_presence?select=broadcast_id&profile_id=eq.$collaborator_id" \
  "$smoke_tmp/refreshed-presence-id.json"
[[ "$(jq -er '.[0].broadcast_id' "$smoke_tmp/refreshed-presence-id.json")" == "$listening_broadcast_id" ]]
rpc "$collaborator_token" record_listening_history \
  "{\"p_canonical_track_id\":\"$canonical_track_id\",\"p_provider\":\"apple_music\",\"p_provider_track_id\":\"harmony-smoke-apple-track\",\"p_played_at\":\"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\",\"p_source\":\"manual\",\"p_visibility\":\"followers\",\"p_rating\":4.0}" \
  "$smoke_tmp/history.json"
history_entry_id="$(jq -er 'if type == "array" then .[0].id else .id end' "$smoke_tmp/history.json")"
history_played_at="$(jq -er 'if type == "array" then .[0].played_at else .played_at end' "$smoke_tmp/history.json")"
rest_get "$conductor_token" \
  "listening_history_entries?select=profile_id,canonical_track_id&profile_id=eq.$collaborator_id" \
  "$smoke_tmp/follower-history.json"
jq -e --arg profile "$collaborator_id" --arg track "$canonical_track_id" 'length == 1 and .[0].profile_id == $profile and .[0].canonical_track_id == $track' "$smoke_tmp/follower-history.json" >/dev/null
rest_get "$conductor_token" \
  "listening_history_entries?select=id,profile_id,played_at,source,visibility,rating,canonical_tracks(title,artist,album,duration_ms,artwork_url,is_explicit),profiles(display_name)&id=eq.$history_entry_id" \
  "$smoke_tmp/history-detail.json"
jq -e 'length == 1 and .[0].rating == 4.0 and .[0].canonical_tracks.title == "Harmony Smoke Track" and (.[] | .profiles.display_name | length) > 0' "$smoke_tmp/history-detail.json" >/dev/null
rest_get "$conductor_token" \
  "social_activity_events?select=id,kind,actor_id,diary_entry_id,review_id&diary_entry_id=eq.$history_entry_id" \
  "$smoke_tmp/manual-diary-activity.json"
jq -e --arg actor "$collaborator_id" --arg entry "$history_entry_id" 'length == 1 and .[0].kind == "diary_logged" and .[0].actor_id == $actor and .[0].diary_entry_id == $entry and .[0].review_id == null' "$smoke_tmp/manual-diary-activity.json" >/dev/null
rpc "$collaborator_token" record_listening_history \
  "{\"p_canonical_track_id\":\"$canonical_track_id\",\"p_provider\":\"apple_music\",\"p_provider_track_id\":\"harmony-smoke-apple-track\",\"p_played_at\":\"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\",\"p_source\":\"harmony_room\",\"p_visibility\":\"followers\"}" \
  "$smoke_tmp/harmony-room-history.json"
harmony_room_history_id="$(jq -er 'if type == "array" then .[0].id else .id end' "$smoke_tmp/harmony-room-history.json")"
rest_get "$conductor_token" \
  "social_activity_events?select=id&diary_entry_id=eq.$harmony_room_history_id" \
  "$smoke_tmp/harmony-room-activity.json"
[[ "$(jq 'length' "$smoke_tmp/harmony-room-activity.json")" -eq 0 ]]

stage="independent track subject state and diary rating"
rest_get "$collaborator_token" \
  "profile_track_subject_states?select=profile_id,canonical_track_id,has_listened,default_rating,is_loved,want_to_listen&canonical_track_id=eq.$canonical_track_id" \
  "$smoke_tmp/initial-track-subject-state.json"
jq -e --arg profile "$collaborator_id" 'length == 1 and .[0].profile_id == $profile and .[0].has_listened == true and .[0].default_rating == 4.0 and .[0].is_loved == false and .[0].want_to_listen == false' "$smoke_tmp/initial-track-subject-state.json" >/dev/null
rest_get "$conductor_token" \
  "profile_track_subject_states?select=profile_id&profile_id=eq.$collaborator_id" \
  "$smoke_tmp/foreign-track-subject-state.json"
[[ "$(jq 'length' "$smoke_tmp/foreign-track-subject-state.json")" -eq 0 ]]
unauthorized_diary_rating_status="$(rpc_status "$conductor_token" set_listening_diary_rating \
  "{\"p_entry_id\":\"$history_entry_id\",\"p_rating\":1.0}" \
  "$smoke_tmp/unauthorized-diary-rating.json")"
[[ "$unauthorized_diary_rating_status" == "400" || "$unauthorized_diary_rating_status" == "404" ]]
invalid_diary_rating_status="$(rpc_status "$collaborator_token" set_listening_diary_rating \
  "{\"p_entry_id\":\"$history_entry_id\",\"p_rating\":4.2}" \
  "$smoke_tmp/invalid-diary-rating.json")"
[[ "$invalid_diary_rating_status" == "400" ]]
rpc "$collaborator_token" set_listening_diary_rating \
  "{\"p_entry_id\":\"$history_entry_id\",\"p_rating\":4.5}" \
  "$smoke_tmp/updated-diary-rating.json"
rest_get "$collaborator_token" \
  "listening_history_entries?select=id,rating&id=eq.$history_entry_id" \
  "$smoke_tmp/diary-rating-snapshot.json"
jq -e 'length == 1 and .[0].rating == 4.5' "$smoke_tmp/diary-rating-snapshot.json" >/dev/null
rpc "$collaborator_token" set_my_track_subject_state \
  "{\"p_canonical_track_id\":\"$canonical_track_id\",\"p_has_listened\":true,\"p_default_rating\":3.5,\"p_is_loved\":true,\"p_want_to_listen\":true}" \
  "$smoke_tmp/updated-track-subject-state.json"
jq -e '(if type == "array" then .[0] else . end) | .has_listened == true and .default_rating == 3.5 and .is_loved == true and .want_to_listen == false' "$smoke_tmp/updated-track-subject-state.json" >/dev/null
rest_get "$collaborator_token" \
  "listening_history_entries?select=id,rating&id=eq.$history_entry_id" \
  "$smoke_tmp/independent-diary-rating.json"
jq -e 'length == 1 and .[0].rating == 4.5' "$smoke_tmp/independent-diary-rating.json" >/dev/null
rpc "$collaborator_token" set_my_track_subject_state \
  "{\"p_canonical_track_id\":\"$spotify_url_track_id\",\"p_has_listened\":false,\"p_default_rating\":null,\"p_is_loved\":false,\"p_want_to_listen\":true}" \
  "$smoke_tmp/want-to-listen-state.json"
jq -e '(if type == "array" then .[0] else . end) | .has_listened == false and .default_rating == null and .is_loved == false and .want_to_listen == true' "$smoke_tmp/want-to-listen-state.json" >/dev/null
clear_listened_with_history_status="$(rpc_status "$collaborator_token" set_my_track_subject_state \
  "{\"p_canonical_track_id\":\"$canonical_track_id\",\"p_has_listened\":false,\"p_default_rating\":null,\"p_is_loved\":true,\"p_want_to_listen\":false}" \
  "$smoke_tmp/clear-listened-with-history.json")"
[[ "$clear_listened_with_history_status" == "400" ]]

stage="owner diary keyset pagination"
rpc "$collaborator_token" record_listening_history \
  "{\"p_canonical_track_id\":\"$canonical_track_id\",\"p_provider\":\"apple_music\",\"p_provider_track_id\":\"harmony-smoke-apple-track\",\"p_played_at\":\"$history_played_at\",\"p_source\":\"manual\",\"p_visibility\":\"private\",\"p_is_relisten\":true,\"p_tags\":[\"same-time\"]}" \
  "$smoke_tmp/tied-diary-entry.json"
tied_history_entry_id="$(jq -er 'if type == "array" then .[0].id else .id end' "$smoke_tmp/tied-diary-entry.json")"
expected_first_tied_id="$(printf '%s\n%s\n' "$history_entry_id" "$tied_history_entry_id" | LC_ALL=C sort -r | head -1)"
expected_second_tied_id="$(printf '%s\n%s\n' "$history_entry_id" "$tied_history_entry_id" | LC_ALL=C sort | head -1)"
rpc "$collaborator_token" list_my_listening_diary \
  '{"p_before_played_at":null,"p_before_id":null,"p_limit":1}' \
  "$smoke_tmp/diary-first-page.json"
first_page_id="$(jq -er '.[0].id' "$smoke_tmp/diary-first-page.json")"
first_page_played_at="$(jq -er '.[0].played_at' "$smoke_tmp/diary-first-page.json")"
[[ "$first_page_id" == "$expected_first_tied_id" ]]
rest_get "$collaborator_token" \
  "rpc/list_my_listening_diary?p_limit=1&select=id,canonical_tracks(id,title),profiles(display_name)" \
  "$smoke_tmp/diary-client-shape.json"
jq -e --arg entry "$expected_first_tied_id" --arg track "$canonical_track_id" '. | length == 1 and .[0].id == $entry and .[0].canonical_tracks.id == $track and .[0].canonical_tracks.title == "Harmony Smoke Track" and (.[] | .profiles.display_name | length) > 0' "$smoke_tmp/diary-client-shape.json" >/dev/null
rpc "$collaborator_token" list_my_listening_diary \
  "{\"p_before_played_at\":\"$first_page_played_at\",\"p_before_id\":\"$first_page_id\",\"p_limit\":2}" \
  "$smoke_tmp/diary-second-page.json"
jq -e --arg second "$expected_second_tied_id" 'length >= 1 and .[0].id == $second' "$smoke_tmp/diary-second-page.json" >/dev/null
rpc "$conductor_token" list_my_listening_diary \
  '{"p_before_played_at":null,"p_before_id":null,"p_limit":50}' \
  "$smoke_tmp/foreign-diary-page.json"
[[ "$(jq 'length' "$smoke_tmp/foreign-diary-page.json")" -eq 0 ]]
partial_diary_cursor_status="$(rpc_status "$collaborator_token" list_my_listening_diary \
  "{\"p_before_played_at\":\"$first_page_played_at\",\"p_before_id\":null,\"p_limit\":50}" \
  "$smoke_tmp/partial-diary-cursor.json")"
[[ "$partial_diary_cursor_status" == "400" ]]

stage="follower music reviews"
rpc "$collaborator_token" create_music_review \
  "{\"p_subject_kind\":\"track\",\"p_canonical_track_id\":\"$canonical_track_id\",\"p_provider\":\"apple_music\",\"p_provider_subject_id\":null,\"p_rating\":4.5,\"p_body\":\"A great Harmony smoke review.\",\"p_visibility\":\"followers\",\"p_contains_spoilers\":true,\"p_is_loved\":true}" \
  "$smoke_tmp/review.json"
review_id="$(jq -er 'if type == "array" then .[0].id else .id end' "$smoke_tmp/review.json")"
rest_get "$conductor_token" \
  "music_reviews?select=id,profile_id,subject_kind,subject_title,subject_artist,rating,contains_spoilers,is_loved,body&id=eq.$review_id" \
  "$smoke_tmp/follower-review.json"
jq -e --arg profile "$collaborator_id" 'length == 1 and .[0].profile_id == $profile and .[0].subject_kind == "track" and .[0].subject_title == "Harmony Smoke Track" and .[0].rating == 4.5 and .[0].contains_spoilers == true and .[0].is_loved == true' "$smoke_tmp/follower-review.json" >/dev/null
rest_get "$collaborator_token" \
  "profile_track_subject_states?select=has_listened,default_rating,is_loved,want_to_listen&canonical_track_id=eq.$canonical_track_id" \
  "$smoke_tmp/review-created-track-state.json"
jq -e 'length == 1 and .[0].has_listened == true and .[0].default_rating == 4.5 and .[0].is_loved == true and .[0].want_to_listen == false' "$smoke_tmp/review-created-track-state.json" >/dev/null

stage="following activity keyset and current visibility"
rpc "$conductor_token" list_following_activity \
  '{"p_before_published_at":null,"p_before_id":null,"p_limit":1}' \
  "$smoke_tmp/activity-first-page.json"
activity_first_id="$(jq -er '.[0].id' "$smoke_tmp/activity-first-page.json")"
activity_first_published_at="$(jq -er '.[0].published_at' "$smoke_tmp/activity-first-page.json")"
jq -e --arg review "$review_id" 'length == 1 and .[0].kind == "review_published" and .[0].review_id == $review' "$smoke_tmp/activity-first-page.json" >/dev/null
rpc "$conductor_token" list_following_activity \
  "{\"p_before_published_at\":\"$activity_first_published_at\",\"p_before_id\":\"$activity_first_id\",\"p_limit\":10}" \
  "$smoke_tmp/activity-second-page.json"
jq -e --arg entry "$history_entry_id" 'length == 1 and .[0].kind == "diary_logged" and .[0].diary_entry_id == $entry' "$smoke_tmp/activity-second-page.json" >/dev/null
rpc "$collaborator_token" list_following_activity \
  '{"p_before_published_at":null,"p_before_id":null,"p_limit":10}' \
  "$smoke_tmp/own-activity-page.json"
jq -e 'length == 2' "$smoke_tmp/own-activity-page.json" >/dev/null
partial_activity_cursor_status="$(rpc_status "$conductor_token" list_following_activity \
  "{\"p_before_published_at\":\"$activity_first_published_at\",\"p_before_id\":null,\"p_limit\":50}" \
  "$smoke_tmp/partial-activity-cursor.json")"
[[ "$partial_activity_cursor_status" == "400" ]]
rpc "$collaborator_token" update_music_review \
  "{\"p_review_id\":\"$review_id\",\"p_rating\":4.5,\"p_body\":\"A great Harmony smoke review.\",\"p_visibility\":\"private\",\"p_contains_spoilers\":true,\"p_is_loved\":true}" \
  "$smoke_tmp/private-review.json"
rest_get "$conductor_token" \
  "social_activity_events?select=id&review_id=eq.$review_id" \
  "$smoke_tmp/private-review-activity.json"
[[ "$(jq 'length' "$smoke_tmp/private-review-activity.json")" -eq 0 ]]
rpc "$collaborator_token" update_music_review \
  "{\"p_review_id\":\"$review_id\",\"p_rating\":4.5,\"p_body\":\"A great Harmony smoke review.\",\"p_visibility\":\"followers\",\"p_contains_spoilers\":true,\"p_is_loved\":true}" \
  "$smoke_tmp/republished-review.json"
rest_get "$conductor_token" \
  "social_activity_events?select=id&review_id=eq.$review_id" \
  "$smoke_tmp/republished-review-activity.json"
jq -e --arg event "$activity_first_id" 'length == 1 and .[0].id == $event' "$smoke_tmp/republished-review-activity.json" >/dev/null

stage="owner diary editing and review linkage"
unauthorized_diary_update_status="$(rpc_status "$conductor_token" update_listening_diary_entry \
  "{\"p_entry_id\":\"$history_entry_id\",\"p_played_at\":\"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\",\"p_visibility\":\"private\",\"p_is_relisten\":false,\"p_tags\":[],\"p_review_id\":null}" \
  "$smoke_tmp/unauthorized-diary-update.json")"
[[ "$unauthorized_diary_update_status" == "400" || "$unauthorized_diary_update_status" == "404" ]]
rpc "$collaborator_token" update_listening_diary_entry \
  "{\"p_entry_id\":\"$history_entry_id\",\"p_played_at\":\"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\",\"p_visibility\":\"followers\",\"p_is_relisten\":true,\"p_tags\":[\" Road Trip \",\"road trip\",\"NIGHT\"],\"p_review_id\":\"$review_id\"}" \
  "$smoke_tmp/diary-update.json"
rest_get "$collaborator_token" \
  "listening_history_entries?select=id,source,visibility,is_relisten,tags,review_id&id=eq.$history_entry_id" \
  "$smoke_tmp/updated-diary.json"
jq -e --arg review "$review_id" 'length == 1 and .[0].source == "manual" and .[0].visibility == "followers" and .[0].is_relisten == true and .[0].tags == ["road trip", "night"] and .[0].review_id == $review' "$smoke_tmp/updated-diary.json" >/dev/null
unauthorized_atomic_diary_update_status="$(rpc_status "$conductor_token" update_listening_diary_entry_with_rating \
  "{\"p_entry_id\":\"$history_entry_id\",\"p_played_at\":\"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\",\"p_visibility\":\"private\",\"p_is_relisten\":false,\"p_tags\":[],\"p_review_id\":null,\"p_rating\":1.0}" \
  "$smoke_tmp/unauthorized-atomic-diary-update.json")"
[[ "$unauthorized_atomic_diary_update_status" == "400" || "$unauthorized_atomic_diary_update_status" == "404" ]]
invalid_atomic_diary_rating_status="$(rpc_status "$collaborator_token" update_listening_diary_entry_with_rating \
  "{\"p_entry_id\":\"$history_entry_id\",\"p_played_at\":\"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\",\"p_visibility\":\"followers\",\"p_is_relisten\":false,\"p_tags\":[\"atomic\"],\"p_review_id\":\"$review_id\",\"p_rating\":4.2}" \
  "$smoke_tmp/invalid-atomic-diary-rating.json")"
[[ "$invalid_atomic_diary_rating_status" == "400" ]]
rpc "$collaborator_token" update_listening_diary_entry_with_rating \
  "{\"p_entry_id\":\"$history_entry_id\",\"p_played_at\":\"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\",\"p_visibility\":\"followers\",\"p_is_relisten\":false,\"p_tags\":[\" Atomic \",\"atomic\",\"LIVE\"],\"p_review_id\":\"$review_id\",\"p_rating\":null}" \
  "$smoke_tmp/atomic-diary-rating-clear.json"
rest_get "$collaborator_token" \
  "listening_history_entries?select=id,visibility,is_relisten,tags,review_id,rating&id=eq.$history_entry_id" \
  "$smoke_tmp/atomic-diary-rating-cleared.json"
jq -e --arg review "$review_id" 'length == 1 and .[0].visibility == "followers" and .[0].is_relisten == false and .[0].tags == ["atomic", "live"] and .[0].review_id == $review and .[0].rating == null' "$smoke_tmp/atomic-diary-rating-cleared.json" >/dev/null
rest_get "$collaborator_token" \
  "profile_track_subject_states?select=default_rating&canonical_track_id=eq.$canonical_track_id" \
  "$smoke_tmp/atomic-default-rating-cleared.json"
jq -e 'length == 1 and .[0].default_rating == null' "$smoke_tmp/atomic-default-rating-cleared.json" >/dev/null
rpc "$collaborator_token" update_listening_diary_entry_with_rating \
  "{\"p_entry_id\":\"$history_entry_id\",\"p_played_at\":\"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\",\"p_visibility\":\"followers\",\"p_is_relisten\":true,\"p_tags\":[\"Atomic\",\"NIGHT\"],\"p_review_id\":\"$review_id\",\"p_rating\":2.5}" \
  "$smoke_tmp/atomic-diary-update.json"
rest_get "$collaborator_token" \
  "listening_history_entries?select=id,visibility,is_relisten,tags,review_id,rating&id=eq.$history_entry_id" \
  "$smoke_tmp/atomically-updated-diary.json"
jq -e --arg review "$review_id" 'length == 1 and .[0].visibility == "followers" and .[0].is_relisten == true and .[0].tags == ["atomic", "night"] and .[0].review_id == $review and .[0].rating == 2.5' "$smoke_tmp/atomically-updated-diary.json" >/dev/null
rest_get "$collaborator_token" \
  "profile_track_subject_states?select=default_rating,is_loved&canonical_track_id=eq.$canonical_track_id" \
  "$smoke_tmp/atomic-default-rating.json"
jq -e 'length == 1 and .[0].default_rating == 2.5 and .[0].is_loved == true' "$smoke_tmp/atomic-default-rating.json" >/dev/null

stage="owner track-state shelf keyset pagination"
rpc "$collaborator_token" list_my_track_subject_states \
  '{"p_before_updated_at":null,"p_before_canonical_track_id":null,"p_limit":1}' \
  "$smoke_tmp/track-state-first-page.json"
track_state_first_id="$(jq -er '.[0].canonical_track_id' "$smoke_tmp/track-state-first-page.json")"
track_state_first_updated_at="$(jq -er '.[0].updated_at' "$smoke_tmp/track-state-first-page.json")"
[[ "$track_state_first_id" == "$canonical_track_id" ]]
rpc "$collaborator_token" list_my_track_subject_states \
  "{\"p_before_updated_at\":\"$track_state_first_updated_at\",\"p_before_canonical_track_id\":\"$track_state_first_id\",\"p_limit\":10}" \
  "$smoke_tmp/track-state-second-page.json"
jq -e --arg first "$track_state_first_id" --arg expected "$spotify_url_track_id" 'length == 1 and .[0].canonical_track_id != $first and .[0].canonical_track_id == $expected' "$smoke_tmp/track-state-second-page.json" >/dev/null
rpc "$conductor_token" list_my_track_subject_states \
  '{"p_before_updated_at":null,"p_before_canonical_track_id":null,"p_limit":50}' \
  "$smoke_tmp/foreign-track-state-page.json"
[[ "$(jq 'length' "$smoke_tmp/foreign-track-state-page.json")" -eq 0 ]]
partial_track_state_cursor_status="$(rpc_status "$collaborator_token" list_my_track_subject_states \
  "{\"p_before_updated_at\":\"$track_state_first_updated_at\",\"p_before_canonical_track_id\":null,\"p_limit\":50}" \
  "$smoke_tmp/partial-track-state-cursor.json")"
[[ "$partial_track_state_cursor_status" == "400" ]]
oversized_track_state_page_status="$(rpc_status "$collaborator_token" list_my_track_subject_states \
  '{"p_before_updated_at":null,"p_before_canonical_track_id":null,"p_limit":101}' \
  "$smoke_tmp/oversized-track-state-page.json")"
[[ "$oversized_track_state_page_status" == "400" ]]
stage="first follower publication is idempotent"
rpc "$collaborator_token" update_listening_diary_entry \
  "{\"p_entry_id\":\"$tied_history_entry_id\",\"p_played_at\":\"$history_played_at\",\"p_visibility\":\"followers\",\"p_is_relisten\":true,\"p_tags\":[\"same-time\"],\"p_review_id\":null}" \
  "$smoke_tmp/published-tied-diary.json"
rest_get "$conductor_token" \
  "social_activity_events?select=id&diary_entry_id=eq.$tied_history_entry_id" \
  "$smoke_tmp/published-tied-diary-activity.json"
tied_activity_id="$(jq -er '.[0].id' "$smoke_tmp/published-tied-diary-activity.json")"
rpc "$collaborator_token" update_listening_diary_entry \
  "{\"p_entry_id\":\"$tied_history_entry_id\",\"p_played_at\":\"$history_played_at\",\"p_visibility\":\"private\",\"p_is_relisten\":true,\"p_tags\":[\"same-time\"],\"p_review_id\":null}" \
  "$smoke_tmp/private-tied-diary.json"
rest_get "$conductor_token" \
  "social_activity_events?select=id&diary_entry_id=eq.$tied_history_entry_id" \
  "$smoke_tmp/private-tied-diary-activity.json"
[[ "$(jq 'length' "$smoke_tmp/private-tied-diary-activity.json")" -eq 0 ]]
rpc "$collaborator_token" update_listening_diary_entry \
  "{\"p_entry_id\":\"$tied_history_entry_id\",\"p_played_at\":\"$history_played_at\",\"p_visibility\":\"followers\",\"p_is_relisten\":true,\"p_tags\":[\"same-time\"],\"p_review_id\":null}" \
  "$smoke_tmp/republished-tied-diary.json"
rest_get "$conductor_token" \
  "social_activity_events?select=id&diary_entry_id=eq.$tied_history_entry_id" \
  "$smoke_tmp/republished-tied-diary-activity.json"
jq -e --arg event "$tied_activity_id" 'length == 1 and .[0].id == $event' "$smoke_tmp/republished-tied-diary-activity.json" >/dev/null
stage="owner diary editing and review linkage"
invalid_album_link_status="$(rpc_status "$collaborator_token" create_music_review \
  '{"p_subject_kind":"album","p_provider":"spotify","p_provider_subject_id":"spotify:album:invalid","p_subject_title":"Invalid Link Album","p_subject_deep_link":"https://example.com/not-spotify","p_rating":3.0}' \
  "$smoke_tmp/invalid-album-link.json")"
[[ "$invalid_album_link_status" == "400" ]]
rpc "$collaborator_token" create_music_review \
  '{"p_subject_kind":"album","p_provider":"spotify","p_provider_subject_id":"spotify:album:harmony-smoke","p_subject_title":"Harmony Smoke Album","p_subject_artist":"Harmony Test Artist","p_subject_artwork_url":"https://example.com/harmony-smoke.jpg","p_subject_deep_link":"https://open.spotify.com/album/harmony-smoke","p_rating":4.0,"p_body":"An album diary entry.","p_visibility":"followers","p_contains_spoilers":false}' \
  "$smoke_tmp/album-review.json"
album_review_id="$(jq -er 'if type == "array" then .[0].id else .id end' "$smoke_tmp/album-review.json")"
rest_get "$conductor_token" \
  "music_reviews?select=id,subject_kind,canonical_album_id,subject_title,subject_artist,subject_deep_link&id=eq.$album_review_id" \
  "$smoke_tmp/follower-album-review.json"
jq -e 'length == 1 and .[0].subject_kind == "album" and .[0].subject_title == "Harmony Smoke Album" and .[0].subject_artist == "Harmony Test Artist"' "$smoke_tmp/follower-album-review.json" >/dev/null
album_canonical_id="$(jq -er '.[0].canonical_album_id' "$smoke_tmp/follower-album-review.json")"
rest_get "$conductor_token" \
  "music_reviews?select=id,canonical_album_id,canonical_albums(id,title,artist,release_date,upc,album_type,total_tracks,artwork_url,provider_albums(provider,provider_album_id,storefront,deep_link,availability,identity_basis))&id=eq.$album_review_id" \
  "$smoke_tmp/swift-shaped-canonical-album-review.json"
jq -e --arg album "$album_canonical_id" 'length == 1 and .[0].canonical_album_id == $album and .[0].canonical_albums.id == $album and .[0].canonical_albums.provider_albums[0].provider_album_id == "spotify:album:harmony-smoke"' "$smoke_tmp/swift-shaped-canonical-album-review.json" >/dev/null
rest_get "$conductor_token" \
  "provider_albums?select=canonical_album_id,provider,provider_album_id,storefront,identity_basis&canonical_album_id=eq.$album_canonical_id" \
  "$smoke_tmp/legacy-album-provider-mapping.json"
jq -e --arg album "$album_canonical_id" 'length == 1 and .[0].canonical_album_id == $album and .[0].provider == "spotify" and .[0].provider_album_id == "spotify:album:harmony-smoke" and .[0].storefront == "global" and .[0].identity_basis == "provider"' "$smoke_tmp/legacy-album-provider-mapping.json" >/dev/null
rpc "$collaborator_token" resolve_harmony_album \
  '{"p_provider":"spotify","p_provider_id":"spotify:album:harmony-smoke","p_title":"Changed snapshot title","p_artist":null,"p_artwork_url":null,"p_deep_link":"https://open.spotify.com/album/harmony-smoke"}' \
  "$smoke_tmp/resolved-legacy-album.json"
[[ "$(jq -er '.' "$smoke_tmp/resolved-legacy-album.json")" == "$album_canonical_id" ]]

stage="canonical album evidence boundaries"
invalid_album_upc_status="$(rpc_status "$collaborator_token" resolve_harmony_album_v2 \
  '{"p_provider":"spotify","p_provider_id":"spotify:album:harmony-invalid-upc","p_title":"Invalid UPC","p_artist":"Harmony Test Artist","p_artwork_url":null,"p_deep_link":"https://open.spotify.com/album/harmony-invalid-upc","p_upc":"not-a-upc","p_release_date":null,"p_total_tracks":null,"p_album_type":"album","p_storefront":"global"}' \
  "$smoke_tmp/invalid-album-upc.json")"
[[ "$invalid_album_upc_status" == "400" ]]
forged_album_upc_status="$(rpc_status "$collaborator_token" resolve_harmony_album_v2 \
  '{"p_provider":"spotify","p_provider_id":"spotify:album:harmony-upc","p_title":"UPC Evidence Album","p_artist":"Harmony Test Artist","p_artwork_url":null,"p_deep_link":"https://open.spotify.com/album/harmony-upc","p_upc":"123456789012","p_release_date":"2026-08-03","p_total_tracks":8,"p_album_type":"album","p_storefront":"global"}' \
  "$smoke_tmp/forged-album-upc.json")"
[[ "$forged_album_upc_status" == "403" ]]
jq -e '.details == "album_upc_attestation_required"' "$smoke_tmp/forged-album-upc.json" >/dev/null
rpc "$collaborator_token" resolve_harmony_album_v2 \
  '{"p_provider":"spotify","p_provider_id":"spotify:album:harmony-canonical-only","p_title":"Canonical-only Album","p_artist":"Harmony Test Artist","p_artwork_url":null,"p_deep_link":"https://open.spotify.com/album/harmony-canonical-only","p_upc":null,"p_release_date":"2026-08-03","p_total_tracks":8,"p_album_type":"album","p_storefront":"global"}' \
  "$smoke_tmp/canonical-only-album.json"
canonical_only_album_id="$(jq -er '.' "$smoke_tmp/canonical-only-album.json")"
rpc "$collaborator_token" resolve_harmony_album_v2 \
  '{"p_provider":"apple_music","p_provider_id":"harmony-title-only-apple","p_title":"Harmony Smoke Album","p_artist":"Harmony Test Artist","p_artwork_url":null,"p_deep_link":"https://music.apple.com/us/album/harmony-smoke-album/harmony-title-only-apple","p_upc":null,"p_release_date":null,"p_total_tracks":null,"p_album_type":"album","p_storefront":"us"}' \
  "$smoke_tmp/apple-title-only-album.json"
apple_title_only_album_id="$(jq -er '.' "$smoke_tmp/apple-title-only-album.json")"
[[ "$apple_title_only_album_id" != "$album_canonical_id" ]]
rpc "$conductor_token" list_canonical_album_reviews \
  "{\"p_canonical_album_id\":\"$album_canonical_id\",\"p_before_created_at\":null,\"p_before_id\":null,\"p_limit\":50}" \
  "$smoke_tmp/canonical-album-reviews.json"
jq -e --arg review "$album_review_id" 'any(.[]; .id == $review and .canonical_album_id != null)' "$smoke_tmp/canonical-album-reviews.json" >/dev/null
rpc "$collaborator_token" create_music_review \
  "{\"p_subject_kind\":\"album\",\"p_canonical_album_id\":\"$canonical_only_album_id\",\"p_rating\":4.5,\"p_body\":\"Canonical-only review.\",\"p_visibility\":\"private\"}" \
  "$smoke_tmp/canonical-only-album-review.json"
canonical_only_review_id="$(jq -er 'if type == "array" then .[0].id else .id end' "$smoke_tmp/canonical-only-album-review.json")"
jq -e --arg album "$canonical_only_album_id" '(if type == "array" then .[0] else . end) | .canonical_album_id == $album' "$smoke_tmp/canonical-only-album-review.json" >/dev/null
rpc "$collaborator_token" delete_music_review \
  "{\"p_review_id\":\"$canonical_only_review_id\"}" \
  "$smoke_tmp/deleted-canonical-only-album-review.json"

stage="album review synchronization and independent snapshots"
# Saving a canonical album review establishes current subject state. Soft
# deletion retains that state; it does not roll the owner backward.
rest_get "$collaborator_token" \
  "profile_album_subject_states?select=profile_id,canonical_album_id,has_listened,default_rating,is_loved,want_to_listen&canonical_album_id=in.($album_canonical_id,$canonical_only_album_id)" \
  "$smoke_tmp/album-review-synchronized-state.json"
jq -e --arg album "$album_canonical_id" --arg canonical_only "$canonical_only_album_id" '
  length == 2
  and any(.[]; .canonical_album_id == $album and .has_listened == true and .default_rating == 4.0 and .is_loved == false and .want_to_listen == false)
  and any(.[]; .canonical_album_id == $canonical_only and .has_listened == true and .default_rating == 4.5 and .is_loved == false and .want_to_listen == false)
' "$smoke_tmp/album-review-synchronized-state.json" >/dev/null
clear_listened_with_album_review_status="$(rpc_status "$collaborator_token" set_my_album_subject_state \
  "{\"p_canonical_album_id\":\"$album_canonical_id\",\"p_has_listened\":false,\"p_default_rating\":null,\"p_is_loved\":false,\"p_want_to_listen\":false}" \
  "$smoke_tmp/clear-listened-with-album-review.json")"
[[ "$clear_listened_with_album_review_status" == "400" ]]
rpc "$collaborator_token" update_music_review \
  "{\"p_review_id\":\"$album_review_id\",\"p_rating\":3.5,\"p_body\":\"An updated album diary entry.\",\"p_visibility\":\"followers\",\"p_contains_spoilers\":false,\"p_is_loved\":true}" \
  "$smoke_tmp/updated-album-review.json"
rest_get "$collaborator_token" \
  "profile_album_subject_states?select=has_listened,default_rating,is_loved,want_to_listen&canonical_album_id=eq.$album_canonical_id" \
  "$smoke_tmp/updated-album-review-state.json"
jq -e 'length == 1 and .[0].has_listened == true and .[0].default_rating == 3.5 and .[0].is_loved == true and .[0].want_to_listen == false' "$smoke_tmp/updated-album-review-state.json" >/dev/null
invalid_album_rating_status="$(rpc_status "$collaborator_token" set_my_album_subject_state \
  "{\"p_canonical_album_id\":\"$album_canonical_id\",\"p_has_listened\":true,\"p_default_rating\":4.2,\"p_is_loved\":false,\"p_want_to_listen\":false}" \
  "$smoke_tmp/invalid-album-rating.json")"
[[ "$invalid_album_rating_status" == "400" ]]
rpc "$collaborator_token" set_my_album_subject_state \
  "{\"p_canonical_album_id\":\"$album_canonical_id\",\"p_has_listened\":true,\"p_default_rating\":4.0,\"p_is_loved\":true,\"p_want_to_listen\":true}" \
  "$smoke_tmp/rated-album-state.json"
jq -e '(if type == "array" then .[0] else . end) | .has_listened == true and .default_rating == 4.0 and .is_loved == true and .want_to_listen == false' "$smoke_tmp/rated-album-state.json" >/dev/null
rpc "$collaborator_token" set_my_album_subject_state \
  "{\"p_canonical_album_id\":\"$canonical_only_album_id\",\"p_has_listened\":false,\"p_default_rating\":2.5,\"p_is_loved\":false,\"p_want_to_listen\":true}" \
  "$smoke_tmp/second-rated-album-state.json"
jq -e '(if type == "array" then .[0] else . end) | .has_listened == true and .default_rating == 2.5 and .want_to_listen == false' "$smoke_tmp/second-rated-album-state.json" >/dev/null
rpc "$collaborator_token" set_my_album_subject_state \
  "{\"p_canonical_album_id\":\"$apple_title_only_album_id\",\"p_has_listened\":false,\"p_default_rating\":null,\"p_is_loved\":false,\"p_want_to_listen\":true}" \
  "$smoke_tmp/want-album-state.json"
jq -e '(if type == "array" then .[0] else . end) | .has_listened == false and .default_rating == null and .want_to_listen == true' "$smoke_tmp/want-album-state.json" >/dev/null
rest_get "$conductor_token" \
  "profile_album_subject_states?select=profile_id&profile_id=eq.$collaborator_id" \
  "$smoke_tmp/foreign-album-state.json"
[[ "$(jq 'length' "$smoke_tmp/foreign-album-state.json")" -eq 0 ]]
direct_album_state_write_status="$(rest_patch_status "$collaborator_token" \
  "profile_album_subject_states?profile_id=eq.$collaborator_id&canonical_album_id=eq.$album_canonical_id" \
  '{"default_rating":1.0}' \
  "$smoke_tmp/direct-album-state-write.json")"
[[ "$direct_album_state_write_status" == "403" ]]
rest_get "$collaborator_token" \
  "profile_album_subject_states?select=canonical_album_id,default_rating,canonical_albums(id,title,artist,artwork_url)&canonical_album_id=eq.$album_canonical_id" \
  "$smoke_tmp/swift-shaped-album-state.json"
jq -e --arg album "$album_canonical_id" 'length == 1 and .[0].canonical_album_id == $album and .[0].default_rating == 4.0 and .[0].canonical_albums.id == $album and .[0].canonical_albums.title == "Harmony Smoke Album"' "$smoke_tmp/swift-shaped-album-state.json" >/dev/null
# State changes do not rewrite the review's authored rating or Loved snapshot.
rest_get "$collaborator_token" \
  "music_reviews?select=id,rating,is_loved&id=eq.$album_review_id" \
  "$smoke_tmp/album-state-independent-review.json"
jq -e 'length == 1 and .[0].rating == 3.5 and .[0].is_loved == true' "$smoke_tmp/album-state-independent-review.json" >/dev/null

stage="owner album Ratings shelf keyset pagination"
rpc "$collaborator_token" list_my_album_subject_states \
  '{"p_before_updated_at":null,"p_before_canonical_album_id":null,"p_limit":1,"p_scope":"rated"}' \
  "$smoke_tmp/rated-album-first-page.json"
rated_album_first_id="$(jq -er '.[0].canonical_album_id' "$smoke_tmp/rated-album-first-page.json")"
rated_album_first_updated_at="$(jq -er '.[0].updated_at' "$smoke_tmp/rated-album-first-page.json")"
rest_get "$collaborator_token" \
  "rpc/list_my_album_subject_states?p_limit=1&p_scope=rated&select=canonical_album_id,default_rating,canonical_albums(id,title,provider_albums(provider,provider_album_id,storefront))" \
  "$smoke_tmp/rated-album-client-shape.json"
jq -e --arg album "$rated_album_first_id" 'length == 1 and .[0].canonical_album_id == $album and .[0].default_rating != null and .[0].canonical_albums.id == $album and (.[] | .canonical_albums.provider_albums | length) > 0' "$smoke_tmp/rated-album-client-shape.json" >/dev/null
rpc "$collaborator_token" list_my_album_subject_states \
  "{\"p_before_updated_at\":\"$rated_album_first_updated_at\",\"p_before_canonical_album_id\":\"$rated_album_first_id\",\"p_limit\":10,\"p_scope\":\"rated\"}" \
  "$smoke_tmp/rated-album-second-page.json"
jq -e --arg first "$rated_album_first_id" 'length == 1 and .[0].canonical_album_id != $first and .[0].default_rating != null' "$smoke_tmp/rated-album-second-page.json" >/dev/null
rpc "$collaborator_token" list_my_album_subject_states \
  '{"p_before_updated_at":null,"p_before_canonical_album_id":null,"p_limit":50,"p_scope":"want_to_listen"}' \
  "$smoke_tmp/want-album-page.json"
jq -e --arg album "$apple_title_only_album_id" 'length == 1 and .[0].canonical_album_id == $album and .[0].want_to_listen == true' "$smoke_tmp/want-album-page.json" >/dev/null
rpc "$conductor_token" list_my_album_subject_states \
  '{"p_before_updated_at":null,"p_before_canonical_album_id":null,"p_limit":50,"p_scope":"all"}' \
  "$smoke_tmp/foreign-album-state-page.json"
[[ "$(jq 'length' "$smoke_tmp/foreign-album-state-page.json")" -eq 0 ]]
partial_album_state_cursor_status="$(rpc_status "$collaborator_token" list_my_album_subject_states \
  "{\"p_before_updated_at\":\"$rated_album_first_updated_at\",\"p_before_canonical_album_id\":null,\"p_limit\":50,\"p_scope\":\"rated\"}" \
  "$smoke_tmp/partial-album-state-cursor.json")"
[[ "$partial_album_state_cursor_status" == "400" ]]
invalid_album_state_scope_status="$(rpc_status "$collaborator_token" list_my_album_subject_states \
  '{"p_before_updated_at":null,"p_before_canonical_album_id":null,"p_limit":50,"p_scope":"reviews"}' \
  "$smoke_tmp/invalid-album-state-scope.json")"
[[ "$invalid_album_state_scope_status" == "400" ]]

stage="canonical album visible-review aggregates"
rpc "$collaborator_token" create_music_review \
  "{\"p_subject_kind\":\"album\",\"p_canonical_album_id\":\"$album_canonical_id\",\"p_rating\":2.0,\"p_body\":\"A newer album rating.\",\"p_visibility\":\"followers\",\"p_is_loved\":false}" \
  "$smoke_tmp/newer-album-review.json"
newer_album_review_id="$(jq -er 'if type == "array" then .[0].id else .id end' "$smoke_tmp/newer-album-review.json")"
rpc "$conductor_token" get_canonical_album_state_aggregate \
  "{\"p_canonical_album_id\":\"$album_canonical_id\"}" \
  "$smoke_tmp/album-state-aggregate.json"
jq -e --arg album "$album_canonical_id" 'length == 1 and .[0].canonical_album_id == $album and .[0].rating_count == 1 and .[0].average_rating == 2.00 and .[0].listened_count == 1 and .[0].loved_count == 0 and .[0].want_to_listen_count == 0' "$smoke_tmp/album-state-aggregate.json" >/dev/null
rpc "$conductor_token" list_canonical_album_rating_distribution \
  "{\"p_canonical_album_id\":\"$album_canonical_id\"}" \
  "$smoke_tmp/album-rating-distribution.json"
jq -e 'length == 10 and (map(.rating_count) | add) == 1 and any(.[]; .rating == 2.0 and .rating_count == 1) and all(.[]; .rating == 2.0 or .rating_count == 0)' "$smoke_tmp/album-rating-distribution.json" >/dev/null
rpc "$collaborator_token" delete_music_review \
  "{\"p_review_id\":\"$newer_album_review_id\"}" \
  "$smoke_tmp/deleted-newer-album-review.json"
rest_get "$collaborator_token" \
  "profile_album_subject_states?select=has_listened,default_rating,is_loved,want_to_listen&canonical_album_id=eq.$album_canonical_id" \
  "$smoke_tmp/state-after-newer-album-review-delete.json"
jq -e 'length == 1 and .[0].has_listened == true and .[0].default_rating == 2.0 and .[0].is_loved == false and .[0].want_to_listen == false' "$smoke_tmp/state-after-newer-album-review-delete.json" >/dev/null
rpc "$conductor_token" get_canonical_album_state_aggregate \
  "{\"p_canonical_album_id\":\"$album_canonical_id\"}" \
  "$smoke_tmp/album-state-aggregate-after-newest-delete.json"
jq -e 'length == 1 and .[0].rating_count == 1 and .[0].average_rating == 3.50 and .[0].loved_count == 1' "$smoke_tmp/album-state-aggregate-after-newest-delete.json" >/dev/null

stage="album state empty-row normalization"
rpc "$collaborator_token" set_my_album_subject_state \
  "{\"p_canonical_album_id\":\"$canonical_only_album_id\",\"p_has_listened\":false,\"p_default_rating\":null,\"p_is_loved\":false,\"p_want_to_listen\":false}" \
  "$smoke_tmp/cleared-album-state.json"
jq -e '(if type == "array" then .[0] else . end) | .has_listened == false and .default_rating == null and .is_loved == false and .want_to_listen == false' "$smoke_tmp/cleared-album-state.json" >/dev/null
rest_get "$collaborator_token" \
  "profile_album_subject_states?select=canonical_album_id&canonical_album_id=eq.$canonical_only_album_id" \
  "$smoke_tmp/removed-empty-album-state.json"
[[ "$(jq 'length' "$smoke_tmp/removed-empty-album-state.json")" -eq 0 ]]

album_diary_link_status="$(rpc_status "$collaborator_token" update_listening_diary_entry_with_rating \
  "{\"p_entry_id\":\"$history_entry_id\",\"p_played_at\":\"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\",\"p_visibility\":\"followers\",\"p_is_relisten\":true,\"p_tags\":[\"atomic\",\"night\"],\"p_review_id\":\"$album_review_id\",\"p_rating\":2.5}" \
  "$smoke_tmp/album-diary-link.json")"
[[ "$album_diary_link_status" == "400" ]]

stage="visible profile shelves keyset and privacy"
rpc "$collaborator_token" set_my_track_subject_state \
  "{\"p_canonical_track_id\":\"$spotify_url_track_id\",\"p_has_listened\":false,\"p_default_rating\":null,\"p_is_loved\":true,\"p_want_to_listen\":true}" \
  "$smoke_tmp/loved-want-to-listen-state.json"
rpc "$conductor_token" list_profile_loved_tracks \
  "{\"p_profile_id\":\"$collaborator_id\",\"p_before_updated_at\":null,\"p_before_canonical_track_id\":null,\"p_limit\":50}" \
  "$smoke_tmp/private-loved-shelf.json"
[[ "$(jq 'length' "$smoke_tmp/private-loved-shelf.json")" -eq 0 ]]
rpc "$collaborator_token" list_profile_loved_tracks \
  "{\"p_profile_id\":\"$collaborator_id\",\"p_before_updated_at\":null,\"p_before_canonical_track_id\":null,\"p_limit\":50}" \
  "$smoke_tmp/owner-loved-shelf.json"
jq -e 'length == 2' "$smoke_tmp/owner-loved-shelf.json" >/dev/null
rest_patch "$collaborator_token" \
  "profile_social_settings?profile_id=eq.$collaborator_id" \
  '{"shelf_visibility":"followers"}' \
  "$smoke_tmp/follower-visible-shelf-setting.json"
jq -e 'length == 1 and .[0].shelf_visibility == "followers"' "$smoke_tmp/follower-visible-shelf-setting.json" >/dev/null
rpc "$conductor_token" list_profile_loved_tracks \
  "{\"p_profile_id\":\"$collaborator_id\",\"p_before_updated_at\":null,\"p_before_canonical_track_id\":null,\"p_limit\":1}" \
  "$smoke_tmp/loved-shelf-first-page.json"
loved_first_track_id="$(jq -er '.[0].canonical_track_id' "$smoke_tmp/loved-shelf-first-page.json")"
loved_first_updated_at="$(jq -er '.[0].updated_at' "$smoke_tmp/loved-shelf-first-page.json")"
rpc "$conductor_token" list_profile_loved_tracks \
  "{\"p_profile_id\":\"$collaborator_id\",\"p_before_updated_at\":\"$loved_first_updated_at\",\"p_before_canonical_track_id\":\"$loved_first_track_id\",\"p_limit\":10}" \
  "$smoke_tmp/loved-shelf-second-page.json"
jq -e --arg first "$loved_first_track_id" 'length == 1 and .[0].canonical_track_id != $first' "$smoke_tmp/loved-shelf-second-page.json" >/dev/null
rpc "$collaborator_token" create_music_review \
  "{\"p_subject_kind\":\"track\",\"p_canonical_track_id\":\"$spotify_url_track_id\",\"p_rating\":3.0,\"p_body\":\"Private blocker review.\",\"p_visibility\":\"private\",\"p_is_loved\":false}" \
  "$smoke_tmp/private-blocker-review.json"
private_blocker_review_id="$(jq -er 'if type == "array" then .[0].id else .id end' "$smoke_tmp/private-blocker-review.json")"
clear_listened_with_review_status="$(rpc_status "$collaborator_token" set_my_track_subject_state \
  "{\"p_canonical_track_id\":\"$spotify_url_track_id\",\"p_has_listened\":false,\"p_default_rating\":null,\"p_is_loved\":false,\"p_want_to_listen\":false}" \
  "$smoke_tmp/clear-listened-with-review.json")"
[[ "$clear_listened_with_review_status" == "400" ]]
rest_get "$collaborator_token" \
  "profile_track_subject_states?select=has_listened,default_rating,is_loved,want_to_listen&canonical_track_id=eq.$spotify_url_track_id" \
  "$smoke_tmp/rejected-clear-preserved-state.json"
jq -e 'length == 1 and .[0].has_listened == true and .[0].default_rating == 3.0 and .[0].is_loved == false and .[0].want_to_listen == false' "$smoke_tmp/rejected-clear-preserved-state.json" >/dev/null
rpc "$collaborator_token" delete_music_review \
  "{\"p_review_id\":\"$private_blocker_review_id\"}" \
  "$smoke_tmp/deleted-private-blocker-review.json"
rpc "$collaborator_token" set_my_track_subject_state \
  "{\"p_canonical_track_id\":\"$spotify_url_track_id\",\"p_has_listened\":false,\"p_default_rating\":null,\"p_is_loved\":false,\"p_want_to_listen\":false}" \
  "$smoke_tmp/empty-track-subject-state.json"
jq -e '(if type == "array" then .[0] else . end) | .has_listened == false and .default_rating == null and .is_loved == false and .want_to_listen == false' "$smoke_tmp/empty-track-subject-state.json" >/dev/null
rest_get "$collaborator_token" \
  "profile_track_subject_states?select=canonical_track_id&canonical_track_id=eq.$spotify_url_track_id" \
  "$smoke_tmp/removed-empty-track-subject-state.json"
[[ "$(jq 'length' "$smoke_tmp/removed-empty-track-subject-state.json")" -eq 0 ]]
rpc "$conductor_token" list_profile_listening_diary \
  "{\"p_profile_id\":\"$collaborator_id\",\"p_before_played_at\":null,\"p_before_id\":null,\"p_limit\":1}" \
  "$smoke_tmp/profile-diary-first-page.json"
profile_diary_first_id="$(jq -er '.[0].id' "$smoke_tmp/profile-diary-first-page.json")"
profile_diary_first_played_at="$(jq -er '.[0].played_at' "$smoke_tmp/profile-diary-first-page.json")"
rpc "$conductor_token" list_profile_listening_diary \
  "{\"p_profile_id\":\"$collaborator_id\",\"p_before_played_at\":\"$profile_diary_first_played_at\",\"p_before_id\":\"$profile_diary_first_id\",\"p_limit\":10}" \
  "$smoke_tmp/profile-diary-second-page.json"
jq -e --arg first "$profile_diary_first_id" 'length == 1 and .[0].id != $first and .[0].source == "manual"' "$smoke_tmp/profile-diary-second-page.json" >/dev/null
rpc "$conductor_token" list_profile_music_reviews \
  "{\"p_profile_id\":\"$collaborator_id\",\"p_before_created_at\":null,\"p_before_id\":null,\"p_limit\":1}" \
  "$smoke_tmp/profile-review-first-page.json"
profile_review_first_id="$(jq -er '.[0].id' "$smoke_tmp/profile-review-first-page.json")"
profile_review_first_created_at="$(jq -er '.[0].created_at' "$smoke_tmp/profile-review-first-page.json")"
[[ "$profile_review_first_id" == "$album_review_id" ]]
rpc "$conductor_token" list_profile_music_reviews \
  "{\"p_profile_id\":\"$collaborator_id\",\"p_before_created_at\":\"$profile_review_first_created_at\",\"p_before_id\":\"$profile_review_first_id\",\"p_limit\":10}" \
  "$smoke_tmp/profile-review-second-page.json"
jq -e --arg review "$review_id" 'length == 1 and .[0].id == $review' "$smoke_tmp/profile-review-second-page.json" >/dev/null

stage="owner review library pagination and exhaustive stats"
rpc "$collaborator_token" list_my_music_reviews \
  '{"p_before_created_at":null,"p_before_id":null,"p_limit":1}' \
  "$smoke_tmp/owner-review-first-page.json"
owner_review_first_id="$(jq -er '.[0].id' "$smoke_tmp/owner-review-first-page.json")"
owner_review_first_created_at="$(jq -er '.[0].created_at' "$smoke_tmp/owner-review-first-page.json")"
[[ "$owner_review_first_id" == "$album_review_id" ]]
rpc "$collaborator_token" list_my_music_reviews \
  "{\"p_before_created_at\":\"$owner_review_first_created_at\",\"p_before_id\":\"$owner_review_first_id\",\"p_limit\":10}" \
  "$smoke_tmp/owner-review-second-page.json"
jq -e --arg first "$owner_review_first_id" --arg review "$review_id" 'length == 1 and .[0].id == $review and .[0].id != $first' "$smoke_tmp/owner-review-second-page.json" >/dev/null
rpc "$conductor_token" list_my_music_reviews \
  '{"p_before_created_at":null,"p_before_id":null,"p_limit":50}' \
  "$smoke_tmp/foreign-owner-review-page.json"
[[ "$(jq 'length' "$smoke_tmp/foreign-owner-review-page.json")" -eq 0 ]]
partial_owner_review_cursor_status="$(rpc_status "$collaborator_token" list_my_music_reviews \
  "{\"p_before_created_at\":\"$owner_review_first_created_at\",\"p_before_id\":null,\"p_limit\":50}" \
  "$smoke_tmp/partial-owner-review-cursor.json")"
[[ "$partial_owner_review_cursor_status" == "400" ]]
oversized_owner_review_page_status="$(rpc_status "$collaborator_token" list_my_music_reviews \
  '{"p_before_created_at":null,"p_before_id":null,"p_limit":101}' \
  "$smoke_tmp/oversized-owner-review-page.json")"
[[ "$oversized_owner_review_page_status" == "400" ]]
rpc "$collaborator_token" get_my_music_review_stats '{}' "$smoke_tmp/owner-review-stats.json"
jq -e 'length == 1 and .[0].review_count == 2 and .[0].song_count == 1 and .[0].album_count == 1 and .[0].loved_count == 2 and .[0].average_rating == 4.0' "$smoke_tmp/owner-review-stats.json" >/dev/null
rpc "$conductor_token" get_my_music_review_stats '{}' "$smoke_tmp/empty-owner-review-stats.json"
jq -e 'length == 1 and .[0].review_count == 0 and .[0].song_count == 0 and .[0].album_count == 0 and .[0].loved_count == 0 and .[0].average_rating == null' "$smoke_tmp/empty-owner-review-stats.json" >/dev/null

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
  "{\"p_review_id\":\"$review_id\",\"p_rating\":5.0,\"p_body\":\"Updated Harmony smoke review.\",\"p_visibility\":\"followers\",\"p_contains_spoilers\":false,\"p_is_loved\":false}" \
  "$smoke_tmp/review-update.json"
rest_get "$conductor_token" \
  "music_reviews?select=id,rating,contains_spoilers,is_loved,body&id=eq.$review_id" \
  "$smoke_tmp/updated-review.json"
jq -e 'length == 1 and .[0].rating == 5.0 and .[0].contains_spoilers == false and .[0].is_loved == false and .[0].body == "Updated Harmony smoke review."' "$smoke_tmp/updated-review.json" >/dev/null
rest_get "$collaborator_token" \
  "profile_track_subject_states?select=default_rating,is_loved&canonical_track_id=eq.$canonical_track_id" \
  "$smoke_tmp/review-synchronized-track-state.json"
jq -e 'length == 1 and .[0].default_rating == 5.0 and .[0].is_loved == false' "$smoke_tmp/review-synchronized-track-state.json" >/dev/null
rest_get "$collaborator_token" \
  "listening_history_entries?select=rating&id=eq.$history_entry_id" \
  "$smoke_tmp/review-independent-diary-rating.json"
jq -e 'length == 1 and .[0].rating == 2.5' "$smoke_tmp/review-independent-diary-rating.json" >/dev/null
# The review owner may moderate another member's comment.
rpc "$collaborator_token" delete_review_comment \
  "{\"p_comment_id\":\"$comment_id\"}" \
  "$smoke_tmp/comment-delete.json"
[[ "$(jq -er '.' "$smoke_tmp/comment-delete.json")" == "true" ]]
rest_get "$conductor_token" \
  "review_comments?select=id&id=eq.$comment_id" \
  "$smoke_tmp/deleted-comment.json"
[[ "$(jq 'length' "$smoke_tmp/deleted-comment.json")" -eq 0 ]]
repeat_comment_delete_status="$(rpc_status "$collaborator_token" delete_review_comment \
  "{\"p_comment_id\":\"$comment_id\"}" \
  "$smoke_tmp/repeat-comment-delete.json")"
[[ "$repeat_comment_delete_status" == "200" ]]
[[ "$(jq -er '.' "$smoke_tmp/repeat-comment-delete.json")" == "false" ]]
rpc "$conductor_token" add_review_comment \
  "{\"p_review_id\":\"$review_id\",\"p_body\":\"I can remove my own follow-up.\"}" \
  "$smoke_tmp/author-owned-review-comment.json"
author_owned_comment_id="$(jq -er 'if type == "array" then .[0].id else .id end' "$smoke_tmp/author-owned-review-comment.json")"
direct_review_comment_write_status="$(rest_patch_status "$collaborator_token" \
  "review_comments?id=eq.$author_owned_comment_id" \
  '{"body":"Direct moderation must remain forbidden."}' \
  "$smoke_tmp/direct-review-comment-write.json")"
[[ "$direct_review_comment_write_status" == "403" ]]
rpc "$conductor_token" delete_review_comment \
  "{\"p_comment_id\":\"$author_owned_comment_id\"}" \
  "$smoke_tmp/author-comment-delete.json"
[[ "$(jq -er '.' "$smoke_tmp/author-comment-delete.json")" == "true" ]]

stage="atomic private music lists"
rest_get "$collaborator_token" \
  "queue_items?select=id&session_id=eq.$session_id" \
  "$smoke_tmp/list-queue-before.json"
list_queue_before="$(jq 'length' "$smoke_tmp/list-queue-before.json")"
rest_get "$collaborator_token" \
  "listening_history_entries?select=id&canonical_track_id=eq.$spotify_url_track_id" \
  "$smoke_tmp/list-history-before.json"
list_history_before="$(jq 'length' "$smoke_tmp/list-history-before.json")"
rest_get "$collaborator_token" \
  "profile_track_subject_states?select=canonical_track_id&canonical_track_id=eq.$spotify_url_track_id" \
  "$smoke_tmp/list-state-before.json"
list_state_before="$(jq 'length' "$smoke_tmp/list-state-before.json")"

direct_list_insert_status="$(curl --silent --show-error \
  -X POST "$supabase_url/rest/v1/music_lists" \
  -H "apikey: $publishable_key" \
  -H "Authorization: Bearer $collaborator_token" \
  -H "Content-Type: application/json" \
  --data "{\"owner_id\":\"$collaborator_id\",\"title\":\"Bypass\"}" \
  -o "$smoke_tmp/direct-list-insert.json" \
  -w '%{http_code}')"
[[ "$direct_list_insert_status" == "401" || "$direct_list_insert_status" == "403" ]]

list_entries_json="$(jq -nc \
  --arg first "$spotify_url_track_id" \
  --arg second "$canonical_track_id" \
  '[
    {canonical_track_id:$first,note:"Opener"},
    {canonical_track_id:$second,note:"Closer"}
  ]')"
save_list_body="$(jq -nc \
  --arg title 'Harmony smoke sequence' \
  --arg description 'An atomic ordered list.' \
  --argjson tags '["party","night"]' \
  --argjson entries "$list_entries_json" \
  '{p_list_id:null,p_title:$title,p_description:$description,p_tags:$tags,p_is_ranked:true,p_visibility:"private",p_entries:$entries,p_expected_revision:null}')"
rpc "$collaborator_token" save_music_list "$save_list_body" "$smoke_tmp/music-list-create.json"
music_list_id="$(jq -er 'if type == "array" then .[0].id else .id end' "$smoke_tmp/music-list-create.json")"
music_list_revision="$(jq -er 'if type == "array" then .[0].entries_revision else .entries_revision end' "$smoke_tmp/music-list-create.json")"

rest_get "$conductor_token" \
  "music_lists?select=id&id=eq.$music_list_id" \
  "$smoke_tmp/private-list-follower.json"
[[ "$(jq 'length' "$smoke_tmp/private-list-follower.json")" -eq 0 ]]
private_entries_status="$(rpc_status "$conductor_token" list_music_list_entries \
  "{\"p_list_id\":\"$music_list_id\",\"p_after_position\":null,\"p_limit\":100}" \
  "$smoke_tmp/private-list-entries-follower.json")"
[[ "$private_entries_status" == "400" || "$private_entries_status" == "403" || "$private_entries_status" == "404" ]]
rpc "$collaborator_token" list_music_list_entries \
  "{\"p_list_id\":\"$music_list_id\",\"p_after_position\":null,\"p_limit\":100}" \
  "$smoke_tmp/private-list-entries-owner.json"
jq -e --arg first "$spotify_url_track_id" --arg second "$canonical_track_id" \
  'length == 2 and .[0].position == 1 and .[0].canonical_track_id == $first and .[1].position == 2 and .[1].canonical_track_id == $second' \
  "$smoke_tmp/private-list-entries-owner.json" >/dev/null

duplicate_draft_status="$(rpc_status "$collaborator_token" save_music_list \
  "$(jq -nc --arg track "$spotify_url_track_id" '{p_list_id:null,p_title:"Duplicate draft",p_description:"",p_tags:[],p_is_ranked:false,p_visibility:"private",p_entries:[{canonical_track_id:$track,note:""},{canonical_track_id:$track,note:"again"}],p_expected_revision:null}')" \
  "$smoke_tmp/duplicate-list-draft.json")"
[[ "$duplicate_draft_status" == "400" || "$duplicate_draft_status" == "404" ]]
rest_get "$collaborator_token" \
  "music_lists?select=id&owner_id=eq.$collaborator_id&deleted_at=is.null" \
  "$smoke_tmp/owner-lists-after-rejected-draft.json"
[[ "$(jq 'length' "$smoke_tmp/owner-lists-after-rejected-draft.json")" -eq 1 ]]

rest_get "$collaborator_token" \
  "queue_items?select=id&session_id=eq.$session_id" \
  "$smoke_tmp/list-queue-after.json"
[[ "$(jq 'length' "$smoke_tmp/list-queue-after.json")" -eq "$list_queue_before" ]]
rest_get "$collaborator_token" \
  "listening_history_entries?select=id&canonical_track_id=eq.$spotify_url_track_id" \
  "$smoke_tmp/list-history-after.json"
[[ "$(jq 'length' "$smoke_tmp/list-history-after.json")" -eq "$list_history_before" ]]
rest_get "$collaborator_token" \
  "profile_track_subject_states?select=canonical_track_id&canonical_track_id=eq.$spotify_url_track_id" \
  "$smoke_tmp/list-state-after.json"
[[ "$(jq 'length' "$smoke_tmp/list-state-after.json")" -eq "$list_state_before" ]]

stage="music list publication ordering and revision conflicts"
reversed_entries_json="$(jq -nc \
  --arg first "$canonical_track_id" \
  --arg second "$spotify_url_track_id" \
  '[
    {canonical_track_id:$first,note:"Now first"},
    {canonical_track_id:$second,note:"Now second"}
  ]')"
publish_list_body="$(jq -nc \
  --arg list "$music_list_id" \
  --argjson revision "$music_list_revision" \
  --argjson entries "$reversed_entries_json" \
  '{p_list_id:$list,p_title:"Harmony smoke sequence",p_description:"Published atomically.",p_tags:["night","party"],p_is_ranked:true,p_visibility:"followers",p_entries:$entries,p_expected_revision:$revision}')"
rpc "$collaborator_token" save_music_list "$publish_list_body" "$smoke_tmp/music-list-publish.json"
published_list_revision="$(jq -er 'if type == "array" then .[0].entries_revision else .entries_revision end' "$smoke_tmp/music-list-publish.json")"
[[ "$published_list_revision" -gt "$music_list_revision" ]]
rpc "$conductor_token" list_profile_music_lists \
  "{\"p_profile_id\":\"$collaborator_id\",\"p_before_updated_at\":null,\"p_before_id\":null,\"p_limit\":50}" \
  "$smoke_tmp/follower-music-lists.json"
jq -e --arg list "$music_list_id" 'length == 1 and .[0].id == $list and .[0].visibility == "followers"' \
  "$smoke_tmp/follower-music-lists.json" >/dev/null
rest_get "$conductor_token" \
  "music_lists?select=id,owner:profiles!music_lists_owner_id_fkey(display_name)&id=eq.$music_list_id" \
  "$smoke_tmp/follower-music-list-client-shape.json"
jq -e --arg list "$music_list_id" 'length == 1 and .[0].id == $list and (.[] | .owner.display_name | length) > 0' \
  "$smoke_tmp/follower-music-list-client-shape.json" >/dev/null
rpc "$conductor_token" list_music_list_entries \
  "{\"p_list_id\":\"$music_list_id\",\"p_after_position\":null,\"p_limit\":100}" \
  "$smoke_tmp/follower-list-entries.json"
jq -e --arg first "$canonical_track_id" --arg second "$spotify_url_track_id" \
  'length == 2 and .[0].canonical_track_id == $first and .[1].canonical_track_id == $second' \
  "$smoke_tmp/follower-list-entries.json" >/dev/null

stale_list_save_status="$(rpc_status "$collaborator_token" save_music_list \
  "$publish_list_body" "$smoke_tmp/stale-list-save.json")"
[[ "$stale_list_save_status" == "400" || "$stale_list_save_status" == "409" ]]
jq -e '.details == "music_list_revision_conflict" or .detail == "music_list_revision_conflict" or (.message | contains("refresh"))' \
  "$smoke_tmp/stale-list-save.json" >/dev/null

rpc "$collaborator_token" add_music_list_entry \
  "{\"p_list_id\":\"$music_list_id\",\"p_canonical_track_id\":\"$cross_isrc_track_id\",\"p_note\":\"Encore\",\"p_expected_revision\":$published_list_revision}" \
  "$smoke_tmp/list-entry-add.json"
added_list_revision="$(jq -er '.entries_revision' "$smoke_tmp/list-entry-add.json")"
list_third_entry_id="$(jq -er '.entry.id' "$smoke_tmp/list-entry-add.json")"
duplicate_list_entry_status="$(rpc_status "$collaborator_token" add_music_list_entry \
  "{\"p_list_id\":\"$music_list_id\",\"p_canonical_track_id\":\"$cross_isrc_track_id\",\"p_note\":\"Duplicate\",\"p_expected_revision\":$added_list_revision}" \
  "$smoke_tmp/duplicate-list-entry.json")"
[[ "$duplicate_list_entry_status" == "400" || "$duplicate_list_entry_status" == "409" ]]

rpc "$collaborator_token" list_music_list_entries \
  "{\"p_list_id\":\"$music_list_id\",\"p_after_position\":null,\"p_limit\":100}" \
  "$smoke_tmp/list-before-reorder.json"
list_first_entry_id="$(jq -er '.[0].id' "$smoke_tmp/list-before-reorder.json")"
list_second_entry_id="$(jq -er '.[1].id' "$smoke_tmp/list-before-reorder.json")"
rpc "$collaborator_token" reorder_music_list_entries \
  "{\"p_list_id\":\"$music_list_id\",\"p_ordered_entry_ids\":[\"$list_third_entry_id\",\"$list_first_entry_id\",\"$list_second_entry_id\"],\"p_expected_revision\":$added_list_revision}" \
  "$smoke_tmp/list-reorder.json"
reordered_list_revision="$(jq -er '.' "$smoke_tmp/list-reorder.json")"
invalid_reorder_status="$(rpc_status "$collaborator_token" reorder_music_list_entries \
  "{\"p_list_id\":\"$music_list_id\",\"p_ordered_entry_ids\":[\"$list_third_entry_id\",\"$list_third_entry_id\",\"$list_second_entry_id\"],\"p_expected_revision\":$reordered_list_revision}" \
  "$smoke_tmp/list-invalid-reorder.json")"
[[ "$invalid_reorder_status" == "400" ]]
rpc "$collaborator_token" list_music_list_entries \
  "{\"p_list_id\":\"$music_list_id\",\"p_after_position\":null,\"p_limit\":100}" \
  "$smoke_tmp/list-after-reorder.json"
jq -e --arg third "$list_third_entry_id" --arg first "$list_first_entry_id" --arg second "$list_second_entry_id" \
  'map(.id) == [$third,$first,$second] and map(.position) == [1,2,3]' \
  "$smoke_tmp/list-after-reorder.json" >/dev/null

stage="music list engagement activity and block privacy"
rpc "$conductor_token" set_music_list_liked \
  "{\"p_list_id\":\"$music_list_id\",\"p_is_liked\":true}" \
  "$smoke_tmp/list-liked.json"
rpc "$conductor_token" set_music_list_liked \
  "{\"p_list_id\":\"$music_list_id\",\"p_is_liked\":true}" \
  "$smoke_tmp/list-liked-repeat.json"
[[ "$(jq -er '.' "$smoke_tmp/list-liked.json")" == "true" ]]
rpc "$conductor_token" add_music_list_comment \
  "{\"p_list_id\":\"$music_list_id\",\"p_body\":\"Great sequence.\"}" \
  "$smoke_tmp/list-comment.json"
music_list_comment_id="$(jq -er 'if type == "array" then .[0].id else .id end' "$smoke_tmp/list-comment.json")"
rest_get "$collaborator_token" \
  "social_notifications?select=kind,actor_id,music_list_id,music_list_comment_id&actor_id=eq.$conductor_id&music_list_id=eq.$music_list_id&order=created_at.asc" \
  "$smoke_tmp/list-notifications.json"
jq -e 'length == 2 and ([.[].kind] | sort) == ["music_list_comment","music_list_like"]' \
  "$smoke_tmp/list-notifications.json" >/dev/null
rest_get "$collaborator_token" \
  "social_notifications?select=id,kind,actor:profiles!social_notifications_actor_id_fkey(display_name),review:music_reviews!social_notifications_review_id_fkey(subject_title),music_list:music_lists!social_notifications_music_list_id_fkey(title)&actor_id=eq.$conductor_id&music_list_id=eq.$music_list_id" \
  "$smoke_tmp/list-notifications-client-shape.json"
jq -e 'length == 2 and all(.[]; .actor.display_name | length > 0) and all(.[]; .music_list.title == "Harmony smoke sequence")' \
  "$smoke_tmp/list-notifications-client-shape.json" >/dev/null
rest_get "$collaborator_token" \
  "social_activity_events?select=id,kind,list_id&list_id=eq.$music_list_id" \
  "$smoke_tmp/list-activity.json"
jq -e 'length == 1 and .[0].kind == "list_published"' "$smoke_tmp/list-activity.json" >/dev/null
rpc "$collaborator_token" update_music_list \
  "{\"p_list_id\":\"$music_list_id\",\"p_title\":\"Harmony smoke sequence updated\",\"p_description\":\"No duplicate activity.\",\"p_tags\":[\"night\"],\"p_is_ranked\":false,\"p_visibility\":\"followers\"}" \
  "$smoke_tmp/list-metadata-update.json"
rest_get "$collaborator_token" \
  "social_activity_events?select=id&list_id=eq.$music_list_id" \
  "$smoke_tmp/list-activity-after-edit.json"
[[ "$(jq 'length' "$smoke_tmp/list-activity-after-edit.json")" -eq 1 ]]
rpc "$collaborator_token" delete_music_list_comment \
  "{\"p_comment_id\":\"$music_list_comment_id\"}" \
  "$smoke_tmp/list-comment-delete.json"
[[ "$(jq -er '.' "$smoke_tmp/list-comment-delete.json")" == "true" ]]

stage="atomic review and optional Diary authoring"
atomic_played_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
rpc "$collaborator_token" create_track_review_with_optional_diary \
  "{\"p_canonical_track_id\":\"$cross_isrc_track_id\",\"p_provider\":\"apple_music\",\"p_provider_subject_id\":\"harmony-cross-isrc-apple\",\"p_rating\":4.5,\"p_body\":\"One action, two independent Harmony records.\",\"p_review_visibility\":\"followers\",\"p_contains_spoilers\":false,\"p_is_loved\":true,\"p_diary_played_at\":\"$atomic_played_at\",\"p_diary_visibility\":\"private\",\"p_is_relisten\":true,\"p_tags\":[\" Road Trip \",\"road trip\",\"NIGHT\"],\"p_diary_rating\":2.0}" \
  "$smoke_tmp/atomic-review-diary.json"
atomic_review_id="$(jq -er 'if type == "array" then .[0].review_id else .review_id end' "$smoke_tmp/atomic-review-diary.json")"
atomic_diary_id="$(jq -er 'if type == "array" then .[0].diary_entry_id else .diary_entry_id end' "$smoke_tmp/atomic-review-diary.json")"
rest_get "$collaborator_token" \
  "music_reviews?select=id,rating,is_loved,visibility,canonical_track_id&id=eq.$atomic_review_id" \
  "$smoke_tmp/atomic-review.json"
jq -e --arg track "$cross_isrc_track_id" \
  'length == 1 and .[0].canonical_track_id == $track and .[0].rating == 4.5 and .[0].is_loved == true and .[0].visibility == "followers"' \
  "$smoke_tmp/atomic-review.json" >/dev/null
rest_get "$collaborator_token" \
  "listening_history_entries?select=id,rating,visibility,is_relisten,tags,review_id,source,canonical_track_id,played_at&id=eq.$atomic_diary_id" \
  "$smoke_tmp/atomic-diary.json"
jq -e --arg review "$atomic_review_id" --arg track "$cross_isrc_track_id" \
  'length == 1 and .[0].canonical_track_id == $track and .[0].review_id == $review and .[0].rating == 2.0 and .[0].visibility == "private" and .[0].is_relisten == true and .[0].source == "manual" and .[0].tags == ["road trip","night"]' \
  "$smoke_tmp/atomic-diary.json" >/dev/null
atomic_persisted_played_at="$(jq -er '.[0].played_at' "$smoke_tmp/atomic-diary.json")"
rest_get "$collaborator_token" \
  "profile_track_subject_states?select=default_rating,is_loved,has_listened&canonical_track_id=eq.$cross_isrc_track_id" \
  "$smoke_tmp/atomic-current-state.json"
jq -e 'length == 1 and .[0].default_rating == 4.5 and .[0].is_loved == true and .[0].has_listened == true' \
  "$smoke_tmp/atomic-current-state.json" >/dev/null

stage="atomic review and Diary validation"
no_diary_metadata_status="$(rpc_status "$collaborator_token" create_track_review_with_optional_diary \
  "{\"p_canonical_track_id\":\"$cross_isrc_track_id\",\"p_rating\":3.0,\"p_body\":\"Invalid metadata.\",\"p_diary_played_at\":null,\"p_is_relisten\":true}" \
  "$smoke_tmp/atomic-no-diary-metadata.json")"
[[ "$no_diary_metadata_status" == "400" ]]
provider_mismatch_status="$(rpc_status "$collaborator_token" create_track_review_with_optional_diary \
  "{\"p_canonical_track_id\":\"$cross_isrc_track_id\",\"p_provider\":\"apple_music\",\"p_provider_subject_id\":\"harmony-smoke-apple-track\",\"p_rating\":3.0,\"p_body\":\"Invalid provider mapping.\"}" \
  "$smoke_tmp/atomic-provider-mismatch.json")"
[[ "$provider_mismatch_status" == "400" ]]

stage="atomic review and Diary rollback"
variant_studio_track_id="$(jq -er '.' "$smoke_tmp/variant-studio.json")"
late_review_failure_status="$(rpc_status "$collaborator_token" create_track_review_with_optional_diary \
  "{\"p_canonical_track_id\":\"$variant_studio_track_id\",\"p_provider\":\"spotify\",\"p_provider_subject_id\":\"spotify:track:harmony-variant-studio\",\"p_rating\":4.2,\"p_body\":\"The review validation must roll back the Diary.\",\"p_review_visibility\":\"followers\",\"p_diary_played_at\":\"$atomic_played_at\",\"p_diary_visibility\":\"followers\",\"p_is_relisten\":false,\"p_tags\":[\"rollback\"],\"p_diary_rating\":2.5}" \
  "$smoke_tmp/atomic-late-failure.json")"
[[ "$late_review_failure_status" == "400" ]]
rest_get "$collaborator_token" \
  "music_reviews?select=id&profile_id=eq.$collaborator_id&canonical_track_id=eq.$variant_studio_track_id" \
  "$smoke_tmp/atomic-rollback-reviews.json"
rest_get "$collaborator_token" \
  "listening_history_entries?select=id&profile_id=eq.$collaborator_id&canonical_track_id=eq.$variant_studio_track_id" \
  "$smoke_tmp/atomic-rollback-diary.json"
rest_get "$collaborator_token" \
  "profile_track_subject_states?select=canonical_track_id&profile_id=eq.$collaborator_id&canonical_track_id=eq.$variant_studio_track_id" \
  "$smoke_tmp/atomic-rollback-state.json"
[[ "$(jq 'length' "$smoke_tmp/atomic-rollback-reviews.json")" -eq 0 ]]
[[ "$(jq 'length' "$smoke_tmp/atomic-rollback-diary.json")" -eq 0 ]]
[[ "$(jq 'length' "$smoke_tmp/atomic-rollback-state.json")" -eq 0 ]]

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
rest_get "$conductor_token" \
  "music_lists?select=id&id=eq.$music_list_id" \
  "$smoke_tmp/blocked-music-list.json"
[[ "$(jq 'length' "$smoke_tmp/blocked-music-list.json")" -eq 0 ]]
blocked_list_entries_status="$(rpc_status "$conductor_token" list_music_list_entries \
  "{\"p_list_id\":\"$music_list_id\",\"p_after_position\":null,\"p_limit\":100}" \
  "$smoke_tmp/blocked-music-list-entries.json")"
[[ "$blocked_list_entries_status" == "400" || "$blocked_list_entries_status" == "403" || "$blocked_list_entries_status" == "404" ]]
rpc "$conductor_token" list_following_activity \
  '{"p_before_published_at":null,"p_before_id":null,"p_limit":50}' \
  "$smoke_tmp/blocked-activity-page.json"
[[ "$(jq 'length' "$smoke_tmp/blocked-activity-page.json")" -eq 0 ]]
rpc "$conductor_token" list_profile_listening_diary \
  "{\"p_profile_id\":\"$collaborator_id\",\"p_before_played_at\":null,\"p_before_id\":null,\"p_limit\":50}" \
  "$smoke_tmp/blocked-profile-diary.json"
[[ "$(jq 'length' "$smoke_tmp/blocked-profile-diary.json")" -eq 0 ]]
rpc "$conductor_token" list_profile_music_reviews \
  "{\"p_profile_id\":\"$collaborator_id\",\"p_before_created_at\":null,\"p_before_id\":null,\"p_limit\":50}" \
  "$smoke_tmp/blocked-profile-reviews.json"
[[ "$(jq 'length' "$smoke_tmp/blocked-profile-reviews.json")" -eq 0 ]]
rpc "$conductor_token" list_profile_loved_tracks \
  "{\"p_profile_id\":\"$collaborator_id\",\"p_before_updated_at\":null,\"p_before_canonical_track_id\":null,\"p_limit\":50}" \
  "$smoke_tmp/blocked-profile-loved.json"
[[ "$(jq 'length' "$smoke_tmp/blocked-profile-loved.json")" -eq 0 ]]
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

stage="review soft-delete detaches linked Diary"
foreign_atomic_delete_status="$(rpc_status "$conductor_token" delete_music_review \
  "{\"p_review_id\":\"$atomic_review_id\"}" \
  "$smoke_tmp/atomic-review-foreign-delete.json")"
[[ "$foreign_atomic_delete_status" == "200" ]]
[[ "$(jq -er '.' "$smoke_tmp/atomic-review-foreign-delete.json")" == "false" ]]
rpc "$collaborator_token" delete_music_review \
  "{\"p_review_id\":\"$atomic_review_id\"}" \
  "$smoke_tmp/atomic-review-delete.json"
[[ "$(jq -er '.' "$smoke_tmp/atomic-review-delete.json")" == "true" ]]
rpc "$collaborator_token" delete_music_review \
  "{\"p_review_id\":\"$atomic_review_id\"}" \
  "$smoke_tmp/atomic-review-delete-repeat.json"
[[ "$(jq -er '.' "$smoke_tmp/atomic-review-delete-repeat.json")" == "false" ]]
rest_get "$collaborator_token" \
  "music_reviews?select=id&id=eq.$atomic_review_id" \
  "$smoke_tmp/atomic-review-after-delete.json"
[[ "$(jq 'length' "$smoke_tmp/atomic-review-after-delete.json")" -eq 0 ]]
rest_get "$collaborator_token" \
  "listening_history_entries?select=id,rating,visibility,is_relisten,tags,review_id,source,canonical_track_id,played_at&id=eq.$atomic_diary_id" \
  "$smoke_tmp/atomic-diary-after-review-delete.json"
jq -e --arg track "$cross_isrc_track_id" --arg played "$atomic_persisted_played_at" \
  'length == 1 and .[0].canonical_track_id == $track and .[0].review_id == null and .[0].rating == 2.0 and .[0].visibility == "private" and .[0].is_relisten == true and .[0].source == "manual" and .[0].tags == ["road trip","night"] and .[0].played_at == $played' \
  "$smoke_tmp/atomic-diary-after-review-delete.json" >/dev/null
rest_get "$collaborator_token" \
  "social_activity_events?select=id&review_id=eq.$atomic_review_id" \
  "$smoke_tmp/atomic-review-activity-after-delete.json"
[[ "$(jq 'length' "$smoke_tmp/atomic-review-activity-after-delete.json")" -eq 0 ]]

rpc "$collaborator_token" stop_listening_presence '{}' \
  "$smoke_tmp/stopped-eavesdrop.json"
rest_get "$collaborator_token" \
  "listening_broadcasts?select=id,ended_at&id=eq.$listening_broadcast_id" \
  "$smoke_tmp/stopped-eavesdrop-broadcast.json"
jq -e 'length == 1 and .[0].ended_at != null' "$smoke_tmp/stopped-eavesdrop-broadcast.json" >/dev/null
stopped_eavesdrop_comment_status="$(rpc_status "$conductor_token" add_listening_broadcast_comment \
  "{\"p_broadcast_id\":\"$listening_broadcast_id\",\"p_body\":\"Too late.\"}" \
  "$smoke_tmp/stopped-eavesdrop-comment.json")"
[[ "$stopped_eavesdrop_comment_status" == "400" || "$stopped_eavesdrop_comment_status" == "403" ]]
rpc "$collaborator_token" delete_music_list \
  "{\"p_list_id\":\"$music_list_id\"}" \
  "$smoke_tmp/music-list-delete.json"
[[ "$(jq -er '.' "$smoke_tmp/music-list-delete.json")" == "true" ]]
rest_get "$collaborator_token" \
  "music_lists?select=id&id=eq.$music_list_id" \
  "$smoke_tmp/deleted-music-list.json"
[[ "$(jq 'length' "$smoke_tmp/deleted-music-list.json")" -eq 0 ]]
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

stage="non-finite queue position rejection"
nan_move_status="$(rpc_status "$conductor_token" apply_queue_command \
  "{\"p_session_id\":\"$session_id\",\"p_command_id\":\"$(new_uuid)\",\"p_expected_revision\":2,\"p_type\":\"move\",\"p_payload\":{\"queue_item_id\":\"$collaborator_item_id\",\"position\":\"NaN\"}}" \
  "$smoke_tmp/nan-move.json")"
[[ "$nan_move_status" == "400" ]]
infinity_move_status="$(rpc_status "$conductor_token" apply_queue_command \
  "{\"p_session_id\":\"$session_id\",\"p_command_id\":\"$(new_uuid)\",\"p_expected_revision\":2,\"p_type\":\"move\",\"p_payload\":{\"queue_item_id\":\"$collaborator_item_id\",\"position\":\"Infinity\"}}" \
  "$smoke_tmp/infinity-move.json")"
[[ "$infinity_move_status" == "400" ]]

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
