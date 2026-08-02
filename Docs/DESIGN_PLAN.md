# Harmony Design Plan

## 1. Product promise

Harmony is a shared, provider-neutral music room. A Conductor creates a room, invites collaborators, and owns playback control. Everyone can contribute to a single Harmony queue, while each listener can resolve that queue through their own Apple Music or Spotify account when supported.

Harmony coordinates _intent_ and social state; it does not host, transmit, or synchronize audio streams.

## 2. MVP boundaries

### Included

- A signed-in user creates, joins, and leaves a session.
- A session has a title, invite code/link, Conductor, roles, presence, queue, revision, and playback intent.
- Members can add tracks and see Apple Music/Spotify availability before adding.
- Conductor can reorder, remove, play, pause, and skip.
- Each client maps a canonical Harmony track to its connected provider.
- Apple Music and Spotify are both visible, independently connected, and independently fallible.

### Explicitly not included in the first public build

- Audio rebroadcasting, playlist import/export, voting, chat, profile feeds, payment, ads, or automated moderation.
- Promise of frame-accurate cross-provider synchronization.
- Android/web clients, SharePlay, and background session recovery.

## 3. Roles and permissions

| Action | Conductor | Collaborator |
| --- | --- | --- |
| Create/end session | Yes | No |
| Invite people | Yes | Yes, if room setting allows |
| Add track | Yes | Yes |
| Move/remove any queue item | Yes | No initially |
| Remove own item | Yes | Yes |
| Playback controls | Yes | No |
| Listen on own provider | Yes | Yes |

The server is the permission authority. The app may hide unavailable controls, but it must never rely on hidden UI for enforcement.

## 4. Primary screens

### Welcome and authentication

One-screen sign-in with Apple. After login, show recent sessions and an empty-state button for “Start a session.” Guest invite links lead here, then resume joining after authentication.

### Home

Shows active/recent rooms, a “Start a session” button, and a “Join with code” action. The local prototype currently opens directly into a sample session; this becomes the home screen after authentication exists.

### Create session

Inputs: title, permission setting (all collaborators can add; Conductor-only reorder), playback mode, and optional expiry. It returns a six/eight-character invite code plus a universal link.

### Live session

The core screen has four regions:

1. Header: room title, Conductor, participant count, invite/share action, and connection health.
2. Now playing: current canonical item, playback status, provider selected by the device, and Conductor controls.
3. Queue: ordered items, contributor, provider availability, drag handles for the Conductor, and swipe actions.
4. Bottom navigation: session, add music, and connections.

### Add music

Search each connected catalog concurrently, normalize results into a single canonical track, and show source chips. Adding emits one Harmony queue command, never a direct provider queue edit.

### Connections

Each provider has states: disconnected, connecting, connected, unavailable, permission denied, subscription required, or open-in-provider only. Include a clear disconnect action and explain that the provider authorizes only the user’s device.

## 5. Queue and playback behavior

### Queue command contract

```text
QueueCommand
  id                 UUID client-generated idempotency key
  sessionID
  actorID
  expectedRevision
  type               add | move | remove | play | pause | skip
  payload
  createdAt
```

The client performs optimistic updates. The server wraps validation, event append, and materialized queue update in one database transaction. A conflict returns the latest revision/events; the client replays eligible local commands or shows a resolution prompt.

### Playback modes

| Mode | Server state | Local device behavior |
| --- | --- | --- |
| Conductor playback | Conductor provider and playback intent | Only Conductor sends play/pause/skip to provider |
| Personal listen-along | Track plus intended start timestamp | Member resolves and starts through their provider |
| Queue-only | Queue only | Member opens their provider manually |

“Personal listen-along” is intentionally approximate. The UI must say “Ready to listen” rather than claim universal synchronization.

## 6. Track matching model

The Harmony queue stores a `canonical_track_id`, not an Apple or Spotify ID. A canonical record includes normalized title, artist, album, duration, artwork, and ISRC when available.

Provider mappings are scoped by provider and storefront:

```text
provider_tracks
  canonical_track_id
  provider                 apple_music | spotify
  provider_id              Apple Music ID or Spotify URI
  storefront
  deep_link
  availability
  match_confidence
```

