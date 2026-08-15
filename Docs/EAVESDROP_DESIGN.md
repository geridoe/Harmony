# Eavesdrop synchronized listen-along design

**Revision date:** 14 August 2026

**Status:** the privacy-safe broadcast identity, cross-provider mapping,
conversation, notification, and ended-snapshot foundation is deployed in
migrations 041 and 054. Position-aware synchronization described below is the
target contract and is not yet implemented end to end.

## Product contract

Eavesdrop is a read-only, remote listen-along to an approved followed member.
A host explicitly shares live listening. An accepted follower can join from
anywhere, resolve the same canonical recording through a provider connected on
their own device, and start at the host's projected current position. Joining
late is normal. Host play, pause, seek, and track changes update the follower's
local playback when the provider adapter supports them.

Harmony coordinates canonical track identity, a short-lived playback timeline,
and social conversation. It never relays audio, transfers provider credentials,
or exposes a provider account/device identifier. “Synchronized” means a
best-effort bounded-drift timeline across independent licensed providers—not
sample-accurate audio, shared output, or a guarantee that two catalog editions
have identical mastering.

The follower is read-only with respect to the host:

- no host queue is exposed or editable;
- no follower action sends play, pause, seek, skip, or provider commands to the
  host;
- the only local playback action is **Join live** and the only session action is
  **Stop listening** / **Rejoin live**;
- system volume/output changes stay local;
- comments and reactions are social writes on the current track broadcast, not
  playback controls.

Eavesdrop does not require proximity, a party-room membership, a shared Wi-Fi
network, or the same music provider. It requires network reachability, an
active host share, accepted-follow authorization, a playable canonical mapping,
and provider playback/seek capability on the follower's device.

## Live versus recently played

The product must not present historical activity as live synchronization.

| Surface | Meaning | Playback action |
| --- | --- | --- |
| **Listening now** | active, fresh host timeline with a server anchor | **Join live** resolves locally and seeks to the projected position; later host generations continue automatically |
| **Recently played** | durable follower-visible history entry; the play has ended or is not being shared live | **Play from beginning** starts an independent local listen at zero; it never subscribes to host updates |
| **Ended Eavesdrop notification** | immutable track/conversation snapshot retained for the host | read-only social context; any surviving provider link is an independent **Open track** action |

A recently-played row may share canonical identity with an active broadcast,
but it never supplies a playback anchor, “live” badge, drift correction, or
automatic next-track transition. The UI must use different button labels and
accessibility identifiers so automation cannot confuse the two modes.

## Information architecture and flows

### Host

1. Connections defaults Live listening to **Only me**.
2. The host chooses Followers and explicitly starts sharing current playback.
3. Harmony publishes immediate state changes plus a bounded heartbeat while
   provider observation is available.
4. The host may stop at any time. Changing live visibility to Only me has the
   same immediate effect.
5. A track change creates a new per-track broadcast/conversation generation
   inside the same live share. Stopping and later restarting creates a new live
   share identity.

### Follower

1. Listen → Listening now lists active shares from accepted followed accounts.
2. Detail states the host, recording, provider options, freshness, and whether
   synchronization is supported.
3. **Join live** resolves the viewer's mapping, projects the server anchor,
   starts locally, seeks, then subscribes to newer generations.
4. If fewer than five seconds remain, Harmony waits for the next track instead
   of launching the final moments.
5. While joined, the screen shows **In sync**, **Host paused**, **Correcting**,
   **Reconnecting**, or **Out of sync**, plus **Stop listening**. It does not
   render host queue or transport controls.
6. Leaving stops Harmony's synchronization subscription. Whether local audio is
   paused is an explicit confirmation/policy; it never affects the host.

If the follower manually changes playback in the provider app, Harmony detects
divergence where possible, labels the session Out of sync, and offers Rejoin.
It must not fight repeated user intent indefinitely or claim synchronization
when the adapter can no longer observe/control the local player.

## Identity and lifecycle

The existing immutable `broadcast_id` remains the identity of one host/track
conversation. Synchronized multi-track listening also needs a stable live-share
identity:

```text
listening_shares
  id                       stable for one explicit host sharing interval
  host_profile_id
  visibility
  started_at
  ended_at
  end_reason

listening_broadcasts
  id                       existing per-track broadcast/conversation
  listening_share_id
  canonical_track_id
  generation               strictly increasing inside the share
  immutable display/provider snapshots
  started_at, ended_at, end_reason

listening_presence          active row only; never historical position storage
  profile_id
  listening_share_id
  broadcast_id
  canonical_track_id
  generation
  playback_state           playing | paused
  position_anchor_ms
  anchor_server_at
  heartbeat_at
  expires_at
  client_sequence
```

