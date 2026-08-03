# Harmony implementation guide

**Last verified against the repository:** 2 August 2026. This guide describes
the implementation that is in source control, rather than the older MVP plan.
It is intended to answer two questions: *what does Harmony do?* and *where is
each decision enforced?*

## 1. Product and trust model

Harmony is a provider-neutral coordination service for shared music. A
**Conductor** creates a live room, shares an invite, and owns playback control.
Members contribute to one canonical queue. Each person listens using their own
music-service account and device.

Harmony coordinates queue intent and social activity; it never carries,
rebroadcasts, or synchronizes audio. “Listen along” therefore means each
device resolves the intended track in its provider. It is deliberately not a
promise of sample-accurate synchronization.

The social layer adds four opt-in experiences:

| Feature | What it stores | What it does not do |
| --- | --- | --- |
| Collaborative rooms | canonical queue and playback intent | stream audio or share a provider account |
| Eavesdrop | short-lived now-listening card and provider deep link | expose position, library, or audio |
| Listening history | user-approved Harmony plays and explicit provider imports | silently scrape a provider history |
| Reviews | track/album rating, review, comments, and reactions | require a subscription or connected provider |

The architectural rule throughout is: the server owns shared state and
authorization; a provider adapter controls only the signed-in user’s local
playback/catalog interaction.

## 2. User-visible features

### Live collaboration

- Create a session with title, expiry, playback mode, and collaborator-invite
  setting. A generated 6–8 character code and universal-link-compatible URL
  can be shared.
- Join an active, unexpired room by invite code; recent rooms can be resumed.
- Add a canonical track, remove one’s own contribution, and see membership and
  queue changes live. The Conductor can reorder/remove any item, play/pause,
  skip, end the room, and change invite permission.
- Playback modes are `conductor_playback`, `personal_listen_along`, and
  `queue_only`. The latter intentionally rejects server playback commands.
- Revisions and client-generated command IDs make queue changes conflict-aware
  and retry-safe.

### Provider-neutral catalog and connections

- The queue refers to a `canonical_track`, never directly to a Spotify or
  Apple Music identifier.
- Every canonical track can have an Apple Music and/or Spotify mapping,
  including storefront, deep link, availability, and match confidence.
- Spotify catalog search is live when connected. Spotify catalog tracks are
  canonicalized server-side by exact mapping/ISRC and returned as neutral
  Harmony tracks with attribution and explicit-content metadata.
- Spotify App Remote provides local-device playback control for a Premium
  account with the Spotify app installed. The Web API token is short-lived and
  is never persisted in iOS.
- Apple Music is represented in the UI and provider model, but live MusicKit
  authorization/catalog/playback remains gated on Apple developer setup and
  physical-device authorization.

### Social and diary

- Follow is a request/accept relationship. People can remove an outgoing
  follow, remove a follower, block, and unblock.
- Blocking removes both follow edges and hides each person’s follower-visible
  data immediately through database policy.
- Eavesdrop is an explicit foreground action. It publishes one card per user,
  with a five-minute normal lifetime and a database-enforced ten-minute maximum.
  Users can stop it explicitly. Spotify “now playing” is an explicit snapshot,
  not a background polling system.
- Listening history supports manual recording, opt-in Harmony skip logging,
  and explicit import of up to 20 recently played Spotify tracks. Imported
  plays are exactly deduplicated.
- A review can concern a canonical track or a provider-addressed album. It
  supports 0.5–5.0 ratings, an independent Loved affinity signal, review text,
  spoiler flag, visibility, editing, soft deletion, comments, and reactions.
  A dated journal listen remains separate from the listener's current opinion,
  so repeat listens do not overwrite a rating or review.
- Durable in-app notifications cover follow requests/acceptance, review
  comments, and reactions. Their data is the future source for APNs delivery;
  APNs is not yet enabled.

## 3. iOS implementation

### Composition and state ownership

`HarmonyApp` constructs one `HarmonySessionStore` and injects it into the
SwiftUI tree. On launch it calls `bootstrap()`; incoming links are passed to
`handleOpenURL(_:)`. `ContentView` provides five tabs:

```text
Session       PlayerView / SessionView        rooms, queue, playback intent
Add music     SearchView                       catalog search and album review
Connections   ConnectionsView                  providers, profile, privacy
Listen        SocialView                        follows, live activity, history, inbox
Reviews       ReviewsView                       community reviews, composer, journal
```

`HarmonySessionStore` is the `@MainActor` observable application state. It
contains screen-facing state, transforms remote DTOs into domain types, makes
optimistic local changes, displays recoverable errors, and owns the
subscriptions used to refresh live state. It delegates all network persistence
to `HarmonyCollaborationRepository`.

