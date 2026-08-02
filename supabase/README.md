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

## Session RPCs

`create_session(title, invite_code, playback_mode, allow_collaborator_invites, expires_at)` creates a room and makes the caller its Conductor. `join_session_by_invite(invite_code)` joins an active room as a Collaborator (and is idempotent). Generate invite codes client-side with six to eight uppercase letters/numbers, then show the unique-constraint error by generating a new code and retrying.

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
| `play`, `pause`, `skip` | Playback intent JSON, e.g. `{ "status": "playing", "queue_item_id": "UUID", "started_at": "ISO-8601" }` |

The RPC returns `{ status: "applied", revision }` or `{ status: "conflict", revision }`. Retrying an applied command with the same command ID is safe. The server verifies membership and role, locks the session, updates the materialized state, increments its revision, and inserts its immutable event in one transaction.

## Important notes

- Direct client writes to sessions, members, queue items, and events are intentionally revoked. Session creation and joining have dedicated RPCs; ending a session and invitation-policy changes should get dedicated Conductor-only RPCs before exposing those controls.
- `provider_connections.encrypted_refresh_token` is never intended for client reads. Use Edge Functions or a service-role worker to write encrypted Spotify refresh tokens.
- The schema publishes session, member, queue-item, and queue-event changes for Supabase Realtime. Use Broadcast for short-lived presence data; update `last_seen_at` through a small dedicated RPC when that feature is wired.
