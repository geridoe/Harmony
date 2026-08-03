# Owner album state and visible review aggregates

**Status:** migrations 039–040 deployed to the linked Harmony Supabase project
on 2026-08-03; linked lint and the complete hosted smoke suite pass.

## Product boundary

`profile_album_subject_states` is the current relationship between one Harmony
profile and one canonical album release. It supports the Letterboxd-style
actions that do not require a written review:

- **Listened** — the owner considers the release heard.
- **Rating** — the owner's current/default score from 0.5 through 5.0 in
  half-star steps.
- **Loved** — an affinity flag independent of score.
- **Want to listen** — a watchlist-style intent for an unlistened release.

Current state and historical review snapshots are separate records, but they
are not unrelated. Saving an active canonical album review marks the album
Listened, clears Want to listen, and makes that review's rating and Loved value
the owner's current defaults. Editing the review's rating or Loved value does
the same. The authored values on older reviews remain unchanged when current
state or a different review changes, and soft-deleting a review never rolls
current state backward. Track playback/history still does not infer that an
entire album was heard.

This follows the actual Letterboxd distinction documented in its
[FAQ](https://letterboxd.com/about/faq/): saving a rating in a diary entry or
review updates the film's default rating, while ratings attached to older
entries remain snapshots. The same FAQ says a watchlist item is automatically
removed when it is watched, logged, reviewed, or rated. Letterboxd's
[Welcome guide](https://letterboxd.com/welcome/) likewise describes moving a
title out of Watchlist when it is watched or logged. Harmony maps those rules
to Listened/default rating/Loved/Want to listen without copying Letterboxd's
film-specific presentation.

Migration 040 backfills the newest active canonical album review for each
owner/album pair, ordered by its last update and then stable creation/id
tie-breakers. This produces the state the review trigger would have created if
it had existed when those reviews were saved.

## Table invariants

The primary key is `(profile_id, canonical_album_id)`, so one account has at
most one current private state row for a release.

Database constraints enforce the following independently of client behavior:

1. A rating is null or a half-star value from 0.5 to 5.0.
2. A rating implies Listened.
3. Listened and Want to listen cannot both be true.
4. An on-disk row must represent at least one relationship. An entirely empty
   state is deleted rather than retained as shelf debris.
5. Profile deletion and canonical-album deletion cascade to state. Canonical
   album review rows still use their separate restrictive identity contract.

`created_at` records when the owner first established the surviving
relationship. `updated_at` is maintained by the shared trigger and supplies
the stable shelf ordering. A generic owner/order index supports all shelves, a
partial owner/rating index supports the common Ratings shelf, and album-side
indexes support future owner-state maintenance.

## Authorization and write authority

RLS permits authenticated users to select only rows whose `profile_id` equals
`auth.uid()`. Authenticated roles receive no direct INSERT, UPDATE, or DELETE
grant and there is no client write policy.

`set_my_album_subject_state` is the only direct mobile-client writer. The
database review trigger is a second internal writer. The setter:

1. requires an authenticated actor;
2. verifies that the canonical album exists;
3. validates the half-star score;
4. derives `profile_id` exclusively from `auth.uid()`;
5. normalizes Rating to Listened and Listened to not-Want-to-listen;
6. serializes mutations for the owner/album pair with an advisory transaction
   lock; and
7. rejects clearing Listened while an active canonical album review still
   proves the relationship; and
8. deletes the row when all submitted relationships are clear.

The clear response retains the normal state response shape, even if no row
existed, while the following read correctly returns no state. No caller can
write a state on behalf of a different profile by changing request JSON.

`sync_album_subject_state_from_review` runs after album-review insertion and
after rating, Loved, or deletion-marker updates. It ignores non-album,
non-canonical, and deleted review rows. For an active canonical review it uses
the same owner/album advisory lock as the setter, then atomically sets
Listened=true, the optional review rating as `default_rating`, the review's `is_loved`,
and Want-to-listen=false. A deletion invokes no rollback; the last established
current state survives.

## Owner shelf pagination

`list_my_album_subject_states` uses descending keyset pagination on
`(updated_at, canonical_album_id)`. Both cursor values must be supplied
together and page size is bounded to 1–100.

Its optional trailing `p_scope` defaults to `all` and accepts:

| Scope | Server predicate |
| --- | --- |
| `all` | every non-empty owner state |
| `rated` | `default_rating is not null` |
| `listened` | `has_listened` |
| `loved` | `is_loved` |
| `want_to_listen` | `want_to_listen` |

Filtering occurs in SQL before `LIMIT`. This matters for the first-class
Ratings page: it receives a full page of rated albums rather than an underfilled
client-side projection of an unfiltered state page. Returned rows can select
their `canonical_albums` foreign relation for title, artist, artwork, release
metadata, and provider mappings.

## Album-detail aggregate contract

Individual rows remain owner-private and never contribute to another viewer's
summary. Two authenticated RPCs run with invoker authority over the existing
review RLS, exposing only album reviews the caller is allowed to see:

Before aggregating, each RPC keeps only the newest active caller-visible review
per profile, ordered by last update with stable creation/id tie-breakers. One
member therefore contributes at most one current rating even when their older
review snapshots remain addressable. A private newer review invisible to the
caller does not suppress an older review that caller is allowed to see.

`get_canonical_album_state_aggregate` returns exactly one row for an existing
canonical album:

```text
canonical_album_id
rating_count
average_rating          nullable when no ratings exist, rounded to 2 decimals
listened_count          distinct visible reviewers (compatibility field)
loved_count             visible reviews marked Loved
want_to_listen_count    always zero; private intent is never aggregated
```

`list_canonical_album_rating_distribution` returns ten ordered rows from 0.5
through 5.0, each with `rating` and `rating_count`. Empty buckets are included
with zero so every client renders the same histogram. Review visibility,
follower acceptance, and blocks are enforced by `music_reviews` RLS before the
aggregate is calculated. Neither function returns profile identifiers,
timestamps, or private owner-state flags. Both reject unauthenticated and
nonexistent-album calls.

## Verification contract

The hosted smoke extension covers:

- review creation and rating/Loved edits synchronize current album state;
- active reviews block clearing Listened, while deletion preserves the last
  established current state and permits a later explicit clear;
- half-star validation and Listened/Want normalization;
- owner-only table reads and owner-only shelf pages;
- nested `canonical_albums` selection used by Swift DTOs;
- two-page keyset traversal of the filtered Ratings shelf;
- Want-to-listen filtering and invalid cursor/scope rejection;
- state changes do not rewrite an existing review rating or Loved snapshot;
- caller-visible review aggregation without owner-state leakage;
- newest-visible-review-per-profile de-duplication in aggregate and histogram;
- one-row aggregate values and all ten histogram buckets; and
- deletion and read-after-clear of an empty state.

The iOS integration adds an album scope to Ratings and a first-class canonical
album page with owner state, provider actions, visible-review statistics, and
paginated review cards.
