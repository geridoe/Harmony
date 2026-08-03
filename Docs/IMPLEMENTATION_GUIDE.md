# Harmony implementation guide

**Last verified against the repository:** 3 August 2026. This guide describes
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
  canonicalized server-side and returned with canonical UUID, ISRC, exact
  duration, attribution, and explicit-content metadata. Client merging treats
  unequal canonical UUIDs as distinct even when display names match.
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
- Eavesdrop is an explicit foreground action. It publishes one active card per
  user, backed by a durable broadcast identity so comments, Heart/Fire/Headphones
  reactions, moderation, and notifications cannot attach to a later song by
  mistake. The active window has a five-minute normal lifetime and a
  database-enforced ten-minute maximum. Users can stop it explicitly. Spotify
  “now playing” is an explicit snapshot, not a background polling system. See
  `EAVESDROP_DESIGN.md` for the identity, cross-provider, and privacy contract.
- Listening history supports manual dated track logs with Relisten, normalized
  tags, and a per-entry audience; opt-in Harmony skip logging; and explicit
  import of up to 20 recently played Spotify tracks. Imported plays are exactly
  deduplicated.
- A review can concern a canonical track or canonical album. Album reviews keep
  their authored provider snapshot while exact provider identity resolves to a
  canonical release; only trusted server ingestion may bridge providers by
  UPC/EAN. It supports written-only reviews or optional 0.5–5.0 half-star
  ratings, an independent Loved affinity signal, spoiler flag, visibility,
  editing, soft deletion, comments, and reactions.
  A dated journal listen remains separate from the listener's current opinion,
  so repeat listens do not overwrite a rating or review.
- Durable in-app notifications cover follow requests/acceptance, review
  comments/reactions, and list likes/comments. Their data is the future source for APNs delivery;
  APNs is not yet enabled.
