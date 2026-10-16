# Design

## Context

`CatalogSearchState` already carries a single optional `message`. The store
builds it in `searchCatalog` by joining per-provider failures into one string.
The picker (`ReviewSubjectPicker`) renders `message` as one footnote and has
no retry affordance; retry exists only for the composer's existing-review
lookup, a different concern.

## Goals / Non-Goals

**Goals:**
- Expose provider-attributed failure detail to the picker without string parsing.
- One retry path that reuses the existing request-ID deduplication.
- Connections shortcut only in the no-provider case.

**Non-Goals:**
- Changing search ranking, merging, or canonicalization.
- Adding provider connection flows inside the picker.
- Touching the add-music picker's identical-but-separate state rendering.

## Decisions

**Structured failures over message parsing.** Extend `CatalogSearchState`
with `failures: [CatalogSearchFailure]` (provider + localized description),
derived from the same `failures` array `searchCatalog` already collects.
Alternative: keep one joined string and regex it in the view — rejected as
brittle and locale-sensitive.

**Retry via store, not view-local state.** The picker calls
`store.searchCatalog(query:purpose:)` again. The store's existing
`catalogSearchRequestIDs` guard already prevents stale responses.

**Connections shortcut as environment-dismiss + tab hint.** Dismiss the
sheet and surface a concise path hint rather than deep-linking into a
Connections subroute from a modal.

## Risks / Trade-offs

- [Apple provider errors may lack user-actionable detail] → Keep existing
  localized text as the failure body; provider attribution is the addition.
- [State struct grows fields] → `CatalogSearchState` stays a value type;
  Equatable still holds, no persistence involved.
