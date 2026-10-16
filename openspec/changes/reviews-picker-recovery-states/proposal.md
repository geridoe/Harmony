# Proposal

## Why

The Reviews subject picker only shows a single footnote message line for all
catalog-search outcomes. When no provider is connected, a provider search
fails, or a rate limit expires, users get the same thin gray line and no
path forward, so a transient error looks like a dead end.

## What Changes

- Introduce distinct picker states for: no connected provider, connected-but-
  searching, per-provider failure with retry, and empty results per mode
  (songs vs albums).
- Each failure state gets an explicit recovery action: open Connections for
  the missing-provider case, retry the failed search for the failure case.
- Album mode keeps its existing deduplication and gains an explicit empty
  message distinct from failure.
- No change to search behavior, ranking, or canonicalization; this is purely
  the picker's state presentation and recovery affordances.

## Capabilities

### New Capabilities

- `reviews-subject-picker`: Catalog-search state presentation and recovery
  affordances inside the Reviews subject picker sheet.

### Modified Capabilities


## Impact

- `Harmony/ContentView.swift` (`ReviewSubjectPicker`): state rendering and
  recovery actions.
- `Harmony/Song.swift` (`searchCatalog`, `CatalogSearchState`): may need to
  expose per-provider failure detail the picker can render distinctly.
- No server, schema, or Edge Function changes.