- Listen owns the durable following Activity page and its member-profile
  navigation. Intentional manual Diary logs and first-published Reviews appear as
  typed events; each member profile has independently paginated Reviews,
  Diary, opt-in Loved, and Lists shelves.

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
Reviews       ReviewsView                       authored reviews and current ratings
```

The Reviews destination is a root tab, never a child of Listen. It opens on
Reviews and provides a sibling Ratings shelf. Diary, Following Activity,
Music shelf, and Lists are full-page destinations reached from Listen. That
hierarchy keeps authored opinions and current ratings out of the listening
utility page while keeping dated listens distinct from reviews.
My Reviews uses an auth-bound keyset-paginated owner library and exhaustive
server totals for review count, average rating, and Loved count. Search and
Songs/Albums/Loved scope apply to the currently loaded owner pages, while the
summary never changes merely because followed members publish newer content.
`ReviewBrowseFilter` is value-typed
and `browseMusicReviews` is a pure transformation, which keeps browsing from
mutating review, Diary, playback, queue, or catalog-search state.

Ratings reads independent current song state and presents a ten-bucket
half-star distribution. It does not infer a current rating from review text or
rewrite historical Diary ratings. Migration 039 supplies the equivalent
owner-private album state plus RLS-filtered visible-review aggregates and a stable
ten-bucket histogram; the Swift album shelf/detail integration consumes that
contract separately. Canonical album release identity remains defined by
migration 038 and does not imply an edition/grouping policy.

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

### Implemented: isolated Reviews subject picker

The Reviews tab has a **Choose a song or album** action. `ReviewsView` owns a
single `ReviewDraft`: subject (`track(HarmonyTrack)` or
`album(ReviewableAlbum)`), rating, body, Loved, spoiler disclosure, and an
explicit per-review audience.
If nothing is selected, the composer still falls back to `nowPlaying` for the
quick-review path.

`ReviewSubjectPicker` is a sheet with a local debounced query and segmented
**Songs / Albums** results. Song rows represent
`HarmonyTrack`; album rows are deduplicated by provider plus provider album ID,
not by mutable display metadata. The selected subject returns through a
closure and never adds a queue item, starts playback, or writes listening
history.

The picker calls `searchCatalog(query:purpose: .reviews)` and reads
`catalogSearchState(for: .reviews)`. Add music uses the independent `.addMusic`
state (also exposed through its compatibility accessors
`catalogSearchResults`, `isSearchingCatalog`, and `catalogSearchMessage`). Each
purpose has its own request UUID, so an older provider response is discarded
without replacing a newer query or changing the other surface's state.

At publication, `publishTrackReview` routes to
`createTrackReview(track:rating:body:visibility:isLoved:)`; the repository
resolves the canonical ID. `publishAlbumReview` routes to
`createAlbumReview(album:rating:body:visibility:isLoved:)`, preserving the
provider album identity and safe metadata. Both store methods return `Bool`:
the composer clears body/Loved only after success and therefore retains the
selected subject and author text on failure. The existing create/update RPCs,
RLS, and `is_loved` column are sufficient; this feature required no new schema
migration.

New drafts snapshot `reviewsSocialVisibility` when the composer opens and show
an explicit Only me/Followers audience picker. Submission passes that captured
value; changing the Connections default while a draft is open does not change
the pending review. A review can still be individually changed after creation
in Edit review. “Loved” remains the author’s independent affinity field:
it never creates a reaction, does not notify followers by itself, and is
visible only where the enclosing review is visible.

### Implemented: review detail, spoilers, and discussion

Review feeds now use a compact `ReviewCard`: `ReviewSummary` shows author,
rating, Loved, subject, an optional three-line non-spoiler excerpt, and compact
heart/comment/date metadata. The summary is a `NavigationLink` to
`ReviewDetailView`, keeping comments and mutation controls out of scrolling
feed cards.

The detail view receives the immutable `reviewID` plus the feed row as a
fallback. Review cards fetch only the parent row and its transactionally
maintained `heart_count` and `comment_count`; they never embed an unbounded
conversation. Opening the page refreshes a dedicated ID-keyed detail cache:
the parent review, the first 50 newest comments through
`list_review_comments`, and heart/comment totals plus viewer affinity through
`get_review_engagement`. “Load older comments” advances a stable
`(created_at, id)` keyset cursor. Realtime child-table changes reset cached
detail pages and totals as well as refreshing the review shelves, including
reviews opened from durable notification IDs.

Spoiler handling is deliberately local presentation state. A typed
`containsSpoilers` field flows from `music_reviews.contains_spoilers` into
`RemoteMusicReview`, the create/update repository parameter structs, and the
store's publish/update methods. The composer and editor expose the toggle.
When a spoiler-marked review opens, `ReviewDetailView.isShowingSpoilers` starts
false; the body is concealed behind an accessible Reveal review button until
that reader opts in. The flag does not change the review body or persist a
reader-specific reveal choice. Feed summaries never show a spoiler excerpt.

The detail screen owns the interactive social surface: the current heart
reaction, keyset-paginated comment thread, comment-author deletion, review-owner thread
moderation, and an add-comment draft. A review owner sees Edit and Delete both from their compact card and in
the detail toolbar; deletion dismisses the detail only after the server
confirms success. `updateReview`, `deleteReview`, comment add/delete, and
publication return `Bool` from the store’s guarded mutation path. The editor
dismisses only on `true`, and the comment text clears only on a successful
insert, preserving author input after validation, RLS, or network failures.
The current reaction choice is heart only. Provider deep links from a detail
are implemented. Review comment/reaction notifications carry the durable review
UUID and open that exact RLS-visible review even when it is outside the bounded
feed caches or the notification is already read. Additional reaction kinds,
reporting, and broader moderation policy remain follow-up work.

### Reviews picker and draft guarantees

`ReviewSubjectPicker` owns query, result mode, and debounce cancellation.
`HarmonySessionStore` owns purpose-keyed `CatalogSearchState` plus an
independent request UUID for `.addMusic` and `.reviews`. Album identity is
`(provider, provider album ID)`; two tracks on one provider album produce one
album row, while Spotify and Apple Music records do not collapse merely
because their display metadata matches.

`ReviewDraft` holds subject, rating, body, `isLoved`, spoiler disclosure, and
visibility. Visibility is copied from the profile default at draft creation
and is never re-read during submission. Existing `Bool` publication behavior
remains: clear only after success and preserve the whole draft/search context
on catalog, auth, validation, RPC, or RLS failure. Picker selection and
publication do not enqueue media or create listening-history entries.

Track drafts may opt into a dated Diary snapshot. `ReviewDraft` keeps the
Diary date, Relisten flag, normalized tags, audience, and rating mode separate
from the review. The rating mode is **Review rating**, **Unrated**, or
**Different rating**. Publication uses migration 044's
`create_track_review_with_optional_diary` RPC; there is deliberately no
sequential client fallback because reporting success after only one record was
saved would violate the authoring contract. The database creates the optional
Diary row first, the review second, and then links them in one transaction.
This preserves an independent historical Diary rating while making the
review's rating and Loved values the newest current track state.

### Implemented: manual dated music diary

The authoring surface is **Listen → Diary → Log a listen**. The top-level
Reviews tab remains dedicated to authored reviews and current ratings.
`DiaryEntryComposer` uses the track-only form of `ReviewSubjectPicker`, so song
selection reuses purpose-isolated `.reviews` catalog state without exposing an
album choice or causing queue, playback, history, or review side effects.

`DiaryEntryDraft` owns `track`, `listenedOn`, `isRelisten`, comma-separated
`tagsText`, and `visibility`. `normalizedTags` trims, lowercases, removes empty
values, and retains only the first occurrence of a duplicate. Client validation
matches the backend limit of ten tags and thirty characters per tag. The date
picker prevents a future selection. Audience snapshots `historySocialVisibility`
when the sheet opens rather than following later Connections changes.

Save calls
`createDiaryEntry(track:listenedOn:isRelisten:tags:visibility:)`. The store's
`isSavingDiaryEntry` guard prevents duplicate submission, the repository
canonicalizes the track, and `Bool` success controls dismissal so a failed
request retains every draft field.

Migration `202608020025_music_diary_entries.sql` adds `is_relisten` and `tags`
to `listening_history_entries`; the selected calendar date uses its existing
`played_at` timestamp. It replaces the prior `record_listening_history` RPC
with a single signature whose new trailing arguments have defaults. Migration
028 later extends that RPC with an optional ninth `p_rating` argument while
preserving all existing named callers. The server rejects future manual timestamps, normalizes and validates
tags, and rejects Relisten/tags on non-manual history. Provider-import repeats
remain governed by the pre-existing import-only unique index; separate manual
listens remain repeatable.

Quick logging remains a separate unadorned history action and does not infer
Relisten or tags.

### Diary editing and optional opinion linkage

Manual entries in **Listen → Diary** expose a pencil action with the
accessible label `Edit journal entry for <track>`. Imported and Harmony-room
history does not expose it. `DiaryEntryEditor` keeps the track immutable and
seeds `DiaryEntryDraft` from the existing date, Relisten flag, tags, audience,
and optional `linkedReviewID`.

`DiaryEntryDraft.listenedOnForSubmission` preserves date-only intent across
time-zone conversion: today submits the current instant, while an earlier day
submits local noon. Manual rows display only month/day/year; imported and
Harmony-room rows continue to display their real time of play.

The **Linked opinion** picker is edit-only. It offers **No linked opinion** and
the owner's active track reviews returned by
`compatibleOwnTrackReviews(for:)`. The client requires an exact canonical
track-ID match and rejects an ID outside that list before making a request.
This avoids presenting album opinions, another member's review, or an opinion
about a different recording. Creation does not silently infer a link.

**Save changes** calls
`updateDiaryEntry(_:listenedOn:isRelisten:tags:visibility:reviewID:)`. The store
accepts only an owned `source = manual` entry, shares the existing
`isSavingDiaryEntry` duplicate-submit guard, and returns `Bool`; failure keeps
the editor and draft intact. A successful call refreshes history before the
sheet dismisses.

Migration `202608030026_edit_music_diary_entries.sql` adds nullable
`listening_history_entries.review_id`, an index for non-null links, and a
manual-only constraint. `ON DELETE SET NULL` makes review deletion an unlink,
not diary deletion. Its owner-only `update_listening_diary_entry` RPC updates
the existing `played_at`, visibility, Relisten, normalized tags, and optional
review link. It rejects future timestamps and invalid tag limits as before.
A linked opinion must be caller-owned, undeleted, a track review, and match the
entry's canonical track; provider identity is a legacy fallback where both
sides supply it. Passing `p_review_id = null` unlinks it. Existing RLS/read
policies are unchanged.

Migration 026 is deployed to the linked Supabase project, and the hosted smoke
suite covers successful normalization/linkage plus foreign-owner and album-link
rejection. The DTO/repository contract adds
`RemoteListeningHistoryEntry.reviewID`, canonical track IDs in nested catalog
rows, and `updateListeningDiaryEntry(...)` using the exact named RPC fields.

### Implemented: owner-paginated journal browsing

Listen → Diary now reads `HarmonySessionStore.journalEntries`, a
separate owner-only manual-diary collection, instead of filtering the recent
social `listeningHistory` snapshot. `refreshJournalEntries()` replaces the
loaded journal with its first 50 rows; `loadMoreJournalEntries()` uses the last
row's `(playedAt, id)` cursor, deduplicates IDs defensively, and appends up to
50 older rows. Loading and has-more state are independent of the follower feed.
Create, edit, delete, and the journal-specific quick log refresh this owner
collection after success.

`JournalBrowseFilter` combines a query, `JournalBrowseScope` (`All`,
`Relistens`, `Linked opinions`), and `JournalBrowseSort` (`Newest`, `Oldest`).
`browseJournalEntries` searches title, artist, album, and tags with
case/diacritic folding, applies scope, and orders by `playedAt`, retaining input
order for timestamp ties. The SwiftUI controls use stable accessibility IDs
`journal-search`, `journal-scope`, and `journal-sort`; a no-match result uses
`journal-filtered-empty-state`. `journal-load-older` appears only when another
server page exists.

Filtering operates only on loaded `journalEntries`. It is a responsive recent
browsing aid, not an exhaustive server search: while Load older entries is
available, a no-match state means no match in loaded pages. Do not derive total
counts or claim that older matches do not exist. If exhaustive search becomes
a launch requirement, query/scope/tag filters need server parameters and
supporting indexes.

Migration `202608030027_paginated_music_diary.sql` defines
`list_my_listening_diary(p_before_played_at, p_before_id, p_limit)`. It is
auth-bound, manual-only, ordered `(played_at DESC, id DESC)`, requires the two
cursor values together, and accepts page sizes from 1 through 100. A matching
partial index supports that owner/cursor path. The repository requests 51
rows, exposes 50, and treats the extra row as the has-more sentinel. Migration
027 is deployed; hosted smoke covers owner isolation, identical-timestamp
keyset paging, and partial-cursor rejection.

### Implemented backend foundation: historical ratings and track state

Migration `202608030028_track_subject_state.sql` adds a nullable half-step
`rating` to manual `listening_history_entries` and creates private
`profile_track_subject_states`, keyed by `(profile_id, canonical_track_id)`.
The latter stores undated Listened, default rating, Loved, and Want to listen
without requiring a review row. Existing history and the newest active track
review per owner/track are backfilled for compatibility.

`record_listening_history` now has one nine-argument signature with optional
trailing `p_rating`. `set_listening_diary_rating` updates or clears the rating
snapshot on one owned manual entry. `set_my_track_subject_state` replaces the
caller's private state, makes a rating imply Listened, clears Want to listen
when Listened becomes true, and refuses to clear Listened while a Diary row or
active review still exists. Database triggers keep newly logged/reviewed music
and the current default rating synchronized without rewriting older Diary or
review snapshots.

The migration is deployed. Hosted smoke covers rating validation, owner-only
state reads, foreign-entry mutation rejection, rating-to-state synchronization,
independent Loved and Want-to-listen values, and review-to-current-state
synchronization. Swift decodes and caches this private track state.

Diary creation and editing are already integrated. `DiaryEntryDraft.rating` is
nullable, and **Rate this listen** activates the otherwise disabled shared
half-star picker when the author opts in. Creation sends optional `p_rating`. Editing calls the
migration-029 `update_listening_diary_entry_with_rating` RPC so date, audience,
Relisten, tags, linked opinion, and rating commit or roll back together. Rated
Journal rows show their historical score; unrated rows do not manufacture one.

Migration `202608030029_atomic_diary_rating_update.sql` is deployed, and hosted
smoke covers invalid-rating rejection, foreign-owner rejection, setting and
clearing the rating/default state, normalized companion fields, incompatible
review rollback, and historical Diary isolation from later current-state
edits. The older diary update
RPC remains available for installed-client compatibility.

### Implemented: private owner Music shelf

The Activity shelf's **Music shelf** link opens a dedicated owner collection
for one-row-per-track state. `HarmonySessionStore.trackSubjectShelf` is separate
from Diary occurrences and social feeds. Refresh requests 51 rows and keeps 50;
Load more uses `(updatedAt, canonicalTrackID)`, deduplicates canonical IDs, and
hydrates the single-track cache used by the track-detail controls.

The page offers All, Loved, Want to listen, Rated, and Listened scopes plus
case/diacritic-insensitive title, artist, and album search. Filtering describes
only loaded pages. Rows show canonical artwork and metadata, status badges, and
the current default rating. No public profile exposure is implied yet; RLS and
the RPC restrict this collection to its owner.

Migration `202608030030_paginated_track_subject_states.sql` deploys
`list_my_track_subject_states` with stable
`updated_at DESC, canonical_track_id DESC` keyset pagination, paired cursor
validation, a 1–100 limit, and a matching owner-first index. Hosted smoke covers
owner isolation, continuation, partial-cursor rejection, and limit validation.

### Implemented: canonical track detail and current state editing

Every Music shelf row navigates to `OwnerTrackDetailView`, keyed by its
nonoptional canonical UUID. It presents track metadata, current Listened,
Loved, Want-to-listen and optional half-star rating, plus loaded owner Diary
and Review sections. The rating copy explicitly distinguishes the current
overall rating from historical Diary snapshots.

`TrackSubjectStateDraft` is a value snapshot. It validates half-star input and
mirrors backend normalization: a rating establishes Listened, while Listened
clears Want to listen; Loved remains independent. The store mutation guard is
keyed by canonical UUID, uses the repository's direct UUID overload, and
updates cache/shelf only after success. A rejected clear retains the draft. An
accepted all-empty response removes the track from cache and the Music shelf.

Migrations `202608030032`–`034` delete empty current-state rows, clean legacy
no-op rows, synchronize track-review create/edit to current rating/Loved, and
serialize state/history/review writers with a shared owner/track advisory lock.
Track review save marks Listened and clears Want; review deletion preserves
current state. Album reviews remain outside track state. Clearing Listened
still fails while any Diary/history entry or active review exists.

### Implemented: typed following Activity and member shelves

Listen → Following activity is a durable following feed rather than a snapshot of
the current review query. `social_activity_events` records only the first
follower-visible publication of a Review or List, or an intentional manual Diary log.
Provider imports, Harmony-room history, historical rows, edits, ratings, and
Loved/Want-to-listen state changes do not emit. The referenced Review or Diary
row remains authoritative, so its current visibility, soft deletion, accepted
follow relationship, and either-direction blocks are enforced at read time.

The repository pages raw event cursors, then batch-hydrates typed payloads in
at most one Review, Diary, and List query. It advances with the raw cursor even
if an object becomes invisible between those reads, preventing a raced delete
from trapping pagination. Swift presents distinct cards and routes actor
identity into `MemberProfileView`.

Member profiles expose independently paginated **Reviews**, **Diary**,
**Loved**, and **Lists** shelves. Their state is keyed by member ID and does not reuse the
owner's editable review, diary, or subject-state caches. Review and Diary
audiences remain per object. Loved is an aggregate shelf with a separate
Only me/Followers setting in Connections; it defaults to private.

Migration `202608030031_social_activity_and_profile_shelves.sql` adds the
append-only event table, first-publication triggers, `shelf_visibility`,
Realtime publication, and the feed/profile RPCs. Pages use paired keyset
cursors and accept 1–100 rows. Hosted smoke covers idempotent republishing,
non-emitting imports, visibility changes, blocks, object deletion, follower
isolation, cursor ties, and Loved shelf opt-in.

## 4. Supabase data model

### Collaboration tables

| Table | Role |
| --- | --- |
| `profiles` | one profile per Supabase Auth user; created by trigger |
| `sessions` | room metadata, Conductor, invite, revision, playback intent, lifecycle |
| `session_members` | per-room role and last-seen membership |
| `canonical_tracks` | provider-independent track identity/metadata/ISRC |
| `provider_tracks` | provider/storefront mapping, link, availability, confidence |
| `canonical_albums` | provider-independent album release identity and trusted UPC/EAN |
| `provider_albums` | exact provider album/storefront mapping and identity evidence |
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
| `profile_social_settings` | per-owner live/history/review/Loved-shelf visibility plus consent |
| `social_follows` | request/accepted follower edges |
| `profile_blocks` | directional blocks; visibility helper treats either direction as blocked |
| `listening_presence` | one expiring now-listening record per profile |
| `listening_history_entries` | owner-removable history; manual rows support dated diary metadata, editing, and optional review links |
| `profile_track_subject_states` | private per-owner track state for Listened, default rating, Loved, and Want to listen |
| `social_activity_events` | append-only typed pointers for intentional Diary/Review follower activity |
| `music_reviews` | canonical track/album opinion with retained provider snapshot, optional rating, Loved signal, visibility, soft delete |
| `review_comments` | comments with author deletion and review-owner moderation |
| `review_reactions` | one reaction per viewer/review/kind |
| `social_notifications` | recipient-owned in-app inbox and read state |
| `music_lists` | owner-authored track collections with visibility and an entry revision |
| `music_list_entries` | exact ordered canonical tracks with optional per-list notes |
| `music_list_likes` | idempotent viewer/list affinity |
| `music_list_comments` | visible-list discussion with author/owner moderation |

The social schema separates canonical track and album release identity from
authored provider snapshots. Album provider IDs remain opaque; exact mappings
are safe for ordinary clients, while cross-provider UPC/EAN evidence requires
trusted server authority.

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
| `resolve_harmony_track_v2` | collision-safe provider/storefront, ISRC, then guarded metadata resolution |
| `resolve_harmony_track` | installed-client compatibility wrapper around v2 |
| `resolve_harmony_album_v2` | exact provider album resolution; UPC/EAN merge requires service-role attestation |
| `resolve_harmony_album` | installed-client provider-scoped album compatibility wrapper |
| `get_canonical_album`, `list_canonical_album_reviews` | canonical release detail and RLS-filtered review page |

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

Migration `202608030035_collision_safe_track_resolution.sql` brings the
resolver up to the canonical-matching policy in `DESIGN_PLAN.md`. Exact
provider/storefront identity wins. Otherwise a normalized, valid ISRC may join
the same recording across providers or alternate catalog IDs. Without ISRC,
fallback requires normalized title, artist, a nonempty album, and durations
within two seconds; title/artist alone can never merge recordings. Multiple
legacy ISRC candidates or a large ISRC-duration conflict fail explicitly.

`resolve_harmony_track_v2` accepts ISRC and storefront. The nine-argument
function remains a nonambiguous compatibility wrapper for installed clients.
The provider-per-canonical constraint is removed because one recording may
legitimately have multiple catalog IDs from the same provider; exact provider
identity remains unique. Provider and semantic advisory locks serialize races.
The nonunique legacy ISRC index stays until existing duplicate splits can be
audited safely—past false merges cannot be automatically reconstructed from
display metadata.

iOS carries a persisted `canonicalTrackID` separately from its local SwiftUI
row ID, preserves storefront/ISRC/exact duration, returns known canonical IDs
without another lookup, and rejects a mappingless unknown track instead of
guessing by title. Search result merging uses canonical ID, then provider ID,
then ISRC, then the same guarded metadata rule. The three Spotify Edge
Functions now share the transactional v2 RPC rather than performing separate
read-then-insert algorithms.

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
`list_my_listening_diary`, `update_listening_diary_entry`,
`update_listening_diary_entry_with_rating`,
`set_listening_diary_rating`, `set_my_track_subject_state`,
`list_my_track_subject_states`,
`list_following_activity`, `list_profile_listening_diary`,
`list_profile_music_reviews`, `list_profile_loved_tracks`,
`create_music_review`, `update_music_review`, `delete_music_review`,
`list_review_comments`, `get_review_engagement`, `add_review_comment`,
`delete_review_comment`, `toggle_review_reaction`, and
`mark_social_notifications_read`.

Database triggers create a profile/social-settings row at signup and create
notifications atomically for follow state transitions, comments, and
reactions. They prevent client-side notification forgery and give APNs a
single server-owned event stream to consume later.

### Realtime

The `supabase_realtime` publication includes rooms, members, queue items,
queue events, follower graph, blocks, settings, listening activity/history,
typed social activity events,
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
| `spotify-search` | refresh token, shared canonicalization, return canonical UUID/ISRC/exact metadata |
| `spotify-history-import` | explicit recent-plays import, shared canonicalization, exact-play deduplication |
| `spotify-now-listening` | shared canonicalization, explicit current-track snapshot and five-minute presence publish |
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

The implemented picker has coverage for choosing a subject, switching its
Songs/Albums result mode, provider-identity album deduplication, audience
snapshotting, and preserving the composer after a failed `Bool` publish.
Review-detail coverage should verify compact navigation, fresh-ID/fallback
rendering after a refresh, concealed/revealed spoilers, owner edit/delete,
and that failed edit/comment operations retain their drafts. Continue adding
coverage for stale/cancelled query rejection and an end-to-end assertion that
a Reviews search cannot alter Add music results. Backend smoke coverage should
continue to prove owner-only edits and visibility/block enforcement for both
subject kinds.

Music-diary coverage should verify stable tag normalization/deduplication,
client and server tag limits, rejection of future manual timestamps,
manual-only Relisten/tag metadata, follower/private visibility, repeat manual
listens, and preservation of the composer after a failed save. UI coverage
should keep Log a listen in Listen → Diary and verify the track-only picker, date,
Relisten, tags, audience, and disabled-until-valid Save flow.

Edit/link coverage should decode `review_id` and nested canonical identity,
preserve a draft's existing optional link, and prove owner/manual-only updates,
unlinking, same-track enforcement, deleted/foreign/album-review rejection,
`ON DELETE SET NULL`, future/tag validation, and failure draft retention. UI
coverage uses the debug-only `--ui-test-diary-editor` launch fixture to assert
the pencil affordance, fixed track, prefilled date/Relisten/tags, compatible
Linked opinion, audience, and Save changes without depending on a developer's
hosted diary contents. The fixture bypasses remote history/review refresh only
in DEBUG builds while that launch argument is present.

Journal-browse unit coverage verifies case/diacritic-insensitive matching for
title, artist, album, and tags; every scope; newest/oldest order; and stable
ties. UI coverage uses the same deterministic diary fixture to verify controls
and the filtered empty state without hosted data. Backend coverage must prove
owner/manual-only pagination, cursor tie behavior, page-size/cursor validation,
and isolation from follower-visible history.

Following-activity coverage verifies typed Diary/Review presentation and the
member-profile route. The deterministic DEBUG fixture
`--ui-test-social-activity` supplies both event types without depending on a
hosted account. A focused UI test navigates through the actor into Reviews,
Diary, and Loved shelves; a second test verifies the separate Connections
privacy control. Hosted smoke is the authority for first-publication
idempotency, no import/backfill emission, current object visibility, blocks,
profile shelf isolation, and stable keyset pagination.

Track-detail unit coverage verifies half-step bounds, normalization, value
snapshot isolation, failure-safe caches, direct canonical identity, and empty
state removal. Its deterministic UI test opens the Music shelf detail, edits
independent status, saves once, and reaches related Diary/review content.
Hosted smoke verifies review create/update synchronization, preservation of
historical Diary ratings, current-state rollback on a rejected clear, active
review blocking, deletion followed by a successful clear, and physical removal
of an all-empty row.

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
  comments/reactions, ordered music lists, and in-app notifications.
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
2. Extend the isolated Reviews picker with richer provider-specific empty and
   recovery states while retaining its separate journal/opinion/Loved model
   and no-queue/no-history guarantees.
3. Review detail, spoiler conceal/reveal, owner thread moderation, and exact
   notification-to-review routing are implemented; extend that surface with
   additional reaction choices and reporting controls.
4. Decide whether loaded-page journal search is sufficient or exhaustive
   server-side filtering is required.
5. Enroll/configure the Apple developer assets, enable MusicKit, and implement
   the equivalent Apple catalog resolution, playback, and opted-in history
   source. Keep its adapter local and submit only canonical/provider metadata
   to the backend.
6. Add server-owned APNs delivery from `social_notifications`; retain the
   database row as the source of truth and provide notification preference UI.
7. Add production operational work: error reporting, scheduled cleanup of
   expired presence, rate limiting/abuse reporting, privacy-policy copy,
   TestFlight build settings, and device-pair collaboration tests.
8. Validate the implemented **Add to list** actions, ranked editor, comments,
   and activity on a physical iPhone. Track-first Collections is deployed;
   album membership follows canonical album identity.
9. If public discovery is desired, design moderation/reporting, profile
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
