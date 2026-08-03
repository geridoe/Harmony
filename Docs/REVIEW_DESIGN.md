# Reviews and listening journal design

**Decision date:** 2 August 2026  
**Status:** dedicated reviews and manual music-diary entry implemented; broader discovery work remains

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

### Evidence from the actual Letterboxd product

This design was checked against Letterboxd's current official product pages,
not secondary mockups. Its [FAQ](https://letterboxd.com/about/faq/) separates
marking a film watched from logging a dated Diary entry; logging may include an
optional review, rating, Like, and tags. The same FAQ says Like and rating can
be used together or independently, describes rewatch entries, spoiler-tagged
reviews, follower activity, review comments, and member Likes/Profile pages.
Letterboxd's [official apps page](https://letterboxd.com/apps/) presents Explore,
Diary, and Social as separate jobs: members keep a diary while a following
feed shows what friends watch, like, list, and discuss. The current
[App Store listing](https://apps.apple.com/us/app/letterboxd/id1054271011)
confirms dated logs with ratings/reviews/tags, review comments, lists, member
profiles with Reviews and Diary entries, following activity, and statistics.

The product pattern Harmony transfers is therefore:

| Verified Letterboxd pattern | Harmony adaptation |
| --- | --- |
| Film page and review subject | Canonical track or provider-identified album |
| Ten-position half-star rating scale | 0.5–5.0 music rating |
| Like independent of rating | Loved affinity independent of score and social review reactions |
| Dated Diary log, optionally reviewed | Dated listen distinct from the current opinion |
| Rewatch flag | Relisten context on an individual manual listen |
| Optional review, tags, and spoiler metadata | Reviews keep spoiler metadata; manual listens accept music-context tags |
| Dedicated review detail with likes/comments | Review detail with reaction and comment thread |
| Member Reviews, Diary, and Likes surfaces | Future profile shelves for Reviews, Journal, and Loved music |
| Following activity feed | Follower-visible review activity now; broader typed activity later |

The information hierarchy matters as much as the fields. Harmony's Reviews
experience remains the fifth root tab, with its own feed, composer, and review
detail navigation. It must not regress into a small Diary section inside the
Listen tab. Listen remains about people, notifications, eavesdropping, and
listening history; Reviews is where authored music opinions and their
conversation live.

### Staged adaptation roadmap

Only the first stage should be described as implemented:

1. **Current:** first-class Reviews tab, follower review feed, song/album
   composer, rating/Loved/spoiler/audience controls, compact cards, review
   detail with reactions/comments, and manual dated track logs with Relisten,
   tags, and per-entry audience.
2. **Next:** editing manual diary entries, optional linkage between a listen
   and an opinion, and richer Journal browsing/filtering.
3. **Later:** profile Reviews/Journal/Loved shelves and a richer typed following
   activity feed. Bulk provider-history imports must not flood that feed.
4. **After moderation and ranking policy:** popular/community discovery,
   shareable lists/collections, and listening statistics/year summaries.

This order emulates Letterboxd's durable separation of diary, opinion,
affinity, and social activity without claiming that Harmony's later discovery,
tags, lists, or stats already exist.

## Harmony model

| Concept | Harmony representation | Behavior |
| --- | --- | --- |
| Playing now | queue/provider playback | ephemeral; not automatically a social post |
| Listening journal | `listening_history_entries` | dated and repeatable; manual entries may carry Relisten/tags, while provider imports are deduplicated |
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
  reviews. **Log a listen** creates a manual track entry with a selected date,
  Relisten flag, tags, and audience. The copy explicitly explains that logs
  and opinions are independent.

## Implemented manual music-diary slice

### Interaction and ownership

Manual diary authoring lives in **Reviews → My journal**, not in Listen.
Listen remains a read-only social/history surface. **Log a listen** opens a
track-only composer with:

1. a song selected through the isolated Reviews catalog search;
2. **Listened on**, limited by the client to today or an earlier date;
3. an independent **Relisten** flag;
4. comma-separated tags; and
5. an explicit Only me/Followers audience copied from the history default when
   the composer opens.

`DiaryEntryDraft` owns all pending values. It trims and lowercases tags,
removes blanks, and stably deduplicates repeated values before submission.
The client and database both limit entries to ten tags of at most thirty
characters each. Save stays disabled without a song or while tag validation
fails. A failed `createDiaryEntry(...) -> Bool` keeps the sheet and authored
draft intact; only confirmed persistence dismisses it.

Quick logging the current track remains available as a separate action. It is
intentionally low friction and does not silently infer Relisten or tags.

### Persistence and invariants

Migration `202608020025_music_diary_entries.sql` extends
`listening_history_entries` with `is_relisten` and `tags`. The selected calendar
date is stored in the existing `played_at` timestamp; no second diary-date
column exists. The migration replaces `record_listening_history` with one
eight-parameter signature, retaining defaults for the new trailing
`p_is_relisten` and `p_tags` inputs so existing named-parameter callers remain
compatible.

The RPC rejects future manual timestamps, normalizes tags again on the server,
and allows Relisten/nonempty tags only when `source = 'manual'`. Harmony-room
and provider-import writes explicitly submit `false` and an empty tag array.
Manual repeats are allowed; the existing provider-import deduplication index
continues to apply only to imported provider history.

This slice is create/delete only. Editing a dated log and linking it to an
existing review are deliberately follow-up work. A diary entry does not create
or update `music_reviews`, enqueue its track, or start playback.

Album review creation remains available on Spotify/Apple catalog results in
Add music. The server migration `202608020023_review_affinity.sql` adds the
affinity field and updates owner-authorized create/edit RPCs.

The Reviews composer has its own subject-picker sheet. It selects a song or
album without adding it to a party queue, starting playback, or writing a
listening-history entry. Picker searches own their results independently of
Add music, present separate Songs and Albums modes, and expose an explicit
creation audience that is captured in the review draft.

## Implemented subject-picker slice

### Goal and interaction

The composer no longer requires a user to add music to a party queue merely to
write an opinion. **Choose a song or album** opens `ReviewSubjectPicker`, a
sheet with a debounced search field and a Songs/Albums segmented control:

1. Search only connected catalogs after a short debounce, keeping the results
   local to this picker.
2. Songs displays selectable `HarmonyTrack` rows.
3. Albums derives `ReviewableAlbum` rows from the returned tracks and
   deduplicates by `(provider, provider album ID)`. Title or artist differences
   do not split the same provider album, while identical IDs from different
   providers remain distinct records.
4. A selected album preserves its provider, provider album ID, title, artist,
   artwork, and safe deep link.
5. The author sets half-star rating, optional body, Loved, spoiler disclosure,
   and audience, then saves.
   Selecting media never adds it to the room queue, starts playback, or creates
   a listening-journal entry.

### Implemented state ownership and cancellation

The implemented ownership is:

| Owner | State / responsibility |
| --- | --- |
| `ReviewsView` | picker presentation, one `ReviewDraft`, and edit form state |
| `ReviewSubjectPicker` | local query, selected Songs/Albums mode, debounce task, and album derivation |
| `HarmonySessionStore` | provider connection state plus purpose-keyed results/loading/message and request tokens for `.addMusic` and `.reviews` |
| Repository/providers | Spotify Edge Function or future MusicKit search, then canonical/provider resolution |

`ReviewDraftSubject` remains a small enum:

```text
track(HarmonyTrack) | album(ReviewableAlbum)
```

Selecting a subject returns it through a closure and dismisses the picker. It
performs no database write. The picker calls
`searchCatalog(query:purpose: .reviews)` and reads only
`catalogSearchState(for: .reviews)`. Add music continues through `.addMusic`
and its compatibility accessors. Each purpose has an independent request UUID,
so an older provider response is discarded without changing the other
surface's results, loading indicator, or message.

### Persistence routing

The media picker needs no new table or migration. The existing endpoints are
the authority:

| Draft subject | Store/repository call | Server identity |
| --- | --- | --- |
| Track | `publishTrackReview` → `createTrackReview` → `create_music_review` | `canonical_track_id`; repository resolves it if necessary |
| Album | `publishAlbumReview` → `createAlbumReview` → `create_music_review` | provider + provider album ID plus validated title/artwork/deep link |

`ReviewsView` performs the small subject switch and calls the
appropriate store method. The store methods apply the existing
`isPublishingMusicReview` guard, refresh review lists on success, and return
`Bool`. The composer replaces its draft only when that result is true, so a
failed request preserves subject, rating, body, Loved, spoiler disclosure, and
audience. It does not dismiss the Reviews tab or discard picker context after
failure.

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

For a newly created review, the composer seeds `ReviewDraft.visibility` from
`reviewsSocialVisibility` when the draft opens, then exposes Only me/Followers
in the creation form. Submission uses that draft value—not a later read of the
global profile setting—so changing Social privacy while the composer is open
cannot silently widen or narrow the review's audience. Existing reviews expose
the same owner-only edit audience picker. In all cases, saved review visibility
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
| Spotify reauthorization or transient error | display the picker-local provider message and retain the current Reviews composer and search context |
| Album lacks required provider metadata | no album button is offered when `reviewableAlbum` is absent; server validation remains final authority |
| Canonical resolution/RPC/RLS error | store returns `false`, keeps every `ReviewDraft` field, and supplies `collaborationMessage` |
| Success | refresh lists and reset the creation draft from the current default audience |

### Tests for the implemented slice

| Layer | Required coverage |
| --- | --- |
| Unit | search-state isolation; album identity dedupe; audience snapshot; half-star bounds; Loved independence; `Bool` failure preserves every draft field; subject selection has no queue/history mutation |
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

## Picker and creation-draft invariants

`ReviewSubjectPicker` owns local query, result mode, and debounce cancellation.
`HarmonySessionStore` owns `CatalogSearchState` and a request token separately
for `.addMusic` and `.reviews`; a search or reset changes only its requested
purpose. That prevents the two surfaces from racing while keeping provider
connection and merge logic centralized. The Albums mode deduplicates by
provider plus provider album ID and only permits provider-identified albums
with a non-empty title.

Creation state is represented by one `ReviewDraft` value:

```text
subject: track(HarmonyTrack) | album(ReviewableAlbum)
rating: Double                 // 0.5...5.0, half-star increment
body: String
isLoved: Bool
visibility: SocialVisibilityOption
```

The draft snapshots `reviewsSocialVisibility` when the composer opens,
displays Only me/Followers in the creation form, and retains that value through
submission. A simultaneous Connections change must not silently alter an open
draft. Provider-specific failures retain the existing local search results and
the entire authored draft. Only confirmed publication resets it.

## Subsequent review-specific slices

1. Expand the implemented detail page with additional reaction choices,
   comment moderation/reporting, and deep links from notifications.
2. Add profile shelves for Journal, Reviews, Loved, and Collections.
3. Extend the implemented dated-log context with edit support, optional review
   linkage, and structured first-listen/live/setting fields without requiring
   them for a quick log.
4. Add discovery only after report/block/moderation and ranking policies are
   defined; bulk history imports should not flood follower activity.
