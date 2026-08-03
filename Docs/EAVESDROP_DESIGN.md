# Eavesdrop live-listening design

**Status:** migrations 041 and 054 deployed on 2026-08-03; hosted smoke coverage passes.

## Product contract

Eavesdrop lets an approved follower see what another person is listening to,
start the same canonical recording in their own connected service, and react or
comment during the short live window. Harmony shares track identity and social
activity only. It never relays audio, playback position, OAuth credentials, or
provider account identifiers, and it does not promise synchronized playback.

The viewer's provider is authoritative for the listen action. A broadcast
authored from Apple Music may resolve to Spotify, or vice versa, through
`canonical_tracks` and safe `provider_tracks` mappings. The broadcaster's deep
link is only a fallback.

## Identity and lifecycle

`listening_presence` remains the current five-minute playback card so existing
iOS and Spotify Edge Function publishers remain compatible. Migration 041 adds
an immutable `broadcast_id` and a durable `listening_broadcasts` parent.

- Refreshing the same active recording extends the existing broadcast.
- Changing recording, publishing after expiry, or starting after a stop creates
  a new broadcast and therefore a new conversation.
- Stopping deletes the presence row and marks its broadcast ended.
- Comments and reactions remain attached to their original broadcast identity;
  new interaction is rejected after end/expiry.
- Each broadcast snapshots its host name, canonical identity, track display
  metadata, source provider ID/link, and last status. A stopped notification
  therefore reopens the original recording and conversation instead of the
  host's newer presence. Lifecycle distinguishes stopped, superseded, and
  expired broadcasts; passive expiry uses the original expiry timestamp.

## Privacy and authority

Broadcast visibility reuses `social_visibility`, accepted-follower checks, and
two-way block enforcement. RLS covers broadcasts, comments, and reactions.
Nonhosts can read a broadcast only while it is active and currently shared with
them. Ended/expired snapshots and their conversation are host-only because live
visibility is temporary consent, not archival sharing. Changing Connections
live visibility is synchronized in the database transaction: Only me removes
the presence and closes the broadcast, while an allowed audience update changes
the active presence and parent together.
Authenticated clients have SELECT only; all writes use actor-derived RPCs:

- `add_listening_broadcast_comment`
- `delete_listening_broadcast_comment`
- `toggle_listening_broadcast_reaction`

The comment author or broadcast host may remove a comment. Reaction kinds are
Heart, Fire, and Headphones. Non-self interactions notify the host through the
existing recipient-only social inbox, and all broadcast tables participate in
Supabase Realtime.

## Cross-provider read contract

`list_eavesdrop_broadcasts(broadcast_id, viewer_provider, storefront)` returns
flat, token-free rows containing host display data, current track metadata,
source-provider fallback, and at most one best mapping for the requested viewer
provider. iOS calls it once without a provider to load the feed and once for
each connected provider, then merges rows strictly by `broadcast_id`.

The detail page exposes provider-specific play/open actions, the three reaction
types, and a live comment thread. Failed comments retain their draft. Provider
playback is routed through the existing adapter boundary and never mutates the
collaborative queue or creates listening history by itself.

`get_listening_broadcast_snapshot(broadcast_id, viewer_provider, storefront)`
is the exact notification resolver. It returns the immutable snapshot plus
`ended_at`, effective end time, and lifecycle reason. The active feed never uses
this RPC. An authorized ended detail is read-only: it shows the original track
and conversation, disables playback/add/reaction mutations in both UI and store,
and labels any surviving catalog link as a passive Open track action. Older
rows that predate snapshots remain truthful shells rather than borrowing a
newer presence from the same host.

## Verification

The hosted smoke suite proves stable refresh identity, immutable snapshot
fields, settings-driven stop, active exact lookup, random-ID absence, block
hiding, Apple-to-Spotify resolution, host-only stopped/expired lookup, child
conversation privacy, ended-interaction rejection, lifecycle materialization,
and account cleanup. Swift tests cover provider-row merging and stopped-before-
expiry state. Simulator UI reopens an exact ended notification with its original
track/comment and verifies the read-only presentation.
