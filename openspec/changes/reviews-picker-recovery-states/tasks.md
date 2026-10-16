# Tasks

## 1. Store model

- [x] 1.1 Add `CatalogSearchFailure` (provider + description) and `failures` to `CatalogSearchState`
- [x] 1.2 Populate `failures` in `searchCatalog`; keep joined `message` for existing consumers
- [x] 1.3 Add no-provider failure variant distinct from per-provider failures

## 2. Picker UI

- [x] 2.1 Render provider-attributed failure rows with a shared retry control
- [x] 2.2 Replace generic empty-album text with mode-specific empty state
- [x] 2.3 Add Connections-guidance state with dismiss action for the no-provider case

## 3. Verification

- [x] 3.1 Unit tests: failure propagation for spotify/apple/no-provider paths
- [x] 3.2 UI test: picker failure shows retry; retry re-triggers search
- [x] 3.3 Full simulator unit + targeted UI test run