```text
SwiftUI action
    -> HarmonySessionStore (presentation state, optimistic UX)
        -> HarmonyCollaborationRepository (Supabase RPC/REST/Function)
            -> Postgres transaction or Edge Function
                -> Supabase Realtime / refreshed snapshot
                    -> store updates view state
```

This separation is intentional: a view does not contain authorization logic,
and a music provider cannot mutate the shared queue directly.

### Domain types and adapters

`Song.swift` contains the app domain:

- `HarmonyTrack`, `ProviderTrackMapping`, and `ReviewableAlbum` model catalog
  identity and provider resolution.
- `SessionMember`, `QueueItem`, `QueueEvent`, role, playback-mode, availability,
  and social relationship/privacy types represent shared state.
- `HarmonyMusicProvider` is the local-provider contract. `AppleMusicProvider`
  handles the MusicKit boundary; Spotify connection and App Remote code are
  coordinated by the session store.

`HarmonyCollaborationRepository.swift` contains the Codable remote models and
the application gateway. Its `LiveQueueSubscription`,
`LiveSessionSubscription`, `LivePresenceSubscription`, and
`LiveSocialSubscription` wrappers isolate Realtime lifecycle details from the
UI. `SupabaseConfiguration.swift` creates the single Supabase client from the
app’s Info.plist configuration; only the project URL, publishable key, Spotify
client ID, and redirect URI belong in the app.

### Important flows

**Queue mutation:** The store generates a UUID command ID and submits the
latest known revision. The RPC either returns the next revision or a conflict
with the current one. Reusing an applied command ID returns the original
result, so a retry cannot append a duplicate event.

**Spotify OAuth:** iOS starts PKCE and keeps the verifier locally for the
authorization round trip. It passes the authorization code/verifier to the
token-exchange function. The function exchanges it server-side, encrypts the
refresh token, and saves it; iOS obtains only a short-lived access token when
App Remote needs one.

**Social visibility:** Connections lets an owner update display name,
Harmony-play recording consent, and separate live/history/review visibility.
The UI offers Only me and Followers. The database supports `public` for a
future intentional discovery feature, but no public-discovery product surface
is implemented.

## 4. Supabase data model

### Collaboration tables

| Table | Role |
| --- | --- |
| `profiles` | one profile per Supabase Auth user; created by trigger |
| `sessions` | room metadata, Conductor, invite, revision, playback intent, lifecycle |
| `session_members` | per-room role and last-seen membership |
| `canonical_tracks` | provider-independent track identity/metadata/ISRC |
| `provider_tracks` | provider/storefront mapping, link, availability, confidence |
| `queue_items` | materialized ordered queue using fractional positions |
| `queue_events` | immutable, per-session revisioned event log and idempotency key |
| `provider_connections` | owner-scoped provider identity, scopes, encrypted refresh token |
| `provider_connection_statuses` | safe view of connection metadata without token material |

Fractional `position` values let a move update one queue row. A future
maintenance task may rebalance positions if repeatedly inserted values become
too close; that is not a current correctness concern.

### Social tables

| Table | Role |
| --- | --- |
| `profile_social_settings` | per-owner live/history/review visibility plus consent |
| `social_follows` | request/accepted follower edges |
| `profile_blocks` | directional blocks; visibility helper treats either direction as blocked |
| `listening_presence` | one expiring now-listening record per profile |
| `listening_history_entries` | immutable, owner-removable logged/imported plays |
| `music_reviews` | track or provider-album opinion, rating, Loved signal, visibility, soft delete |
| `review_comments` | comments with author-owned soft deletion |
| `review_reactions` | one reaction per viewer/review/kind |
| `social_notifications` | recipient-owned in-app inbox and read state |

The social schema distinguishes *identity* (canonical tracks) from an album
review’s first-release provider identifier. This allows album reviews before a
canonical-album matcher exists, without pretending Spotify and Apple Music
album IDs are interchangeable.

## 5. Authorization, RLS, and RPC contracts

Postgres Row-Level Security is the authority, not disabled buttons in iOS.
Normal authenticated clients can read only allowed rows and cannot directly
write shared queue, token, social-content, or notification tables. Privileged
changes go through narrowly scoped `security definer` RPCs after checking
`auth.uid()`.

### Collaboration commands

| RPC | Enforcement and result |
| --- | --- |
| `create_session` | caller becomes Conductor and first member |
| `join_session_by_invite` | active/unexpired invite; idempotent membership insert |
| `apply_queue_command` | membership, expected revision, role/ownership, advisory lock, event append and state update in one transaction |
| `skip_queue_item` | Conductor only; rejects queue-only playback and advances queue atomically |
| `end_harmony_session` / `leave_harmony_session` | Conductor ends; collaborators leave |
| `set_harmony_collaborator_invites` | Conductor only |
| `resolve_harmony_track` | idempotent provider-to-canonical mapping resolution |