- Refreshing the same recording updates the active anchor and extends freshness
  without changing `broadcast_id`.
- Play/pause/seek changes increment `client_sequence` and replace the anchor.
- A track change ends the old broadcast, creates the next generation, and
  atomically moves presence to it. Joined followers follow the share identity,
  while comments remain attached to the correct track broadcast.
- Stop ends the share and active broadcast and deletes presence.
- Passive timeout ends them as expired. Restart after stop/expiry creates a new
  share, so a stale subscriber cannot attach to later listening.
- Durable broadcast snapshots retain host/canonical/display/conversation data,
  but never retain exact position anchors after the live interval.

## Server and Realtime contract

Normal clients receive SELECT projections only. Actor-derived RPCs are the
write boundary:

```text
publish_listening_state(
  canonical_track_id,
  source_provider,
  source_provider_track_id,
  playback_state,
  observed_position_ms,
  duration_ms,
  generation,
  client_sequence
)

stop_listening_share()
list_live_listen_alongs(viewer_provider, storefront)
get_live_listen_along_state(listening_share_id, viewer_provider, storefront)
```

The server stamps `anchor_server_at`; it never trusts a device wall clock.
`observed_position_ms` is bounded to the recording duration and rounded to a
documented precision before storage. `(generation, client_sequence)` must move
forward monotonically. Duplicate publication is idempotent; stale/out-of-order
publication is ignored or rejected without moving the anchor backward.

The publisher sends state immediately for track/play/pause/seek changes and a
heartbeat at most every ten seconds while it can truthfully observe playback.
Presence expires after thirty seconds without a heartbeat. Realtime is a refresh
signal, not the authorization authority: each notification causes the follower
to fetch a fresh RLS-filtered projection and its server timestamp. The active
projection returns token-free canonical metadata, freshness, playback anchor,
share/broadcast generation, and at most one best mapping for the requested
viewer provider.

The deployed `list_eavesdrop_broadcasts` and
`get_listening_broadcast_snapshot` remain compatibility/social-snapshot reads
until the position-aware RPCs replace the active-feed path. The snapshot RPC is
never a synchronization source.

## Projection and drift algorithm

For an authorized fresh state, the follower computes:

```text
if host is playing:
  target_ms = anchor_position_ms + max(0, server_now - anchor_server_at)
else:
  target_ms = anchor_position_ms

target_ms = clamp(target_ms, 0, duration_ms)
```

`server_now` comes from the response or an estimated server offset, never the
viewer's uncorrected wall clock. Join resolves and starts the viewer's provider
track, seeks to `target_ms`, and pauses locally when the host state is paused.
The operation is tagged with share ID + generation; a newer generation cancels
all older resolve/start/seek completions.

After start and each fresh anchor:

- absolute drift ≤ 1.5 seconds: do nothing;
- drift > 1.5 seconds: seek to the newly projected target when supported;
- repeated corrections or unavailable position observation: show Out of sync
  and require an explicit Rejoin rather than claiming success;
- remaining duration ≤ 5 seconds: wait for the next generation.

These thresholds are initial product constants and require physical-device
measurement per provider. Adapters must expose explicit play-at/seek, pause,
current-position, and observation capabilities; an `openInProvider` deep link
is an independent fallback, not successful synchronization.

## Privacy, authorization, and data minimization

- Live visibility defaults to Only me and requires explicit host opt-in.
- A nonhost may read active state only when it is fresh, visibility permits it,
  the viewer is an accepted follower, and neither account blocks the other.
- Unfollow, follower removal, audience reduction, or either-direction block
  removes future reads immediately. A joined client that loses authorization
  stops correction/subscription and leaves live mode without revealing which
  privacy predicate changed.
- Only the host can publish or stop its share. No API accepts a target host ID
  for playback mutation, and Eavesdrop has no queue-command bridge.
- Provider OAuth tokens, library contents, device IDs, raw provider playback
  sessions, output route, volume, and account identifiers are never projected.
- Position is sensitive ephemeral telemetry. It exists only in the active
  presence row, is rounded, is omitted from ended snapshots/social events/log
  payloads, and is deleted on stop/expiry.
- Mapping resolution returns only allowlisted provider/storefront metadata and
  sanitized deep links. Provider secrets remain server-side.
- Publish, join-state refresh, comments, and reactions require independent rate
  limits. Sequence/generation validation prevents replay and stale overwrites.
- Account deletion ends the share before removing social/provider data.

## Playback and social authority

Host provider observation is the only source of host playback intent. The
follower's adapter controls only the follower's provider/device. Harmony never
uses Spotify or MusicKit credentials belonging to the host to play on a
follower's account or vice versa.