Resolution order: exact provider mapping, ISRC, normalized metadata with duration tolerance, then a visible unavailable/open-in-provider state. Never silently substitute a different recording.

## 7. iOS architecture

```text
SwiftUI Feature Views
        ↓ intents
SessionViewModel / SessionStore
        ↓ repository protocol
SessionRepository (local mock → Supabase)
        ↓                     ↓
ProviderResolver       Realtime event stream
        ↓
AppleMusicAdapter / SpotifyAdapter
```

The existing `HarmonySessionStore` is the local mock implementation. Extract its data access behind protocols before adding Supabase so unit tests remain fast and provider integrations cannot mutate canonical state directly.

## 8. Backend architecture

Use Supabase:

- Auth: Sign in with Apple.
- Postgres: sessions, members, tracks, mappings, queue items, queue events, invitations.
- Realtime Broadcast: presence and queue-event fan-out.
- RPC/Edge Function: validates command role/revision and writes events atomically.
- Row-Level Security: membership is required to read; commands are subject to room role; provider tokens are private to their owner.

Minimum database tables:

```text
profiles(id, display_name, avatar_url)
sessions(id, title, conductor_id, invite_code, revision, playback_state)
session_members(session_id, profile_id, role, joined_at, last_seen_at)
canonical_tracks(id, title, artist, album, duration_ms, isrc, artwork_url)
provider_tracks(id, canonical_track_id, provider, provider_id, storefront, availability)
queue_items(id, session_id, canonical_track_id, added_by, position, created_at)
queue_events(id, session_id, revision, actor_id, type, payload, created_at)
provider_connections(id, profile_id, provider, encrypted_refresh_token, expires_at)
```

## 9. Provider implementation plan

### Apple Music

1. Enroll in Apple Developer Program and enable MusicKit for Harmony’s App ID.
2. Add `NSAppleMusicUsageDescription`, MusicKit capability, and `MusicAuthorization` flow.
3. Use MusicKit catalog search and local playback on a physical device.
4. Resolve canonical tracks to catalog IDs per storefront.

### Spotify

1. Register the iOS bundle ID and redirect URI in Spotify Developer Dashboard.
2. Add the Spotify iOS SDK/App Remote and URL scheme configuration.
3. Complete OAuth with PKCE; store refresh tokens server-side, encrypted.
4. Use App Remote for active-device control and the Web API for metadata/queue capability where permitted.
5. Clearly gate Premium-only player controls and App Remote availability.

## 10. Security and privacy

- Do not embed Apple developer tokens, Spotify secrets, or Supabase service keys in the app.
- Use Keychain for short-lived device credentials and backend encryption for Spotify refresh tokens.
- Request only provider scopes required for search and user-initiated playback.
- Give users an explicit provider disconnect/delete-connection control.
- Persist event actor IDs for abuse investigation; do not collect audio or listening history beyond the data required for the session.

## 11. Test plan

| Layer | Tests |
| --- | --- |
| Domain | Queue ordering, role checks, revision conflicts, track availability |
| Repository | Event serialization, optimistic rollback, realtime reconnection |
| UI | Create/join, add track, drag reorder, unavailable mapping state |
| Devices | Apple Music authorization/playback; Spotify app remote; two-account session |
| Backend | RLS policies, RPC role validation, replay/idempotency |

## 12. Milestone checklist

### Milestone 0 — local interactive prototype

- [x] Provider-neutral models
- [x] Sample Apple Music and Spotify mappings
- [x] Session, queue, add, remove, reorder, and playback mock UI
- [x] Simulator build

### Milestone 1 — live collaboration

- [x] Supabase project and schema
- [ ] Sign in with Apple
- [x] Anonymous sign-in for personal-project development
- [x] Create/join/share session
- [x] Realtime queue updates
- [x] Conflict/revision recovery
- [ ] Presence / participant list backed by Supabase Realtime

### Milestone 2 — real services

- [ ] MusicKit setup and Apple Music device adapter
- [ ] Spotify developer setup, OAuth, and App Remote adapter
- [ ] Canonical search/matching pipeline
- [ ] Provider-specific error and fallback UI

### Milestone 3 — hardening

- [ ] Push notifications
- [ ] Disconnect/deletion/privacy controls
- [ ] Unit/UI/device test coverage
- [ ] TestFlight release checklist