`is_session_member(session_id)` is a security-definer helper used by reading
policies to avoid recursive membership policy evaluation. Room reads require
membership. Queue mutations record the actor and cannot be forged as another
member.

### Social commands and visibility

`can_view_social(owner, visibility)` centralizes private/follower/public logic;
it first denies either-direction blocks. `is_accepted_follower(owner)` and
`social_accounts_are_blocked(left, right)` support it. Activity, history,
reviews, comments, reactions, and notifications all rely on this database
policy layer.

The main social RPCs are `request_social_follow`,
`respond_to_social_follow`, `remove_social_follow`,
`remove_social_follower`, `block_social_profile`, `unblock_social_profile`,
`publish_listening_presence`, `stop_listening_presence`,
`record_listening_history`, `delete_listening_history_entry`,
`create_music_review`, `update_music_review`, `delete_music_review`,
`add_review_comment`, `delete_review_comment`, `toggle_review_reaction`, and
`mark_social_notifications_read`.

Database triggers create a profile/social-settings row at signup and create
notifications atomically for follow state transitions, comments, and
reactions. They prevent client-side notification forgery and give APNs a
single server-owned event stream to consume later.

### Realtime

The `supabase_realtime` publication includes rooms, members, queue items,
queue events, follower graph, blocks, settings, listening activity/history,
reviews, comments, reactions, and notifications. Postgres Changes still uses
RLS. Ephemeral room attendance should use Supabase Realtime Presence rather
than a durable member row. The app refreshes materialized snapshots when a
subscription indicates that relevant remote data changed.

## 6. Edge Functions and provider secrets

All Spotify functions require a valid Harmony bearer token. They use Supabase
Function Secrets for `SPOTIFY_CLIENT_ID`, `SPOTIFY_CLIENT_SECRET`, and a
random 32-byte base64 `SPOTIFY_TOKEN_ENCRYPTION_KEY`. Refresh tokens are
AES-GCM encrypted before storage. Neither a Spotify client secret, an Apple
developer token, nor a Supabase service-role key is shipped in the app.

| Function | Responsibility |
| --- | --- |
| `spotify-token-exchange` | PKCE code exchange, encrypt and save refresh token |
| `spotify-access-token` | refresh and return short-lived token for App Remote; `no-store` |
| `spotify-disconnect` | delete only caller’s stored connection |
| `spotify-search` | refresh token, search catalog, canonicalize/mapping, return safe metadata |
| `spotify-history-import` | explicit recent-plays import, scope check, canonicalization, exact-play deduplication |
| `spotify-now-listening` | explicit current-track snapshot and five-minute presence publish |
| `delete-account` | service-role cleanup of owned data followed by Auth-user deletion |

An existing Spotify connection must be reauthorized after a newly required
scope is introduced. History import requires `user-read-recently-played`;
current playback requires its read scope; App Remote controls require Spotify
Premium, the installed Spotify app, and a reachable App Remote transport.

## 7. Privacy and security decisions

- All new social settings default to **Only me**; Harmony play logging is
  default-off. A user explicitly chooses both recording and visibility.
- History import and Spotify current-playback sharing are foreground actions.
  There is no background provider history collection.
- Presence records expire; expired records disappear through RLS even if a
  cleanup job has not removed them yet.
- Blocks remove follow edges and deny visibility in either direction.
- Provider links are controlled display metadata; tokens, library contents,
  playback positions, and raw provider sessions are never read by other users.
- Account deletion uses a server-only cleanup RPC and then removes the Auth
  user. The iOS app does not receive authority to delete arbitrary data.
- Reviews/comments are soft-deleted so owner intent and auditability remain
  compatible with social notification records.

## 8. Testing and operational workflow

### Automated checks in the repository

| Layer | Location | What it proves |
| --- | --- | --- |
| Swift unit tests | `Harmony/HarmonyTests/HarmonyTests.swift` | domain queue behavior, provider state and OAuth/PKCE assumptions |
| Swift UI tests | `Harmony/HarmonyUITests/` | launch and primary UI interactions/accessibility |
| Live backend smoke | `Harmony/supabase/tests/live_smoke.sh` | disposable-user auth, RLS, role controls, revisions, idempotency, lifecycle, social privacy, and cleanup |
| Realtime smoke | `Harmony/supabase/tests/realtime_smoke.mjs` | follower-graph change delivery through Supabase Realtime |