Comments and Heart/Fire/Headphones reactions continue to use the existing
actor-derived RPCs and per-broadcast identity. They do not extend presence TTL.
The comment author or host may remove a live comment. When a broadcast ends,
new comments/reactions are rejected and the authorized snapshot conversation
is read-only under the existing retention policy.

## Failure semantics

| Condition | Required behavior | Must not happen |
| --- | --- | --- |
| Host playing; follower joins late | project server anchor, start own provider, seek, show In sync only after adapter confirmation | start from zero and label it live |
| Host paused | join/seek into paused state; mirror later resume | autoplay while claiming host is paused |
| Track nearly finished | remain joined and wait for next generation | launch final seconds or attach to the next track's old conversation |
| Host changes track during resolve | cancel stale completion; resolve latest generation | old track starts after new track |
| Host seeks | publish new anchor; correct viewer when beyond tolerance | send a command back to host |
| Host stops or revokes visibility | terminate live mode immediately on fresh signal; neutral unavailable state | retain/reveal the last position or keep claiming live |
| Heartbeat delayed | show Reconnecting and continue only during the 30-second grace window | silently extend live status for five minutes |
| Presence expires | pause/detach according to local policy, show Share ended | use an ended snapshot as a live anchor |
| Follow/block authorization changes | stop refresh/correction and remove share from feed | disclose whether block, unfollow, or privacy caused loss |
| Viewer provider mapping unavailable | explain unavailable; offer sanitized independent deep link if present | substitute another recording silently |
| Adapter can open but not seek/observe | label Open independently; do not enter joined state | claim synchronized playback |
| Provider authorization/subscription/app missing | retain screen and actionable recovery; remain not joined | mutate queue/history or spin indefinitely |
| Viewer backgrounds/returns | recompute from a fresh anchor and rejoin/correct before showing In sync | trust a stale local timer |
| Viewer manually diverges | show Out of sync and offer Rejoin | continuously override deliberate local control |
| Recently played selected | start independently at zero on viewer's provider | subscribe, drift-correct, or show a live badge |
| Comments/reactions fail | retain comment draft or prior reaction state and show scoped error | alter playback or presence freshness |

## Acceptance matrix

| Capability | Backend evidence | Swift/domain evidence | UI/device evidence |
| --- | --- | --- | --- |
| Private default and explicit share | settings/RLS + actor-bound publish tests | bootstrap/settings tests | Only me copy and explicit sharing action |
| Remote accepted-follower discovery | active/fresh/follow/block projection tests | row decoding and share-ID merge | two accounts on different networks |
| Late join while playing | server-stamped anchor response | deterministic projected-position tests | physical join seeks near host position |
| Join while paused | paused anchor unchanged by elapsed time | paused join-plan test | local provider remains paused |
| Near-end join | current generation plus duration | wait-for-next-track test | no last-seconds launch; next track begins |
| Multi-track continuity | atomic generation transition and stale-sequence rejection | stale async completion cancellation | joined follower follows next track without queue access |
| Drift correction | fresh anchors and server time | tolerance/seek decision tests | measured Spotify/Apple correction behavior |
| Read-only host authority | no host-target playback RPC; queue RPC isolation | no queue/history mutation tests | no host transport/queue controls in detail |
| Cross-provider join | canonical mapping projection without tokens | strict broadcast + provider merge | Spotify↔Apple physical-device pair |
| Unsupported mapping/seek | narrow unavailable/open projection | join plan returns unavailable | independent-open copy; never In sync |
| Stop/expiry/privacy revocation | immediate row loss, neutral denial, no position retention | joined-state teardown tests | live badge/actions disappear promptly |
| Recently played independence | history projection contains no live anchor | independent-from-beginning plan test | button says Play from beginning; no sync state |
| Social conversation isolation | per-broadcast RLS and ended-write rejection | exact snapshot/identity tests | comments stay on correct track; ended view read-only |
| Data minimization | projection-shape and log/retention tests | DTO excludes secrets/device identity | privacy copy states what is shared |

### Current evidence and remaining implementation

Already deployed/tested: explicit foreground share, follower/private/block RLS,
canonical cross-provider destinations, stable per-track broadcast identity,
comments/reactions, exact ended notification snapshots, ended interaction
rejection, account cleanup, provider-row merging, and read-only ended UI.

Still required for synchronized listen-along: stable multi-track share identity,
ephemeral position anchors, server time/sequence authority, 30-second freshness,
Realtime live-state refresh, adapter seek/position observation, joined-state UI,
stale-generation cancellation, independent recently-played play actions, rate
limits, and two-device/provider measurements. MusicKit device validation remains
externally gated, but the server contract, privacy tests, deterministic timing
logic, simulator states, and Spotify adapter work are not.
