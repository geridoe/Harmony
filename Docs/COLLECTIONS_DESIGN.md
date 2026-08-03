# Music lists and collections design

**Decision date:** 3 August 2026  
**Status:** migrations 036–037 deployed; hosted contract smoke, Swift repository/store, dedicated iOS index/editor/detail, profile/activity integration, and Add-to-list entry points implemented

## Product decision

Harmony will adapt Letterboxd's curated Lists as owner-authored music
collections. A list may contain ordered songs, be ranked or unranked, include a
description, tags, and per-entry notes, and be visible only to its owner or to
accepted followers. Followers may like and comment on a visible list.

This is intentionally separate from **Want to listen**. Want to listen is the
single-toggle watchlist equivalent and may clear when a track becomes Listened.
Curated list membership is expressive authored content and never changes
Listened, Loved, rating, Diary, queue, playback, or provider state.

The behavior is based on Letterboxd's current official
[FAQ](https://letterboxd.com/about/faq/) and
[Lists directory](https://letterboxd.com/lists/): lists are distinct from the
watchlist, may be public or private, may be ranked, support reordering and
entry notes, and have likes and comments. Harmony adopts the information model,
not Letterboxd's branding or film-specific presentation.

## Navigation decision

Harmony already has five primary iPhone tabs. Adding a sixth would move a
destination into iOS's More tab and weaken both Reviews and Lists. Lists are
therefore implemented as a dedicated `MusicListsView` with its own navigation
title, index, detail, and editor, reached in one tap from **Reviews → Activity
→ Lists**.

Additional entry points will be:

- **Reviews → Create → Create a list**;
- a member profile's **Lists** shelf;
- a first-publication card in following Activity;
- **Add to list** on canonical track detail and catalog results.

No list action is placed in Listen. That tab remains for people, notifications,
live eavesdropping, and history.

## MVP subject decision

The first schema uses canonical tracks only. Album reviews currently rely on a
provider-specific snapshot because Harmony does not yet have a canonical album
entity. Mixing that snapshot polymorphism into ordered-list authority would
make deduplication and cross-provider opening ambiguous. Album lists follow
after canonical albums exist or after a separately reviewed snapshot policy.

This is a deliberate narrowing from Letterboxd parity, not an accidental data
limitation. The UI will say **Add songs** during the track-only stage.

## Data model

### `music_lists`

| Column | Contract |
| --- | --- |
| `id` | UUID primary key |
| `owner_id` | profile owner; account deletion cascades |
| `title` | trimmed, 1–120 characters |
| `description` | optional prose represented by an empty string; max 5,000 characters |
| `tags` | normalized unique lowercase values; at most 10, 30 characters each |
| `is_ranked` | controls whether positions are presented as ranks; never discards order |
| `visibility` | private by default; current UI offers private or followers |
| `entries_revision` | optimistic-concurrency authority for ordered entry mutations |
| timestamps / `deleted_at` | updated-at ordering and soft deletion |

### `music_list_entries`

| Column | Contract |
| --- | --- |
| `id` | UUID primary key |
| `list_id` | parent list; parent deletion cascades |
| `canonical_track_id` | durable track identity; canonical deletion is restricted while referenced |
| `position` | contiguous positive integer for ranked and unranked lists |
| `note` | optional per-entry prose; max 1,000 characters |
| timestamps | authorship and editing audit |

Each canonical track appears at most once per list. `(list_id, position)` is a
named deferrable unique constraint so a transaction may swap/rewrite positions
and validate the final contiguous order at commit.

### Engagement

- `music_list_likes(list_id, profile_id, created_at)` uses an idempotent set
  operation, not a race-prone toggle.
- `music_list_comments` stores author, trimmed body, timestamps, and soft
  deletion. Comment authors may delete their own comment even after losing
  visibility; the list owner may moderate comments on their list.

## Write authority and concurrency

Authenticated clients receive no direct insert/update/delete grants. Security-
definer RPCs validate `auth.uid()`, ownership, bounds, block state, and current
visibility.

Entry mutations lock the list row and compare `entries_revision`. Add, remove,
note update, and reorder each increment the revision exactly once. Reorder
accepts an exact, duplicate-free permutation of current entry IDs. A stale
revision rejects atomically as HTTP 409 with stable detail
`music_list_revision_conflict`; the client refreshes
and lets the owner reapply their draft. Remove compacts later positions within
the same transaction. The initial cap is 1,000 entries per list.

Migration 036 initially used SQLSTATE `40001`, which is semantically a
serialization failure. Hosted verification showed Supabase retrying that
deliberate rejection until its gateway returned a plain-text timeout. Migration
037 remaps only these authored revision rejections to PostgREST's non-retryable
`PT409`; transaction rollback and conflict detection are unchanged.

The editor retains one value-typed draft containing list metadata and ordered
entries. Nothing is committed to the store cache until one complete backend
save succeeds; errors keep every title, note, selection, and ordering choice.

## Privacy and RLS

Parent visibility is the authority for every child object:

- the owner can always read a nondeleted list;
- accepted followers can read follower-visible lists;
- either-direction blocking hides the list, entries, likes, comments, and
  engagement contributed by the blocked account;
- private lists and child counts cannot leak through direct table reads or
  summary RPCs.

`can_view_music_list(list_id)` centralizes the parent check. Child SELECT
policies call it, and interaction RPCs repeat visibility/block validation at
write time. Profile list pagination uses the paired `(updated_at, id)` keyset
cursor and `can_view_social`; it must not add a follower-only precondition that
would later break signed-in public discovery.

## Social behavior

Publishing a list to followers creates one durable `list_published` activity
event. Private creation emits none. The first private-to-followers transition
emits once; edits, reorders, likes, comments, unpublishing, and republishing do
not create additional feed events. Current object visibility dynamically hides
the event when a list becomes private, is deleted, or is blocked.

Likes and comments notify the list owner unless self-authored. Like
notifications are unique per actor/list/recipient so unlike/re-like cannot
spam. Realtime publication includes list parents, entries, likes, and comments,
with RLS remaining the visibility authority.

## UI contract

- **Index:** artwork mosaic, title, entry count, updated date, ranked/private
  badges, short description/tags, create action, pagination and empty states.
- **Editor:** title, description, tags, Ranked toggle, audience, Add songs,
  reorder/delete, and optional per-song note.
- **Detail:** author link, metadata, ordered tracks, rank numbers only when
  ranked, notes, provider-open action, likes, comments, and owner Edit/Delete.
- **Add to list:** chooses an existing owner list or creates a new one without
  queueing, playing, logging, or rating the song.

## Delivery order

1. **Implemented:** schema, constraints, RLS, owner CRUD, revision-safe ordering,
   activity/notifications, engagement summary, and Realtime publication.
2. **Implemented:** Swift DTO/repository/store layer with isolated draft/search
   tests and revision-conflict recovery.
3. **Implemented:** dedicated owner Lists index, complete atomic editor, catalog
   picker, detail, likes, comments, and moderation.
4. **Implemented:** member profile shelf and typed following activity.
5. **Implemented:** Add-to-list actions on canonical song detail and catalog
   search, plus list likes/comments, notifications, and typed activity.
   Physical-iPhone visual polish remains.
6. **Later:** canonical album identity followed by mixed song/album lists.

## Required verification

Tests cover private/follower/block visibility; rejected direct DML; title,
tag, note, and size bounds; duplicate tracks; contiguous add/remove; ranked
toggle order preservation; exact-permutation reorder; concurrent stale-
revision rejection; idempotent likes; comment moderation; first-publication
event idempotence; tied-cursor pagination; child-object privacy; Realtime; and
the guarantee that list membership has no queue/history/status/playback side
effects.
