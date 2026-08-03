# Harmony Supabase setup

This folder is a credential-free backend scaffold. It contains the schema, Row Level Security (RLS), indexes, profile trigger, and the queue command RPC. It does **not** contain a project URL, anon key, provider secret, or Apple developer token.

## Prerequisites

- A Supabase project with Email or Sign in with Apple authentication enabled.
- The [Supabase CLI](https://supabase.com/docs/guides/local-development/cli/getting-started) and Docker for local development, or access to the Supabase SQL Editor.

## Apply the schema

From the repository root:

```bash
supabase login
supabase link --project-ref YOUR_PROJECT_REF
supabase db push
```

For local development, start Supabase first with `supabase start`, then run `supabase db reset`. Alternatively, paste the migration into the hosted project’s SQL Editor once. Do not use `supabase db push` against production until you have reviewed the migration in source control.

## Required app configuration later

The iOS app will need only the Supabase project URL and publishable/anon key, supplied through an untracked `.xcconfig` file. Do not commit a service-role key. Spotify OAuth token exchange and refresh must run in an Edge Function; its client secret belongs in Supabase Function Secrets. Query `provider_connection_statuses`, never the token-bearing `provider_connections` table.

## Spotify token exchange function

`functions/spotify-token-exchange` is an authenticated PKCE exchange boundary. The app sends its authorization code and verifier to the function; it validates the Harmony user, exchanges the code with Spotify, AES-GCM encrypts the refresh token, and writes it with the Supabase secret key. It never returns a token to iOS.

`functions/spotify-access-token` is the companion App Remote boundary. It validates the Harmony user, decrypts only that user's refresh token, refreshes it with Spotify, and returns a short-lived access token with `Cache-Control: no-store`. Refresh tokens and the Spotify client secret remain server-side.

`functions/spotify-disconnect` authenticates the current Harmony user and deletes only that user's Spotify connection, including the encrypted refresh token. The client cannot delete provider-token rows directly.

`functions/spotify-search` refreshes the current user's Spotify access token server-side, searches Spotify's catalog, reuses an eligible canonical track by ISRC, and records exact Spotify-to-canonical mappings before returning provider-neutral track metadata to iOS. It preserves explicit-content and attribution metadata and never exposes the refresh token or client secret.

`functions/delete-account` validates the current user, removes their session and provider data through a service-role-only database function, then deletes their Supabase Auth user. The iOS client cannot invoke the cleanup RPC directly.

Before deployment, create a Spotify developer app and register the exact iOS redirect URI. Set `SPOTIFY_CLIENT_ID`, optionally `SPOTIFY_CLIENT_SECRET`, and a random 32-byte base64 `SPOTIFY_TOKEN_ENCRYPTION_KEY` as Supabase Function Secrets. The checked-in `functions/.env.example` is intentionally blank.

```bash
supabase secrets set --env-file supabase/functions/.env
supabase functions deploy spotify-token-exchange
```

## Session RPCs

`create_session(title, invite_code, playback_mode, allow_collaborator_invites, expires_at)` creates a room and makes the caller its Conductor. `join_session_by_invite(invite_code)` joins an active room as a Collaborator (and is idempotent). Generate invite codes client-side with six to eight uppercase letters/numbers, then show the unique-constraint error by generating a new code and retrying.

`end_harmony_session(session_id)` is Conductor-only and marks the room ended. `leave_harmony_session(session_id)` removes a Collaborator; Conductors must explicitly end their room instead.

## Social graph foundation

`profile_social_settings` starts with live listening, history, and reviews all set to `private`. A user may expose each category to approved followers independently. `request_social_follow(profile_id)` creates a follower request; the target accepts or rejects it with `respond_to_social_follow(requester_id, accept)`. `remove_social_follow(profile_id)` removes only the caller's outgoing edge, while `remove_social_follower(profile_id)` removes only an incoming edge. `block_social_profile(profile_id)` removes both edges and prevents a new request; `unblock_social_profile(profile_id)` restores the ability to request a relationship. These operations are dedicated security-definer RPCs, not direct client writes. The visibility helpers used by later listening activity and review tables deny access across blocks and require an accepted follower for follower-visible data.

`publish_listening_presence(...)` writes a single user-owned, short-lived eavesdrop card. It must expire within ten minutes and is hidden by RLS unless its owner allows the viewer. `stop_listening_presence()` removes it. `record_listening_history(...)` is the user-owned history path; `record_harmony_plays` is a separate default-off consent setting, and history visibility remains independently private or follower-visible. Harmony never imports a provider’s data without an explicit user choice.

`create_music_review(...)` creates a follower/private/public review of a canonical track or provider-addressed album. Owners can edit or soft-delete it through `update_music_review(...)` and `delete_music_review(...)`. Visible viewers can use `add_review_comment(...)` and `toggle_review_reaction(...)`; comment authors can soft-delete their own comments. RLS reevaluates the review’s visibility and blocks before granting access.

`resolve_harmony_track(provider, provider_id, title, artist, ...)` resolves a provider catalog item to a canonical Harmony track before queue insertion. It is idempotent by provider and provider ID, so provider-specific search clients can contribute tracks even before a cross-provider matcher has added mappings for the other services.

## Queue RPC contract

Authenticated clients call `apply_queue_command` with:

```text
p_session_id        UUID
p_command_id        client-generated UUID idempotency key
p_expected_revision last known session queue_revision
p_type              add | move | remove | play | pause | skip
p_payload           JSON object
```

Payloads:

| Command | Payload |
| --- | --- |
| `add` | `{ "canonical_track_id": "UUID" }` |
| `move` | `{ "queue_item_id": "UUID", "position": 1024.0 }` |
| `remove` | `{ "queue_item_id": "UUID" }` |
| `play`, `pause` | Playback intent JSON, e.g. `{ "status": "playing", "queue_item_id": "UUID", "started_at": "ISO-8601" }` |

The RPC returns `{ status: "applied", revision }` or `{ status: "conflict", revision }`. Retrying an applied command with the same command ID is safe. The server verifies membership and role, locks the session, updates the materialized state, increments its revision, and inserts its immutable event in one transaction.

`skip_queue_item(session_id, command_id, expected_revision)` is the Conductor-only companion command. It atomically removes the canonical queue head, advances the revision, records a `skip` event, and leaves provider playback as a device-side effect. Both it and playback commands are rejected for `queue_only` sessions.

## Live smoke test

Run the disposable-user smoke test against the configured project with:

```bash
./supabase/tests/live_smoke.sh
```

It exercises anonymous authentication, social follow/block enforcement, session creation/joining, provider-track canonicalization, member-role reads, Conductor-only invite-permission updates, collaborator add/remove ownership, queue-only playback rejection, Conductor-only reorder/playback/lifecycle enforcement, revision conflicts, command idempotency, session ending, and account cleanup. It reads the public project URL/key from the app plist and never prints access tokens.

## Important notes

- Direct client writes to sessions, members, queue items, and events are intentionally revoked. Creation, joining, ending, leaving, and queue mutations use dedicated RPCs; invitation-policy changes need a dedicated Conductor-only RPC before exposing that control.
- Collaboration read policies call `is_session_member(session_id)`, a boolean security-definer helper bound to the caller's JWT identity. This avoids recursive `session_members` RLS evaluation without exposing another profile's membership.
- `provider_connections.encrypted_refresh_token` is never intended for client reads. Use Edge Functions or a service-role worker to write encrypted Spotify refresh tokens.
- The schema publishes session, member, queue-item, and queue-event changes for Supabase Realtime. Use Broadcast for short-lived presence data; update `last_seen_at` through a small dedicated RPC when that feature is wired.
