-- Evaluate the request identity once per statement instead of once per row.
-- This is behaviorally identical but reduces CPU on growing feeds and shelves.
alter policy "users update their own profile" on public.profiles
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

alter policy "users read their own provider connection metadata" on public.provider_connections
  using (profile_id = (select auth.uid()));

alter policy "users read their social settings" on public.profile_social_settings
  using (profile_id = (select auth.uid()));
alter policy "users update their social settings" on public.profile_social_settings
  using (profile_id = (select auth.uid()))
  with check (profile_id = (select auth.uid()));

alter policy "people read their own follow edges" on public.social_follows
  using (
    follower_id = (select auth.uid())
    or followed_id = (select auth.uid())
  );
alter policy "users read their own blocks" on public.profile_blocks
  using (blocker_id = (select auth.uid()));

alter policy "users view their own track subject states" on public.profile_track_subject_states
  using (profile_id = (select auth.uid()));
alter policy "users view their own album subject states" on public.profile_album_subject_states
  using (profile_id = (select auth.uid()));

alter policy "profiles are visible unless blocked" on public.profiles
  using (
    id = (select auth.uid())
    or not private.viewer_social_account_is_blocked(id)
  );

alter policy "recipients view unblocked social notifications" on public.social_notifications
  using (
    recipient_id = (select auth.uid())
    and not private.viewer_social_account_is_blocked(actor_id)
  );

alter policy "view current followed social activity" on public.social_activity_events
  using (
    not private.viewer_social_account_is_blocked(actor_id)
    and (
      actor_id = (select auth.uid())
      or exists (
        select 1
        from public.social_follows follow_edge
        where follow_edge.follower_id = (select auth.uid())
          and follow_edge.followed_id = actor_id
          and follow_edge.state = 'accepted'
      )
    )
    and (
      (
        kind = 'diary_logged'
        and exists (
          select 1 from public.listening_history_entries entry
          where entry.id = diary_entry_id
            and entry.profile_id = actor_id
            and entry.source = 'manual'
            and entry.visibility = 'followers'
        )
      )
      or (
        kind = 'review_published'
        and exists (
          select 1 from public.music_reviews review
          where review.id = review_id
            and review.profile_id = actor_id
            and review.deleted_at is null
            and review.visibility = 'followers'
        )
      )
      or (
        kind = 'list_published'
        and exists (
          select 1 from public.music_lists list
          where list.id = list_id
            and list.owner_id = actor_id
            and list.deleted_at is null
            and list.visibility <> 'private'
            and public.can_view_social(list.owner_id, list.visibility)
        )
      )
    )
  );

alter policy "reporters view their submitted reports" on public.abuse_reports
  using (reporter_id = (select auth.uid()));
alter policy "members view notification preferences" on public.notification_preferences
  using (profile_id = (select auth.uid()));
