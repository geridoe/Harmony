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

### Implemented: Reviews subject picker

The Reviews tab now has a **Choose a song or album** action. `ReviewsView`
owns a local `ReviewDraftSubject?` (`track(HarmonyTrack)` or
`album(ReviewableAlbum)`), rating, body, Loved state, and sheet presentation.
If nothing is selected, the composer still falls back to `nowPlaying` for the
quick-review path.

`ReviewSubjectPicker` is a sheet with a debounced query and displays each
`HarmonyTrack` result with **Review song** and, where available, **Review
album** buttons. The selected subject returns through a closure, resets the
composer's rating/Loved/body fields, and never adds a queue item, starts
playback, or writes listening history.

Today the sheet calls `HarmonySessionStore.searchCatalog(query:)` and reads
the store-wide `catalogSearchResults`, `isSearchingCatalog`, and search
message. That is correct functional behavior but means it shares search state
with Add music; opening both surfaces can replace each other’s results. The
picker does not yet use a segmented Songs/Albums view or deduplicate album
rows.

At publication, `publishTrackReview` routes to
`createTrackReview(track:rating:body:visibility:isLoved:)`; the repository
resolves the canonical ID. `publishAlbumReview` routes to
`createAlbumReview(album:rating:body:visibility:isLoved:)`, preserving the
provider album identity and safe metadata. Both store methods return `Bool`:
the composer clears body/Loved only after success and therefore retains the
selected subject and author text on failure. The existing create/update RPCs,
RLS, and `is_loved` column are sufficient; this feature required no new schema
migration.

New reviews use the current global `reviewsSocialVisibility` at the moment of
submission. A review can be individually changed after creation in Edit
review, but the create composer does **not** yet snapshot or expose a
per-review audience. “Loved” remains the author’s independent affinity field:
it never creates a reaction, does not notify followers by itself, and is
visible only where the enclosing review is visible.

### Implemented: review detail, spoilers, and discussion

Review feeds now use a compact `ReviewCard`: `ReviewSummary` shows author,
rating, Loved, subject, an optional three-line non-spoiler excerpt, and compact
heart/comment/date metadata. The summary is a `NavigationLink` to
`ReviewDetailView`, keeping comments and mutation controls out of scrolling
feed cards.

The detail view receives the immutable `reviewID` plus the feed row as a
fallback. Its computed review first looks up that ID in the latest
`store.musicReviews`, then uses the fallback only until the refreshed/Realtime
snapshot is available. Consequently a comment, reaction, edit, or deletion
refresh changes the same detail screen without passing a stale copied review
through several views.

Spoiler handling is deliberately local presentation state. A typed
`containsSpoilers` field flows from `music_reviews.contains_spoilers` into
`RemoteMusicReview`, the create/update repository parameter structs, and the
store's publish/update methods. The composer and editor expose the toggle.
When a spoiler-marked review opens, `ReviewDetailView.isShowingSpoilers` starts
false; the body is concealed behind an accessible Reveal review button until
that reader opts in. The flag does not change the review body or persist a
reader-specific reveal choice. Feed summaries never show a spoiler excerpt.

The detail screen owns the interactive social surface: the current heart
reaction, full comment list, comment author deletion, and an add-comment
draft. A review owner sees Edit and Delete both from their compact card and in
the detail toolbar; deletion dismisses the detail only after the server
confirms success. `updateReview`, `deleteReview`, comment add/delete, and
publication return `Bool` from the store’s guarded mutation path. The editor
dismisses only on `true`, and the comment text clears only on a successful
insert, preserving author input after validation, RLS, or network failures.
The current reaction choice is heart only. Provider deep links from a detail
are implemented; deep links *from notifications*, additional reaction kinds,
and moderation workflows remain follow-up work.

### Follow-up: isolate picker state and add creation audience

The next refactor should introduce a `ReviewMediaPickerModel` that owns query,
result mode, debounce/cancellation, loading/error state, and local results.
It should call a store method that returns results rather than mutate
`catalogSearchResults`, so Add music and Reviews cannot race. That refactor
can add a segmented **Songs / Albums** result mode, deduplicating albums by
provider plus provider album ID and only allowing provider-identified albums
with a title to be selected.

At the same time, replace the parallel `ReviewsView` fields with a small
`ReviewDraft` value holding subject, rating, body, `isLoved`, and visibility.
Seed visibility from `reviewsSocialVisibility` on composer open, allow an
explicit Only me/Followers selection, and preserve that snapshot until save.
A Connections privacy change must not silently change an already-open draft.
Keep the existing `Bool` publication result behavior: dismiss/clear only after
success and preserve draft/search context on a recoverable catalog, auth,
validation, RPC, or RLS failure.

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

### Shared-input hardening

Migration `202608020024_catalog_and_queue_input_hardening.sql` closes two
Postgres-specific input gaps at the shared-data boundary:

- Queue positions have a table constraint requiring a value strictly between
  negative and positive infinity. This rejects `NaN`, `Infinity`, and
  `-Infinity` regardless of which future write path reaches `queue_items`, while
  retaining the complete finite `double precision` range used for fractional
  ordering. A rejected move rolls back before its event or revision can commit.
- `resolve_harmony_track` trims provider IDs and display metadata, bounds the
  album and URL lengths, permits artwork only over HTTPS, and accepts deep links
  only on the expected provider host (`open.spotify.com/track/…` or
  `music.apple.com/…`). These rules match the current Spotify Web API and Apple
  Music catalog outputs. Provider IDs remain opaque because Apple and Spotify
  use different identifier formats.
- Public function execution is explicitly revoked; authenticated clients and
  trusted service-role jobs retain the catalog-resolution RPC grant. The RPC
  still takes an advisory lock and returns an existing mapping idempotently.

The hosted smoke test covers both providers' accepted URL shapes, hostile link
and insecure-artwork rejection, plus `NaN` and `Infinity` queue moves. Negative
infinity is enforced by the same symmetric table constraint.

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

The implemented picker needs UI coverage for choosing a subject, its per-result
song/album actions, and preserving the composer after a failed `Bool` publish.
Review-detail coverage should verify compact navigation, fresh-ID/fallback
rendering after a refresh, concealed/revealed spoilers, owner edit/delete,
and that failed edit/comment operations retain their drafts. The follow-up
picker refactor needs unit coverage for album deduplication, visibility
snapshotting, and stale/cancelled query rejection, plus UI coverage that
Reviews search cannot alter Add music results and that a per-review audience
survives an in-flight Connections change. Backend smoke coverage should
continue to prove owner-only edits and visibility/block enforcement for both
subject kinds.

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
2. Refactor the implemented Reviews picker: isolate its catalog state from Add
   music, add segmented/deduplicated album results, and add explicit
   per-review audience snapshotting while retaining the current separate
   journal/opinion/Loved model and no queue side effect.
3. Review detail and spoiler conceal/reveal are implemented; extend that
   surface with additional reaction choices, comment moderation, and
   notification-to-review deep links.
4. Enroll/configure the Apple developer assets, enable MusicKit, and implement
   the equivalent Apple catalog resolution, playback, and opted-in history
   source. Keep its adapter local and submit only canonical/provider metadata
   to the backend.
5. Add server-owned APNs delivery from `social_notifications`; retain the
   database row as the source of truth and provide notification preference UI.
6. Add production operational work: error reporting, scheduled cleanup of
   expired presence, rate limiting/abuse reporting, privacy-policy copy,
   TestFlight build settings, and device-pair collaboration tests.
7. If public discovery is desired, design moderation/reporting, profile
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
