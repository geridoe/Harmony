# Reviews and listening journal design

**Decision date:** 2 August 2026  
**Status:** first dedicated iOS surface implemented; broader discovery work remains

## Why this is a separate product surface

Reviews are an identity and discovery feature, not a control attached to live
playback. Hiding them inside Listen made the feature feel incidental and mixed
three different user jobs: seeing friends, sharing live activity, and keeping a
music diary. Harmony now gives Reviews its own primary tab while Listen keeps
followers, notifications, eavesdropping, and listening history.

## Research findings

Letterboxd's transferable strength is its separation of four concepts:

1. A low-friction consumption status (watched).
2. A dated, repeatable diary log.
3. A rating/review that expresses an opinion.
4. A Like that is independent of the numeric rating.

Its social layer then makes reviews, likes, comments, lists, and follower
activity discoverable without treating every historic import as a new post.
These behaviors are documented in the [Letterboxd FAQ](https://letterboxd.com/about/faq/),
[official app overview](https://letterboxd.com/apps/), and
[App Store listing](https://apps.apple.com/us/app/letterboxd/id1054271011).

Harmony adopts that information model, not Letterboxd's branding, colors,
icons, poster grid, or copy.

## Harmony model

| Concept | Harmony representation | Behavior |
| --- | --- | --- |
| Playing now | queue/provider playback | ephemeral; not automatically a social post |
| Listening journal | `listening_history_entries` | dated and repeatable; imports are deduplicated |
| Opinion | `music_reviews` | current 0.5–5.0 rating and optional review |
| Affinity | `music_reviews.is_loved` | independent Loved signal; not a social reaction |
| Spoiler disclosure | `music_reviews.contains_spoilers` | author-controlled metadata; clients conceal the body until the reader reveals it |
| Community reaction | `review_reactions` | another listener reacting to a published review |

The distinction between affinity and reaction is important. “Loved” describes
the review author's relationship to the music. A heart on a review describes a
reader's response to that review.

## First implementation

The fifth iOS tab has two shelves:

- **Community** contains a current-track composer and follower-visible review
  feed. The rating control supports half-star steps. The author can mark the
  music Loved independently of the score.
- **My journal** contains the owner's dated listening entries and their own
  reviews. The copy explicitly explains that logs and opinions are independent.

Album review creation remains available on Spotify/Apple catalog results in
Add music. The server migration `202608020023_review_affinity.sql` adds the
affinity field and updates owner-authorized create/edit RPCs.

The Reviews composer now also has its own subject-picker sheet. It can select
a track or album from a catalog result without adding it to a party queue. This
is an implemented first pass; the dedicated local search model, segmented
album display, and creation-time per-review audience described below remain
follow-up work.

## Implemented subject-picker slice

### Goal and interaction

The composer no longer requires a user to add music to a party queue merely to
write an opinion. **Choose a song or album** opens `ReviewSubjectPicker`, a
sheet with one debounced search field. It currently presents each matching
track with two independent actions:

1. Search only connected catalogs after a short debounce.
2. **Review song** selects that `HarmonyTrack`.
3. **Review album** appears when the track supplies a `ReviewableAlbum`; its
   provider, provider album ID, title, artist, artwork, and deep link travel
   with the selection.
4. The author sets half-star rating, optional body, and Loved, then saves.
   Selecting media never adds it to the room queue, starts playback, or creates
   a listening-journal entry.

There is not yet a segmented Songs/Albums result mode or a deduplicated album
shelf. The same album can therefore be offered below multiple matching tracks.
Those are intentional follow-up refinements, not current behavior.

### Implemented state ownership and cancellation

The implemented ownership is:

| Owner | State / responsibility |
| --- | --- |
| `ReviewsView` | picker presentation, selected `ReviewDraftSubject?`, rating, Loved, review body, and edit form state |
| `ReviewSubjectPicker` | query text and the `Task.sleep` debounce tied to that query |
| `HarmonySessionStore` | provider connection state plus shared `searchCatalog(query:)`, search loading/message, and `catalogSearchResults` |
| Repository/providers | Spotify Edge Function or future MusicKit search, then canonical/provider resolution |

`ReviewDraftSubject` is currently a small enum:

```text
track(HarmonyTrack) | album(ReviewableAlbum)
```

Selecting a subject returns it through a closure, resets rating/Loved/body, and
dismisses the picker. It performs no database write. Today the picker reuses
`catalogSearchResults`; this means an Add music search and a Review picker
search can replace each other’s result set. Swift task cancellation prevents
cancelled debounce work from continuing, but there is no independent result
generation/token or local picker model yet.

### Persistence routing

The media picker needs no new table or migration. The existing endpoints are
the authority:

| Draft subject | Store/repository call | Server identity |
| --- | --- | --- |
| Track | `publishTrackReview` → `createTrackReview` → `create_music_review` | `canonical_track_id`; repository resolves it if necessary |
| Album | `publishAlbumReview` → `createAlbumReview` → `create_music_review` | provider + provider album ID plus validated title/artwork/deep link |

`ReviewsView` currently performs the small subject switch and calls the
appropriate store method. The store methods apply the existing
`isPublishingMusicReview` guard, refresh review lists on success, and return
`Bool`. The composer resets body/Loved only when that result is true, so a
failed request preserves the selected subject and the author’s text. It does
not dismiss the Reviews tab or discard the selection after failure.

### Loved, journal, and privacy semantics

Loved is `music_reviews.is_loved`, the review author’s affinity flag. It is
not `review_reactions.kind = 'heart'`, it does not create a notification, and
it does not assert that the author played the media today. It can be true at
any valid rating and remains editable with the review. A reader’s heart stays
a separate reaction to the post.

Spoiler disclosure is stored independently as
`music_reviews.contains_spoilers`. Only the review author can set or change it,
through the same owner-authorized create/update RPCs used for the rest of the
review. The flag does not change visibility or RLS: an authorized reader may
fetch it, but a conforming client must hide the review body by default and
require an explicit reveal. Ratings, Loved, subject metadata, comments, and
reactions are not classified as spoiler text and remain visible. Revealing is
local presentation state and is never persisted as consent for later reviews.

The database column and RPC parameters predate this UI slice, so no new
migration is required. The iOS repository now decodes `contains_spoilers` and
accepts `containsSpoilers` on track/album creation and owner edits. The review
composer and owner edit form expose the author-facing toggle, and cards require
an explicit per-review reveal before rendering a flagged body.

For a newly created review, the current store reads
`reviewsSocialVisibility` at submission time. It does not yet show audience in
the creation composer or snapshot a draft audience. Existing reviews do expose
an owner-only edit audience picker. In all cases, the saved review visibility
controls both the body and Loved marker; RLS and `can_view_social` deny blocked
viewers and viewers outside that audience. The picker never exposes provider
tokens, library contents, raw playback state, or another person’s catalog.
Choosing music is an intent to author a review, not consent to create a
live-presence or history record.

### Errors and recovery

| Condition | Picker/composer behavior |
| --- | --- |
| Empty query or no results | use the store's catalog/empty result presentation; do not submit without a selected/current subject |
| No provider / MusicKit unavailable | store provides existing catalog connection guidance; no picker-specific navigation yet |
| Spotify reauthorization or transient error | display the shared catalog message and retain the current Reviews composer |
| Album lacks required provider metadata | no album button is offered when `reviewableAlbum` is absent; server validation remains final authority |
| Canonical resolution/RPC/RLS error | store returns `false`, keeps subject/body/Loved/spoiler state in Reviews, and supplies `collaborationMessage` |
| Success | refresh lists; clear body/Loved/spoiler state; retain the selected subject for a potential subsequent opinion |

### Tests for the implemented slice

| Layer | Required coverage |
| --- | --- |
| Unit | `ReviewDraftSubject` routing; half-star bounds; Loved independence; `Bool` failure retains subject/body/Loved |
| Repository | track call contains canonical/provider mapping; album call preserves provider metadata; no direct table write is introduced |
| UI | fifth tab opens; Choose music opens picker; per-result Review song/Review album actions; selected subject appears in composer; cancel preserves no write; error preserves draft; success appears in My reviews |
| Backend smoke | both subject kinds respect owner-only edit/delete, follower/private visibility, and block enforcement |

The live backend smoke also creates a follower review with
`p_contains_spoilers = true`, verifies that an authorized follower reads the
flag, edits the same review as its author with the flag set to `false`, and
verifies that the cleared value persists. Its existing non-owner update check
continues to prove that another viewer cannot change spoiler metadata.

## Implemented review detail flow

Community and personal shelves now render compact `ReviewCard` summaries.
Each summary shows author, rating, Loved, media, a three-line non-spoiler
preview (or spoiler warning), reaction/comment counts, and date. Its
`NavigationLink` opens `ReviewDetailView`, where the full review, provider
link, heart action, comment thread/composer, and owner actions live. This keeps
conversation controls out of the scrolling feed while giving each opinion a
first-class destination.

The detail view is keyed by review ID and uses the navigation-time review only
as a fallback. After a successful reaction, comment, edit, or deletion refresh,
it reads the updated value from `HarmonySessionStore.musicReviews`; counts and
threads therefore do not remain stale while the page is open. Spoiler reveal
is per-page `@State` and defaults to concealed on every new navigation.

Review mutation helpers return `Bool`. Create/edit forms and the comment
composer clear or dismiss only after success, preserving authored text when a
network, validation, or RLS error occurs. Deletion navigates back only after
the backend confirms it. Owner authorization remains enforced by the RPCs/RLS,
not by the presence of SwiftUI menus.

## Follow-up picker refactor

Introduce `ReviewMediaPickerModel` with local query, result mode, debounce,
cancellation, loading/error state, and results. It should call a store search
method that returns results rather than mutating `catalogSearchResults`; this
prevents Add music and Reviews searches racing. Add a segmented Songs/Albums
presentation and deduplicate albums by provider plus provider album ID, while
requiring a provider ID and title before selection.

Replace the parallel creation fields with a `ReviewDraft` value:

```text
subject: track(HarmonyTrack) | album(ReviewableAlbum)
rating: Double                 // 0.5...5.0, half-star increment
body: String
isLoved: Bool
visibility: SocialVisibilityOption
```

Seed `visibility` from `reviewsSocialVisibility` when the composer opens,
display Only me/Followers in the creation form, and retain that value through
submission. A simultaneous Connections change must not silently alter an open
draft. Add generation-based stale-response rejection, actionable
provider-specific errors, and preserve all draft fields until success.

## Subsequent review-specific slices

1. Expand the implemented detail page with additional reaction choices,
   comment moderation/reporting, and deep links from notifications.
2. Add profile shelves for Journal, Reviews, Loved, and Collections.
3. Add music-native context to journal entries (first listen, relisten, live,
   mood, setting) without requiring it for a quick log.
4. Add discovery only after report/block/moderation and ranking policies are
   defined; bulk history imports should not flood follower activity.
