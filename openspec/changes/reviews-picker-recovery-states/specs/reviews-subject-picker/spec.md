# Spec Delta

## Purpose

Define how the Reviews subject picker communicates catalog-search state and
offers recovery when the connected catalogs cannot serve a query.

## ADDED Requirements

### Requirement: Idle-with-no-provider guidance
The picker SHALL display an explicit no-provider state with guidance to
connect a music service when a search is requested while no catalog provider
is connected.

#### Scenario: Search without any connection
- **WHEN** the user submits a query while neither Spotify nor Apple Music is connected
- **THEN** the picker shows a no-provider message, local-library matches still appear, and a button opens the Connections area

### Requirement: Per-provider failure detail
The picker SHALL distinguish which connected provider failed when a search
returns partial or failed results, and SHALL offer a retry action for that
failed search.

#### Scenario: Spotify search fails
- **WHEN** Apple Music returns results but Spotify search fails
- **THEN** the picker renders available results plus a message naming Spotify and shows a retry control

#### Scenario: Retry after failure
- **WHEN** the user activates retry after a provider failure
- **THEN** the picker re-runs the same query against all connected providers

### Requirement: Mode-specific empty results
The picker SHALL show a mode-specific empty state when a connected-provider
search succeeds but returns no results for the selected media type, distinct
from failure messaging.

#### Scenario: Album search with no matches
- **WHEN** a query matches no albums but connected providers responded successfully
- **THEN** the picker shows a no-albums message and no retry control

#### Scenario: Song search with no matches
- **WHEN** a query matches no songs and connected providers responded successfully
- **THEN** the picker shows a no-songs message and no retry control
