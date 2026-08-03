# Reviews and listening journal design

**Decision date:** 2 August 2026  
**Status:** first dedicated iOS surface implemented; broader discovery work remains

## Why this is a separate product surface

Reviews are an identity and discovery feature, not a control attached to live
playback. Hiding them inside Listen made the feature feel incidental and mixed
three different user jobs: seeing friends, sharing live activity, and keeping a
music diary. Harmony now gives Reviews its own primary tab while Listen keeps
followers, notifications, eavesdropping, and listening history.

## Research findings

Letterboxd's transferable strength is its separation of four concepts:

1. A low-friction consumption status (watched).
2. A dated, repeatable diary log.
3. A rating/review that expresses an opinion.
4. A Like that is independent of the numeric rating.

Its social layer then makes reviews, likes, comments, lists, and follower
activity discoverable without treating every historic import as a new post.
These behaviors are documented in the [Letterboxd FAQ](https://letterboxd.com/about/faq/),
[official app overview](https://letterboxd.com/apps/), and
[App Store listing](https://apps.apple.com/us/app/letterboxd/id1054271011).

Harmony adopts that information model, not Letterboxd's branding, colors,
icons, poster grid, or copy.

## Harmony model

| Concept | Harmony representation | Behavior |
| --- | --- | --- |
| Playing now | queue/provider playback | ephemeral; not automatically a social post |
| Listening journal | `listening_history_entries` | dated and repeatable; imports are deduplicated |
| Opinion | `music_reviews` | current 0.5–5.0 rating and optional review |
| Affinity | `music_reviews.is_loved` | independent Loved signal; not a social reaction |
| Community reaction | `review_reactions` | another listener reacting to a published review |

The distinction between affinity and reaction is important. “Loved” describes
the review author's relationship to the music. A heart on a review describes a
reader's response to that review.

## First implementation

The fifth iOS tab has two shelves:

- **Community** contains a current-track composer and follower-visible review
  feed. The rating control supports half-star steps. The author can mark the
  music Loved independently of the score.
- **My journal** contains the owner's dated listening entries and their own
  reviews. The copy explicitly explains that logs and opinions are independent.

Album review creation remains available on Spotify/Apple catalog results in
Add music. The server migration `202608020023_review_affinity.sql` adds the
affinity field and updates owner-authorized create/edit RPCs.

## Next review-specific slices

1. Add a media picker inside Reviews so a user can review any resolved song or
   album without first placing it in the queue.
2. Add review detail navigation, spoiler reveal, reaction choices, comment
   moderation, and deep links from notifications.
3. Add profile shelves for Journal, Reviews, Loved, and Collections.
4. Add music-native context to journal entries (first listen, relisten, live,
   mood, setting) without requiring it for a quick log.
5. Add discovery only after report/block/moderation and ranking policies are
   defined; bulk history imports should not flood follower activity.
