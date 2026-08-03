# Reviews and listening journal design

**Decision date:** 2 August 2026  
**Status:** first-class Reviews experience, Letterboxd-inspired review and ratings browsing, owner and member profile shelves, typed following activity, historical ratings, and independent track-state foundation deployed

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
| Member Reviews, Diary, and Likes surfaces | Member profile shelves for Reviews, Diary, and opt-in Loved music |
| Following activity feed | Durable, typed manual Diary and first-publication Review events |
| Review pages filter and sort authored opinions | Loaded owner reviews can be searched and scoped by Songs, Albums, or Loved, then sorted by date or rating |

The current public Letterboxd product also confirms several navigation and
interaction details that guide the next slices:

- Diary, Reviews, Ratings, Lists, Likes, Activity, and profile overview are
  distinct destinations, even though they refer to the same canonical film.
- Its composer is subject-first and permits a rating, Like, review, dated log,
  rewatch, tags, spoiler metadata, and audience to coexist without requiring
  every field.
- A review is independently addressable social content with reactions,
  comments, moderation, and later editing; it is not merely a Diary cell.
- Profile overview acts as an index into the deeper shelves and includes a
  rating distribution, recent reviews/activity, lists, favorites, tags, and
  network links.
- Search spans subjects, reviews, lists, and people. Discovery is reinforced by
  understandable popular/highly-rated/friend activity paths rather than one
  opaque recommendation feed.

