# Harmony

Harmony is an iOS social music app built around two ideas:

1. a provider-agnostic collaborative queue for parties and live sessions; and
2. a durable music network for live listening, follows, diaries, ratings,
   reviews, and curated lists.

Harmony stores canonical music intent and social data. Spotify or Apple Music
remains responsible for licensed playback on each listener's own account and
device; Harmony never rebroadcasts audio.

Eavesdrop's target experience is a read-only remote listen-along to an
opted-in followed member. Each follower plays on their own provider/device;
Harmony supplies only canonical identity and an ephemeral server-anchored
timeline for late join and bounded drift correction. Recently played remains
independent playback from the beginning. The deployed foundation currently
provides live cards, cross-provider resolution, and conversation identity while
the position-aware path is implemented.

## Current product surfaces

| iOS destination | Responsibility |
| --- | --- |
| Session | Conductor/collaborator room, permission-aware shared queue ordering, playback intent |
| Add music | Connected-catalog search and queue insertion |
| Connections | Spotify/Apple setup, profile, consent, social privacy |
| Listen | follows, notifications, Eavesdrop, history, Diary, Activity, Music shelf, and Lists routes |
| Reviews | first-class Following, My Reviews, Ratings, and review composition |

The Reviews architecture is intentionally Letterboxd-inspired without copying
its film-specific presentation. Current rating, Loved state, a dated listen,
and a written review are separate records. Reviews and Lists are addressable
social objects with comments/reactions; automatic provider plays are not
broadcast into followers' feeds one song at a time.

## Architecture

```text
SwiftUI views
  -> HarmonySessionStore (@MainActor presentation/cache authority)
    -> HarmonyCollaborationRepository (typed Supabase boundary)
      -> Postgres RLS + security-definer RPC transactions
      -> Supabase Realtime refresh signals
      -> Edge Functions for provider-token operations

MusicProvider adapters
  -> Spotify Web API search/OAuth + Spotify App Remote playback
  -> MusicKit catalog/playback after Apple entitlement is available
```

Canonical tracks and provider mappings prevent a Spotify ID from becoming the
shared identity of a song. Queue commands and ordered-list edits use explicit
revisions; stale mutations reject atomically and the client reloads the
authoritative snapshot. New rooms allow collaborators to arrange the queue by
default; the Conductor can revoke that permission without transferring
playback or arbitrary-removal authority.
Optimistic queue commands are serialized, visibly marked while syncing, and
surface a Retry/Dismiss decision when an automatic one-time rebase cannot
preserve the requested change.

## Build and test

The project currently uses the Xcode installation at:

```text
/Applications/Xcode.app/Contents/Developer
```

Simulator unit tests:

```sh
DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer' \
  xcodebuild test \
  -project Harmony.xcodeproj \
  -scheme Harmony \
  -destination 'platform=iOS Simulator,id=A509714B-2C46-4429-84C3-E3EA8A681554' \
  -parallel-testing-enabled NO \
  -maximum-parallel-testing-workers 1 \
  ASSETCATALOG_FILTER_FOR_DEVICE_MODEL= \
  ASSETCATALOG_FILTER_FOR_DEVICE_OS_VERSION= \
  ENABLE_ON_DEMAND_RESOURCES=NO \
  -only-testing:HarmonyTests \
  CODE_SIGNING_ALLOWED=NO
```

Linked Supabase verification:

```sh
supabase db lint --linked
supabase db push --linked --dry-run
HARMONY_NODE_BINARY='/Users/geridoe/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node' \
  bash supabase/tests/live_smoke.sh
```

The smoke test creates disposable anonymous accounts and deletes them on exit.
It verifies RLS, follows/blocks, queue authority, revision conflicts, review and
list privacy, notification/activity shapes, and Realtime delivery.

## External gates

Spotify catalog search, OAuth, App Remote playback, live sharing, and manual
history import can be developed and tested now with a Spotify developer app and
Premium account. Apple Music authorization/playback requires the Apple
Developer Program, a MusicKit-enabled App ID, signing entitlements, and a real
device/account. That gate does not block Supabase, social, queue, Reviews,
Ratings, Lists, Spotify, or simulator work.

Sign in with Apple, APNs registration, owner notification preferences, private
device-token storage, and typed notification routing are implemented.
Production delivery still requires enabling Sign in with Apple and Push
Notifications for the App ID, configuring Supabase's Apple provider/manual
identity linking, and installing an APNs key for the deployed trusted worker.

Production safety includes durable abuse reports, per-account write throttles,
bounded service-role cleanup, and exhaustive server-side Diary filtering. Live
listening uses a 15-second heartbeat, one preferred-provider feed projection,
and table-specific Realtime cache invalidation to contain operating costs.
Spotify Edge Functions also share an encrypted, short-lived access-token cache
and a database refresh lease, preventing simultaneous searches/history/live
polling from repeatedly refreshing the same account token.

## Design references

- [Product specification](Docs/PRODUCT_SPEC.md)
- [System design plan](Docs/DESIGN_PLAN.md)
- [Implementation guide](Docs/IMPLEMENTATION_GUIDE.md)
- [Reviews and Diary design](Docs/REVIEW_DESIGN.md)
- [Eavesdrop design](Docs/EAVESDROP_DESIGN.md)
- [Collections design](Docs/COLLECTIONS_DESIGN.md)
- [Social expansion specification](Docs/SOCIAL_EXPANSION_SPEC.md)
