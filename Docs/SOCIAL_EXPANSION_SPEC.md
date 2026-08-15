# Harmony social listening expansion

## Product model

Harmony remains a provider-neutral collaborative queue for a party, event, or
small group. Social listening extends that experience between rooms:

- **Live room**: a Conductor hosts a collaborative queue with explicit members.
- **Eavesdrop**: a person voluntarily publishes a short-lived, follower-visible
  playback timeline. An accepted follower may join remotely on their own
  provider/device at the projected current position and follow later host
  play/pause/seek/track generations without gaining host queue or playback
  control. Harmony never sends audio or promises sample-accurate sync.
- **Listening history**: a person can choose to publish Harmony-recorded plays
  and explicitly imported provider history to followers. A history row may
  start independent playback from the beginning; it is never a live anchor.
- **Reviews**: a Letterboxd-style diary entry for a track or album, with rating,
  optional review text, comments, and reactions.
- **Notifications**: a durable, unread in-app inbox for follow requests,
  accepted follows, review comments, and reactions. APNs can later deliver the
  same server-owned events without becoming the source of truth.

## Non-negotiable privacy defaults

1. Social visibility starts **off** for every account.
2. Live listening defaults to **private**, is manually enabled, and
   expires automatically after a short TTL when the client stops refreshing it.
3. Provider tokens, private Spotify sessions, device/account identifiers,
   Apple Music library contents, and unapproved listening history are never
   exposed. A rounded playback anchor may be projected only to currently
   authorized followers during an active share and is deleted at stop/expiry.
4. A user can delete their activity/history/reviews independently of their
   account and can block another user. Blocking immediately hides each
   person’s follower-visible social data from the other.
5. Reactions and comments are only available on content visible to the viewer.

## Provider boundary

Harmony stores and displays **its own social activity and ephemeral playback
intent**. It does not subscribe a follower directly to another user's provider
account. The host observes its provider locally or through its own authorized
server boundary; a follower applies the resulting timeline only to the
follower's separately authorized provider/device.

- Spotify can supply a connected user’s current playback and recently played
  tracks when they grant the relevant OAuth scopes. A server-side job or a
  foreground refresh writes only the user-approved Harmony activity record.
- MusicKit can provide recently played content after MusicKit authorization;
  app playback can also produce a first-party Harmony activity record.
- A user who connects neither provider can still write reviews and participate
  in rooms. Social features do not require an audio subscription.

## Visibility and social graph

The initial model has private, followers, and public visibility values. The
product UI should expose only `Followers` and `Only me` until public discovery
is intentionally enabled. Following is request/accept, not automatic:

```text
follow_requests(requester_id, target_id, state, created_at)
blocks(blocker_id, blocked_id, created_at)
profile_settings(profile_id, social_visibility, history_visibility, ...)
```

RLS is the authority: a client may read a social object only when it owns the
object, is an accepted follower permitted by its visibility, or the object is
public, and neither account has blocked the other.

## Social objects

```text
listening_shares
  id, host_profile_id, visibility, started_at, ended_at, end_reason

listening_presence
  profile_id, listening_share_id, broadcast_id, canonical_track_id?,
  provider, provider_track_id?, provider_deep_link?, status, visibility,
  playback_generation,
  position_anchor_ms, anchor_server_at, heartbeat_at, expires_at, updated_at

listening_broadcasts
  id, listening_share_id, generation, canonical_track_id,
  immutable host/track/provider snapshots, started_at, ended_at, end_reason

listening_history_entries
  profile_id, canonical_track_id?, provider, provider_track_id?,
  played_at, source, visibility, created_at

reviews
  profile_id, subject_kind (track | album), canonical_track_id?,
  provider, provider_subject_id?, rating? (0.5...5.0), body, visibility,
  spoiler, created_at, updated_at

comments
  review_id, author_id, body, created_at, deleted_at
reactions
  review_id, profile_id, kind, created_at
```

Albums remain provider-addressed at first; the later canonical album matcher
can merge equivalent Apple Music and Spotify album IDs without rewriting a
review’s public identity.

## First delivery slices

1. **Foundation** — private profile settings, accepted follower graph, blocks,
   privacy helpers, and RLS tests.
2. **Eavesdrop foundation (implemented)** — foreground-published TTL card,
   follower feed, canonical provider mapping, conversation identity, and an
   explicit Stop sharing control.
3. **Eavesdrop synchronization (next)** — server-stamped playback anchors,
   short freshness TTL, Realtime generations, late join/seek, read-only local
   provider mirroring, and independent recently-played playback.
4. **Diary** — user-owned listening history, track/album rating/review,
   comments, reactions, edit/delete, and RLS tests.
5. **Provider import** — Spotify recent-history import and current-playback
   publishing are implemented as explicit foreground actions, with exact-play
   deduplication for history. MusicKit recent content follows after its provider
   authorization path is available.

## Out of scope for this expansion

- Audio broadcasting, remote control of another user’s player, or
  sample-/frame-accurate cross-provider sync. Best-effort follower-local
  playback correction is explicitly in scope for Eavesdrop.
- DMs, group chat, recommendation ranking, ads, or public discovery ranking.
- Automatic collection of a provider’s history without an explicit user choice.
