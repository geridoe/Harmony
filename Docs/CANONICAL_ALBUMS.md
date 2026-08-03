# Canonical album identity

**Status:** deployed to the linked Supabase project on 3 August 2026 and verified by the hosted smoke suite.

## Decision

Harmony treats an album as a catalog release, not a normalized title/artist
string. `canonical_albums` is the provider-independent release record and
`provider_albums` maps a provider's opaque album identifier and storefront to
that record.

An exact `(provider, provider_album_id, storefront)` mapping is authoritative.
The only automatic cross-provider merge key in this slice is a validated
12- or 13-digit UPC/EAN. Matching title, artist, artwork, release date, or track
count is never enough to merge two records. This deliberately prefers a
temporary duplicate over joining reviews for different editions.

## Tables and invariants

`canonical_albums` stores stable release metadata: title, artist, release date,
UPC/EAN, release type, track count, and HTTPS artwork. A partial unique index
enforces one canonical row per known UPC/EAN. Metadata can be enriched when a
previously empty field becomes available; provider snapshots on reviews remain
unchanged.

`provider_albums` stores provider, opaque album ID, storefront, deep link,
availability, and the evidence that created the mapping (`provider` or `upc`).
Spotify uses the `global` storefront. Apple Music uses a lowercase two-letter
storefront parsed from its URL, with `us` as the compatibility fallback for old
snapshots that did not persist storefront.

Both catalog tables are readable by signed-in users. Authenticated clients
cannot write them directly; the resolver functions are the write authority.
Ordinary authenticated calls remain provider-scoped. Only a service-role call
from trusted ingestion may submit UPC/EAN evidence, preventing a client from
forging a barcode to join unrelated albums. Service-role access also remains
available for catalog repair.

## Resolver contract

`resolve_harmony_album_v2` accepts provider identity, display metadata, optional
UPC/EAN, optional release metadata, and an explicit storefront. Its order is:

1. Validate authentication, identity, storefront, URLs, and metadata bounds.
2. Serialize work for the exact provider identity.
3. Return its existing canonical album if mapped, enriching only empty fields.
4. If a UPC/EAN is supplied, require service-role attestation and reject
   evidence that conflicts with the mapped album or a different canonical row.
5. For a new provider identity, reuse the canonical row with that UPC/EAN.
6. Otherwise create a new canonical row. No fuzzy metadata match is attempted.

Authenticated callers may use `resolve_harmony_album_v2` for richer non-identity
metadata, but a non-null UPC/EAN fails with `album_upc_attestation_required`.
This check runs before any identity or catalog mutation, so forged evidence
cannot poison an existing mapping.

`resolve_harmony_album` is the compatibility wrapper for existing snapshot
callers. It infers storefront and supplies no UPC/EAN, so it can only reuse the
same provider identity. Provider IDs remain case-sensitive and opaque.

A later authoritative catalog job may consolidate duplicates after new UPC or
label evidence arrives. Migration 038 intentionally raises
`canonical_album_identity_conflict` instead of silently moving an already
mapped provider album and its reviews.

## Existing review preservation

Migration 038 adds nullable `music_reviews.canonical_album_id` with
`ON DELETE RESTRICT`. Backfill includes public, private, blocked, duplicate,
and soft-deleted album reviews. Rows are grouped only by their exact legacy
provider identity and inferred storefront. Review IDs, authors, timestamps,
rating/body, visibility, artwork/deep-link snapshots, comments, reactions,
notifications, and activity events are not rewritten.

Malformed legacy rows that lack provider identity or title remain nullable and
valid through the transitional constraint. They can be repaired later without
blocking deployment or deleting authored work. New album reviews must provide
either a canonical album ID or enough provider identity to resolve one.

## Review write and read contracts

Migration 038 replaces the installed 13-argument `create_music_review` RPC
with one 19-argument signature. Its original argument names and order are
unchanged and all six album arguments are appended with defaults, preserving
existing named PostgREST callers and track behavior. New optional fields are:

- `p_canonical_album_id`
- `p_provider_storefront`
- `p_album_upc`
- `p_album_release_date`
- `p_album_total_tracks`
- `p_album_type`

Provider-based album creation resolves the canonical identity server-side. If
the caller also supplies a canonical ID, the mapping must belong to it.
Canonical-only creation selects a deterministic preferred provider snapshot
when one exists. Track reviews reject canonical album IDs and continue to use
`canonical_track_id` exactly as before.

`get_canonical_album` returns catalog metadata. `list_canonical_album_reviews`
returns a descending keyset page of visible, non-deleted reviews; it is a
security-invoker function, so existing review RLS remains the privacy authority.

## Current limitations and follow-up

- Spotify and Apple catalog adapters must request UPC/EAN before they can
  safely bridge providers. Existing iOS album search currently lacks this
  enrichment, so it will resolve by provider identity until adapted.
- Apple storefront was not retained in old reviews. The `us` fallback is stable
  and compatible but may need a repair job when authoritative storefront data
  becomes available.
- Canonical albums do not yet model editions, release groups, or track
  membership. Migration 039 adds independent owner-level Listened, Rating,
  Loved, and Want-to-listen state without changing release identity; see
  `ALBUM_SUBJECT_STATE.md`.
- A privileged consolidation RPC/job is intentionally absent. Its audit and
  review reassignment behavior should be designed before resolving conflicts.

## Verification contract

The hosted smoke script now asserts legacy payload compatibility, automatic
canonical linking, exact provider idempotency, forged and malformed UPC
rejection, no title-only cross-provider merge, canonical-only review creation,
visibility-filtered album review reads, and unchanged track review paths.
The trusted UPC merge path requires a service-role database test and must never
put that credential in the iOS app or hosted smoke environment. The hosted
suite passed against migration 038 on 3 August 2026, including the exact nested
canonical-album relation selected by the Swift repository.
