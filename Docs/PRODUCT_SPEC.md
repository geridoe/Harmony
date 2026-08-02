# Harmony MVP Specification

## Goal
Harmony owns a collaborative, provider-neutral music queue. A Conductor hosts a session; members add and arrange tracks; each person plays through their own Apple Music or Spotify connection. Harmony never streams or rebroadcasts audio.

## First milestone
- Create or join one live session, see members and a shared queue.
- Add, remove, and reorder canonical tracks locally.
- Show independent Apple Music and Spotify availability for every track.
- Use mock provider connections until MusicKit and Spotify OAuth/App Remote credentials are configured.

## Architecture
The SwiftUI feature layer sends commands to `HarmonySessionStore`. The store is the optimistic local state boundary and will later call a `SessionRepository` backed by Supabase Realtime. The domain uses canonical tracks plus provider mappings; provider adapters resolve and play locally, never as the source of truth.

The backend phase stores sessions, memberships, canonical tracks, provider mappings, queue items, and an append-only queue-event log. Every mutation supplies an expected queue revision; the server validates membership/role, appends the event atomically, updates the materialized queue, and broadcasts the new revision.

## Delivery sequence
1. Local store, queue UX, provider mapping states, and unit tests.
2. Supabase auth, persistence, realtime events, invite links, and revision conflicts.
3. Apple Music MusicKit adapter and Spotify OAuth/App Remote adapter on physical devices.
4. Push notifications, resilience, and device-test coverage.

## Validation
Use unit tests for queue operations; use XcodeBuildMCP to compile/test simulator UI; use real devices and valid service accounts for all MusicKit/Spotify authorization and playback checks.