These points were verified against Letterboxd's current official
[FAQ](https://letterboxd.com/about/faq/),
[Welcome guide](https://letterboxd.com/welcome/),
[apps overview](https://letterboxd.com/apps/), and
[App Store listing](https://apps.apple.com/us/app/letterboxd/id1054271011).
The conclusions about Harmony's event-noise policy and music-specific layouts
are product-design inferences, not claims about Letterboxd internals.

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
2. **Current:** owner editing for manual diary metadata and an optional link to
   the owner's opinion for the same canonical track.
3. **Current:** recent journal browsing with text search, All /
   Relistens / Linked opinions scopes, Newest / Oldest ordering, and stable
   owner-only pagination.
4. **Current backend foundation:** historical ratings can belong to individual
   Diary entries, while Listened, default rating, Loved, and Want to listen are
   independent owner/track state. A private Music shelf exposes those states
   with search, scopes, and stable pagination.
5. **Current:** a durable typed following feed and follower member profiles
   with independent Reviews, Diary, and opt-in Loved shelves. Imported provider
   history and Harmony-room playback never generate feed events.
6. **Current:** My Reviews includes an average/count/Loved summary, local
   title/artist/album/body search, Songs / Albums / Loved scopes, and Newest /
   Highest rated / Lowest rated ordering.
7. **Current:** Ratings is a full shelf in the root Reviews page, backed by
   independent current song state rather than inferred from review rows. It
   presents a half-star distribution, average, count, and canonical song links.
8. **Next:** a deliberate create-time opinion-linking interaction if the
   edit-first workflow proves too hidden, plus server-side filtered search if
   exhaustive results are required.
9. **After moderation and ranking policy:** popular/community discovery,
   shareable lists/collections, and listening statistics/year summaries.

This order emulates Letterboxd's durable separation of diary, opinion,
affinity, and social activity without claiming that Harmony's later discovery,
tags, lists, or stats already exist.

## Harmony model

| Concept | Harmony representation | Behavior |
| --- | --- | --- |
| Playing now | queue/provider playback | ephemeral; not automatically a social post |
| Listening journal | `listening_history_entries` | dated and repeatable; manual entries may carry Relisten/tags and a historical rating, while provider imports are deduplicated |
| Opinion | `music_reviews` | authored 0.5–5.0 rating/Loved snapshot and optional review text |
| Track state | `profile_track_subject_states` | authoritative private current Listened, default rating, Loved, and Want to listen state |
| Review affinity snapshot | `music_reviews.is_loved` | the Loved value submitted with that review; saving a track review also updates current track state |
| Spoiler disclosure | `music_reviews.contains_spoilers` | author-controlled metadata; clients conceal the body until the reader reveals it |
| Community reaction | `review_reactions` | another listener reacting to a published review |

The distinction between affinity and reaction is important. “Loved” describes
the review author's relationship to the music. A heart on a review describes a
reader's response to that review.

## First implementation

The fifth iOS tab has four full shelves and opens on Reviews:

- **Reviews** contains the owner's published song and album opinions.
- **Ratings** contains the owner's current song ratings independently of review
  authorship, with a ten-bucket half-star distribution.
- **Diary** contains the owner's dated listening entries.
- **Activity** contains shortcuts into the owner's journal plus
  follower-visible review activity.

The top-right **Create** menu offers **Write a review** and **Log a listen**
from every shelf. Review composition is modal so the selected shelf and scroll
position survive dismissal. The rating control supports half-star steps, and
Loved remains independent of the score.

Album ratings remain review-backed until Harmony has canonical album identity.
The Ratings shelf says so explicitly instead of merging provider snapshots by
title. This avoids presenting two provider editions as one album or one album
as two subjects. Canonical albums require an album table, provider mappings,
edition policy, track membership, and an owner album-state row analogous to
`profile_track_subject_states`.

### Activity-volume policy for music

Letterboxd's manually logged films are low-frequency enough to appear as
individual feed events. Automatic music listening can produce hundreds of
tracks per day, so Harmony does not copy that emission rule literally. Durable
activity is reserved for first-publication reviews and lists, intentional
manual Diary logs, live/eavesdrop starts, and later session summaries. Provider
history imports, automatic track transitions, rating corrections, reorders,
and audience edits stay silent. Rapid live/reaction updates will be grouped
before broader discovery ships.

### Review browsing and ratings summary

**Reviews → Reviews** now treats a member's opinions as a browsable catalog,
not a chronological text dump. Its summary reports the average of the loaded
owner reviews, total review count, and Loved count. Search folds case and
diacritics and matches subject title, artist, album, or review body. Scope is
**All**, **Songs**, **Albums**, or **Loved**; sort is **Newest**, **Highest
rated**, or **Lowest rated**, with creation time breaking rating ties.

`ReviewBrowseFilter` owns the three controls and `browseMusicReviews` remains a
pure client transformation, covered by unit tests. The current review query is
limited to 50 records, so these values and filters describe the loaded review
page rather than claiming all-time statistics. Server-keyset pagination and
exhaustive statistics remain a later slice. This limitation is stated here so
future UI copy does not misrepresent partial data.

## Implemented manual music-diary slice

### Interaction and ownership

Manual diary authoring lives in **Reviews → Diary** and the Reviews toolbar's
**Create → Log a listen** action, not in Listen.
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
signature, retaining defaults for the new trailing `p_is_relisten` and
`p_tags` inputs so existing named-parameter callers remain compatible.
Migration 028 later adds optional trailing `p_rating` without changing those
named calls.

The RPC rejects future manual timestamps, normalizes tags again on the server,
and allows Relisten/nonempty tags only when `source = 'manual'`. Harmony-room
and provider-import writes explicitly submit `false` and an empty tag array.
Manual repeats are allowed; the existing provider-import deduplication index
continues to apply only to imported provider history.

### Local edit and opinion-link slice

Each owner-visible manual row now has an accessible **Edit journal entry**
action. Harmony-room and provider-import rows remain immutable in this editor.
The track is also fixed: editing changes only Listened on, Relisten, tags,
audience, and an optional Linked opinion. Creation intentionally remains a
quick log without a Linked opinion control; the author may link it afterward.

The editor is seeded from the persisted row, including its existing link. It
shows **No linked opinion** plus only the owner's active track reviews whose
canonical track ID exactly matches the diary entry. Save calls
`updateDiaryEntry(...) -> Bool`; invalid input or a failed request leaves the
sheet and all edited values intact. A successful refresh and dismiss occur
only after server confirmation.

Manual journal rows render their calendar date without a misleading time;
imported and Harmony-room history retains full timestamps. For submission,
today maps to the current instant so it cannot be rejected as a future time,
while an earlier selected day maps to local noon to avoid crossing the chosen
calendar boundary during UTC conversion.

Migration `202608030026_edit_music_diary_entries.sql` adds nullable
`review_id` with `ON DELETE SET NULL`, so deleting an opinion unlinks the log
without deleting either record. The owner-only `update_listening_diary_entry`
RPC permits only manual entries and reuses the existing future-date and tag
rules. A non-null review must be owned by the same caller, undeleted, a track
review, and about the same track. The server compares canonical IDs when
available and falls back to provider identity for legacy rows where both sides
provide it. Passing null explicitly unlinks the opinion. RLS and read
visibility remain unchanged and independent for the two records.

The migration is deployed to the linked Supabase project. A diary entry still
never creates or updates `music_reviews`, enqueues its track, or starts
playback.

### Journal browsing and pagination slice

**Diary** now browses the owner's manual diary independently of the
follower listening-history feed. Search matches title, artist, album, or tags
after case- and diacritic-insensitive folding. The scope control offers **All**,
**Relistens**, and **Linked opinions**; ordering offers **Newest** and
**Oldest**. Equal timestamps retain their loaded order, preventing controls
from visibly reshuffling ties. A filtered empty state explains that entries
were not removed.

`JournalBrowseFilter` owns query/scope/sort and `browseJournalEntries` is a
pure transformation over pages already loaded in `journalEntries`. Search and
scope therefore describe the loaded portion, not an exhaustive server search.
When `hasMoreJournalEntries` is true, **Load older entries** requests another
page; a user may need to load older pages before an older matching listen can
appear. This distinction prevents the client from claiming complete counts or
absence while older pages remain unloaded.

Migration `202608030027_paginated_music_diary.sql` adds the auth-bound
`list_my_listening_diary` RPC and a partial
`(profile_id, played_at DESC, id DESC) WHERE source = 'manual'` index. Pages
use the `(played_at, id)` pair as a keyset cursor, so identical timestamps do
not produce gaps or duplicates. The app requests 51 rows, displays 50, and
uses the extra row only to determine whether another page exists. The RPC
accepts 1–100 rows, requires both cursor parts or neither, and returns only the
authenticated owner's manual rows under existing RLS.

Migration 027 is deployed to the linked project. Hosted smoke covers owner
isolation, keyset pagination across identical timestamps, and rejection of a
partial cursor. Filtering remains intentionally local; making text/tag filters
exhaustive would require server parameters, appropriate indexes, and product
copy that distinguishes a complete result from a loaded-page preview.

### Independent track state and historical ratings foundation

Migration `202608030028_track_subject_state.sql` is deployed. It adds an
optional half-step `rating` snapshot to manual Diary rows and introduces
`profile_track_subject_states`, keyed by owner and canonical track. That state
holds undated Listened, default rating, Loved, and Want to listen without
requiring a review. Existing active track reviews seed the initial state.
Saving a track review updates current state while old Diary and review rows
retain their own authored snapshots.

History writes mark the track Listened and clear Want to listen. A manual Diary
rating becomes the current default through a database trigger, while earlier
Diary rows preserve their own value. `set_listening_diary_rating` updates or
clears one owned manual entry; `set_my_track_subject_state` replaces the
caller's private state and rejects clearing Listened while history or an active
track review still exists. Direct client mutation is revoked and owner-only RLS
protects reads. Track review creation/editing marks Listened, clears Want to
listen, and makes the submitted rating/Loved the current track state. Album
reviews do not have a canonical track relationship and therefore do not mutate
track state.

Hosted smoke covers half-step validation, owner isolation, foreign-entry
rejection, state synchronization, independent Loved/Want-to-listen behavior,
and the guarantee that later current-state or review edits do not mutate older
Diary rating snapshots.

Migration `202608030029_atomic_diary_rating_update.sql` adds
`update_listening_diary_entry_with_rating`, keeping the older update RPC for
installed-client compatibility. The new RPC updates date, audience, Relisten,
tags, linked opinion, and nullable historical rating in one transaction. A bad
rating or incompatible review link rolls back every field.

The iOS Diary composer and editor now expose an optional **Rate this listen**
control. An unrated log remains `nil` with a disabled scale; enabling it starts
at 4.0 and uses the same half-star picker as reviews. Journal rows display only ratings actually
stored on that listen. Swift also decodes/caches the new private track state,
and the owner subject-detail UI edits Loved/Listened/Want-to-listen/current
rating without rewriting historical Diary rows.

### Owner Music shelf

Reviews → Activity now links to a dedicated **Music shelf**. It is not another
Diary list: each canonical track appears once with its current Listened, Loved,
Want-to-listen, and default-rating state. All, Loved, Want to listen, Rated,
and Listened scopes sit alongside local title/artist/album search. Rows show
artwork and compact state badges, while filtered-empty copy distinguishes “no
match in loaded pages” from an empty account.

Migration `202608030030_paginated_track_subject_states.sql` deploys the
owner-only `list_my_track_subject_states` RPC. It uses the stable
`(updated_at DESC, canonical_track_id DESC)` cursor, requires both cursor
parts, limits pages to 1–100, and is backed by a matching owner-first index.
The app requests 51 rows, displays 50, and exposes Load more when the sentinel
exists. Search and scopes intentionally apply to loaded pages, as in Diary.
Hosted smoke covers owner isolation, continuation, partial-cursor rejection,
and the page-size cap.

### Owner track detail and state invariants

Selecting a Music shelf row opens a first-class canonical-track page. Its
identity is the canonical UUID carried by `RemoteCatalogTrack`; it never
round-trips through title/artist matching. The page keeps a value-typed draft
for Listened, current rating, Loved, and Want to listen, normalizes Rating →
Listened and Listened → not Want before submission, and changes its cache only
after the server accepts the complete replacement. Failed saves retain the
draft for retry. Loaded owner Diary entries and reviews for the track appear as
separate sections so historical occurrences remain distinct from current
state.

Canonical resolution outside the page follows the same identity rule. A known
canonical UUID is authoritative; unequal known UUIDs never merge merely because
their display metadata matches. Provider identity and ISRC precede a guarded
album-and-duration fallback, preserving studio/live/remaster distinctions.

Migrations 032–034 remove all-empty state rows (including legacy rows), sync
track-review create/edit into current state, and serialize direct state,
history, and review writers with the same owner/track advisory lock. Clearing
Listened is rejected while any history or active track review still proves the
relationship; deleting a review does not roll current state backward. Direct
current-state changes never rewrite a historical Diary or review snapshot.

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

Activity and Reviews shelves now render compact `ReviewCard` summaries.
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
2. Add Collections and optional profile favorites; Reviews, Diary, and Loved
   member shelves are implemented.
3. Extend dated-log context with structured first-listen/live/setting fields
   without requiring them for a quick log.
4. Move journal search/scope filters server-side if product requirements call
   for exhaustive results across unloaded pages.
5. Add discovery only after report/block/moderation and ranking policies are
   defined; bulk history imports should not flood follower activity.

## Typed following activity and member profiles

Migration `202608030031_social_activity_and_profile_shelves.sql` makes the
social journal durable. `social_activity_events` is an append-only index of a
manual Diary log or the first publication of a Review. It stores the actor,
kind, referenced object ID, and publication cursor; the object itself remains
the source of truth. Feed reads therefore apply the object's current audience,
deletion state, accepted-follow relationship, and blocks. Making an item
private or deleting it removes it from readers immediately, while making it
visible again does not manufacture a second event.

Only intentional manual logs and reviews enter the feed. Provider imports,
Harmony-room history, historical backfills, subject-state changes, and review
edits do not create activity. This preserves Letterboxd's distinction between
recording a back catalog and deliberately publishing current activity.

The Reviews tab's **Activity** shelf now renders typed Review and Diary cards.
Actor identity navigates to a member profile with three independent shelves:
**Reviews**, **Diary**, and **Loved**. Each shelf has its own loading, error,
empty, and keyset-pagination state, keyed by profile ID so navigating between
members cannot mix results. Profile reads never populate the signed-in
owner's editable caches.

Review and Diary visibility continue to belong to each object. Loved is an
aggregate profile shelf and is separately opt-in through Connections using
`profile_social_settings.shelf_visibility`; it defaults to Only me and can be
shared with accepted followers. There is no public profile discovery surface.