The live smoke test reads the project URL and public key from the iOS plist,
does not print tokens, and needs a Node 22+ binary only for its native
WebSocket assertion. It is an integration/security test, not a substitute for
provider-device testing.

### Local development and deployment

```bash
# From /Users/geridoe/App Development/Harmony/Harmony
supabase link --project-ref YOUR_PROJECT_REF
supabase db push
supabase secrets set --env-file supabase/functions/.env
supabase functions deploy spotify-token-exchange
./supabase/tests/live_smoke.sh
```

Deploy every changed Edge Function explicitly. Use the checked-in
`supabase/functions/.env.example` only as a shape reference; never commit a
real secrets file. iOS configuration values should be supplied through an
untracked xcconfig/Info.plist configuration, not source code.

For iOS, build and test through the selected Xcode toolchain using
`xcodebuild`/Xcode. Provider playback must be verified on a physical device:
the Simulator cannot establish Spotify App Remote playback or grant a real
MusicKit library/playback authorization.

## 9. Delivery status and gates

### Implemented and deployable now

- Supabase schema, RLS, RPC authority, Realtime publication, profile creation,
  account deletion, collaborative rooms, queue revisions/idempotency, invites,
  lifecycle, social graph, privacy, blocks, eavesdrop, history, reviews,
  comments/reactions, and in-app notifications.
- iOS SwiftUI screens for Session, Add music, Connections, Listen, and Reviews; live
  data/store/repository integration; Spotify OAuth/App Remote integration;
  Spotify search, now-playing share, and user-triggered history import.
- Automated unit/UI and backend live/Realtime smoke-test artifacts.

### Requires user action or external entitlement

| Gate | Why it is gated | Work that can proceed without it |
| --- | --- | --- |
| Spotify reauthorization | previously connected accounts lack newly requested history scope | all UI/backend implementation; then reconnect once and import |
| Spotify Premium + installed app | App Remote controls a local Spotify client | search, queue, review, history import, social data |
| Apple Developer Program / MusicKit capability | MusicKit device authorization and developer-token/capability path | entire Supabase/social/Spotify product |
| Sign in with Apple configuration | Apple App ID, entitlement, redirect/auth settings | anonymous/dev Supabase testing and all non-Apple provider features |
| APNs / TestFlight | paid Apple membership, push credential, distribution setup | durable in-app notification system and local/physical-device builds |

### Intentional non-goals at this stage

- Audio streaming/rebroadcasting, remote control of another person’s provider,
  guaranteed cross-provider timing, DMs/chat, automated moderation, ranking,
  ads, and Android/web clients.
- Background provider polling or automatic provider history ingestion.
- Public discovery UI. The database supports a `public` visibility value so it
  can be added deliberately with moderation/discovery design later.

## 10. Recommended next engineering slices

1. Reauthorize the Spotify test account, then verify recent-play import,
   now-playing share, search, and local App Remote playback on a physical
   iPhone. Capture server/function errors separately from App Remote transport
   errors.
2. Enroll/configure the Apple developer assets, enable MusicKit, and implement
   the equivalent Apple catalog resolution, playback, and opted-in history
   source. Keep its adapter local and submit only canonical/provider metadata
   to the backend.
3. Add server-owned APNs delivery from `social_notifications`; retain the
   database row as the source of truth and provide notification preference UI.
4. Add production operational work: error reporting, scheduled cleanup of
   expired presence, rate limiting/abuse reporting, privacy-policy copy,
   TestFlight build settings, and device-pair collaboration tests.
5. If public discovery is desired, design moderation/reporting, profile
   discovery queries, rate limits, and explicit migration from follower-only
   UI before exposing the existing `public` data value.

## 11. File map

| Area | Primary files |
| --- | --- |
| App composition and screens | `Harmony/HarmonyApp.swift`, `Harmony/ContentView.swift`, `Harmony/PlayerView.swift`, `Harmony/SearchView.swift` |
| State/domain/providers | `Harmony/Song.swift`, `HarmonyMusicProvider.swift`, `Harmony/AppleMusicAPI.swift` |
| Network and Realtime | `Harmony/HarmonyCollaborationRepository.swift`, `Harmony/SupabaseConfiguration.swift` |
| Database authority | `supabase/migrations/` |
| Provider and account backend | `supabase/functions/` |
| Backend test tools | `supabase/tests/` |
| Product intent | `Docs/DESIGN_PLAN.md`, `Docs/PRODUCT_SPEC.md`, `Docs/SOCIAL_EXPANSION_SPEC.md` |

When changing a feature, update the relevant view/store/repository *and* its
database policy/RPC/function contract. A SwiftUI-only change is never a
complete authorization change in Harmony.
