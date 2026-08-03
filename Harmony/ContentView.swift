//
//  ContentView.swift
//  Harmony
//
//  Created by Geri Doe on 7/25/22.
//

import SwiftUI
struct ContentView: View {
    @EnvironmentObject private var store: HarmonySessionStore
    @State private var selection = 0
    var body: some View {
        TabView(selection: $selection) {
            SessionView()
                .tag(0)
                .tabItem { Label("Session", systemImage: "music.note.list") }
            SearchView()
                .tag(1)
                .tabItem { Label("Add music", systemImage: "plus.circle") }
            ConnectionsView().tag(2)
                .tabItem { Label("Connections", systemImage: "dot.radiowaves.left.and.right") }
            SocialView().tag(3)
                .tabItem { Label("Listen", systemImage: "ear") }
                .badge(store.unreadSocialNotificationCount)
            ReviewsView().tag(4)
                .tabItem { Label("Reviews", systemImage: "text.book.closed") }
        }
        .tint(.indigo)
        .onAppear {
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-test-social-activity") {
                store.seedSocialActivityUITestFixture()
            }
#endif
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

struct SocialView: View {
    @EnvironmentObject private var store: HarmonySessionStore

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if store.socialNotifications.isEmpty {
                        Text("No social notifications yet.").foregroundColor(.secondary)
                    } else {
                        ForEach(store.socialNotifications) { notification in
                            notificationRow(notification)
                        }
                    }
                } header: {
                    HStack {
                        Text("Notifications")
                        Spacer()
                        if store.unreadSocialNotificationCount > 0 {
                            Button("Mark all read") { Task { await store.markSocialNotificationsRead() } }
                                .font(.caption)
                        }
                    }
                }

                Section("Library and activity") {
                    NavigationLink {
                        ListeningDiaryView()
                    } label: {
                        Label("Diary", systemImage: "calendar")
                    }
                    .accessibilityIdentifier("listen-open-diary")

                    NavigationLink {
                        FollowingActivityView()
                    } label: {
                        Label("Following activity", systemImage: "person.2.wave.2")
                    }
                    .accessibilityIdentifier("listen-open-activity")

                    NavigationLink {
                        MusicShelfView()
                    } label: {
                        Label("Music shelf", systemImage: "books.vertical")
                    }
                    .accessibilityIdentifier("listen-open-music-shelf")

                    NavigationLink {
                        MusicListsView()
                    } label: {
                        Label("Lists", systemImage: "list.bullet.rectangle")
                    }
                    .accessibilityIdentifier("listen-open-music-lists")
                }

                Section("People") {
                    if store.isRefreshingSocialProfiles && store.socialProfiles.isEmpty {
                        ProgressView("Loading people…")
                    } else if store.socialProfiles.isEmpty {
                        Text("No other Harmony listeners are available yet.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(store.socialProfiles) { profile in
                            HStack(spacing: 12) {
                                NavigationLink {
                                    MemberProfileView(profileID: profile.id, displayName: profile.displayName)
                                } label: {
                                    HStack(spacing: 12) {
                                        Text(initials(for: profile.displayName))
                                            .font(.caption.bold())
                                            .foregroundColor(.indigo)
                                            .frame(width: 38, height: 38)
                                            .background(Color.indigo.opacity(0.12))
                                            .clipShape(Circle())
                                            .accessibilityHidden(true)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(profile.displayName).font(.headline)
                                            Text(relationshipLabel(for: profile.id))
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("social-profile-link-\(profile.id.uuidString)")
                                Spacer()
                                followerControl(for: profile)
                            }
                        }
                    }
                }

                Section("Eavesdrop") {
                    Text(store.liveSocialVisibility == .followers
                        ? "Share the current Harmony track with approved followers for five minutes. Harmony shares activity and provider links, never audio."
                        : "Live listening is set to Only me. You can save a private five-minute activity card or enable Followers in Connections.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Button {
                        Task { await store.toggleEavesdropping() }
                    } label: {
                        if store.isPublishingListeningPresence {
                            ProgressView()
                        } else {
                            Label(
                                store.isEavesdropping
                                    ? "Stop now-listening activity"
                                    : (store.liveSocialVisibility == .followers ? "Share now listening" : "Save private now listening"),
                                systemImage: store.isEavesdropping ? "ear.badge.xmark" : "ear.badge.checkmark"
                            )
                        }
                    }
                    .disabled(store.isPublishingListeningPresence)
                    if !store.isEavesdropping && store.providerState(for: .spotify) == .connected {
                        Button {
                            Task { await store.shareSpotifyNowListening() }
                        } label: {
                            Label("Share Spotify now playing", systemImage: "dot.radiowaves.left.and.right")
                        }
                        .disabled(store.isPublishingListeningPresence)
                    }
                }

                Section("Listening now") {
                    if store.isRefreshingListeningFeed && store.eavesdropFeed.isEmpty {
                        ProgressView("Loading listener activity…")
                    } else if store.eavesdropFeed.isEmpty {
                        Text("No approved listeners are sharing activity right now.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(store.eavesdropFeed) { broadcast in
                            NavigationLink {
                                EavesdropBroadcastDetailView(broadcast: broadcast)
                            } label: {
                                HStack(spacing: 12) {
                                if let track = broadcast.harmonyTrack {
                                    TrackArtwork(track: track, size: 42, cornerRadius: 10)
                                } else {
                                    Image(systemName: "music.note")
                                        .frame(width: 42, height: 42)
                                        .background(Color.indigo.opacity(0.12))
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(broadcast.hostDisplayName).font(.headline)
                                    Text([broadcast.title, broadcast.artist].compactMap { $0 }.joined(separator: " · "))
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                    Text(broadcast.status == "paused" ? "Paused" : "Listening now")
                                        .font(.caption)
                                        .foregroundColor(.indigo)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityIdentifier("eavesdrop-feed-card-\(broadcast.id.uuidString)")
                        }
                    }
                }

                Section("Listening history") {
                    if store.isRefreshingListeningHistory && store.listeningHistory.isEmpty {
                        ProgressView("Loading listening history…")
                    } else if store.listeningHistory.isEmpty {
                        Text("No visible Harmony listening history yet.").foregroundColor(.secondary)
                    } else {
                        ForEach(store.listeningHistory) { entry in
                            HStack(spacing: 12) {
                                if let track = entry.canonicalTrack {
                                    TrackArtwork(track: track.harmonyTrack, size: 38, cornerRadius: 8)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.canonicalTrack.map { "\($0.title) · \($0.artist)" } ?? "Unavailable track")
                                        .font(.subheadline.weight(.semibold))
                                    HStack(spacing: 4) {
                                        Text(entry.profile.displayName)
                                        Text("·")
                                        Text(entry.playedAt, style: .relative)
                                        if store.isOwnHistoryEntry(entry) {
                                            Image(systemName: entry.visibility.systemImage)
                                                .accessibilityLabel(entry.visibility.title)
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                }
                                Spacer()
                                if store.isOwnHistoryEntry(entry) {
                                    Button(role: .destructive) {
                                        Task { await store.deleteListeningHistoryEntry(entry.id) }
                                    } label: { Image(systemName: "trash") }
                                    .accessibilityLabel("Delete history entry")
                                }
                            }
                        }
                    }
                }

            }
            .navigationTitle("Listen")
            .task {
                await store.refreshAccountSettings()
                await store.refreshSocialNotifications()
                await store.refreshSocialProfiles()
                await store.refreshListeningFeed()
                await store.refreshListeningHistory()
                await store.activateSocialRealtime()
            }
            .refreshable {
                await store.refreshSocialNotifications()
                await store.refreshSocialProfiles()
                await store.refreshListeningFeed()
                await store.refreshListeningHistory()
            }
        }
    }

    @ViewBuilder
    private func followerControl(for profile: RemoteSocialProfile) -> some View {
        if store.socialProfileActionIDs.contains(profile.id) {
            ProgressView().controlSize(.small)
        } else {
            switch store.socialRelationship(with: profile.id) {
            case .none:
                Button("Follow") { Task { await store.requestSocialFollow(profile.id) } }
                    .buttonStyle(.bordered)
            case .outgoingRequested:
                Menu("Requested") {
                    Button("Cancel request", role: .destructive) {
                        Task { await store.removeSocialFollow(profile.id) }
                    }
                    blockButton(profile.id)
                }
            case .incomingRequested:
                Menu("Respond") {
                    Button("Accept") { Task { await store.respondToSocialFollow(from: profile.id, accept: true) } }
                    Button("Decline", role: .destructive) {
                        Task { await store.respondToSocialFollow(from: profile.id, accept: false) }
                    }
                    blockButton(profile.id)
                }
                .buttonStyle(.borderedProminent)
            case .following:
                Menu("Following") {
                    Button("Unfollow", role: .destructive) { Task { await store.removeSocialFollow(profile.id) } }
                    blockButton(profile.id)
                }
            case .followsYou:
                Menu("Follows you") {
                    Button("Follow back") { Task { await store.requestSocialFollow(profile.id) } }
                    Button("Remove follower", role: .destructive) { Task { await store.removeSocialFollower(profile.id) } }
                    blockButton(profile.id)
                }
            case .mutual:
                Menu("Mutual") {
                    Button("Unfollow", role: .destructive) { Task { await store.removeSocialFollow(profile.id) } }
                    Button("Remove follower", role: .destructive) { Task { await store.removeSocialFollower(profile.id) } }
                    blockButton(profile.id)
                }
            case .blocked:
                Button("Unblock") { Task { await store.unblockSocialProfile(profile.id) } }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func blockButton(_ profileID: UUID) -> some View {
        Button("Block", role: .destructive) { Task { await store.blockSocialProfile(profileID) } }
    }

    private func relationshipLabel(for profileID: UUID) -> String {
        switch store.socialRelationship(with: profileID) {
        case .none: "Discoverable profile"
        case .outgoingRequested: "Request pending"
        case .incomingRequested: "Wants to follow you"
        case .following: "You follow this listener"
        case .followsYou: "Follows you"
        case .mutual: "You follow each other"
        case .blocked: "Blocked"
        }
    }

    private func initials(for displayName: String) -> String {
        displayName.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    private func notificationIcon(_ kind: String) -> String {
        switch kind {
        case "follow_request": "person.badge.plus"
        case "follow_accepted": "person.crop.circle.badge.checkmark"
        case "review_comment": "bubble.left.fill"
        case "review_reaction": "heart.fill"
        case "music_list_like": "heart.fill"
        case "music_list_comment": "bubble.left.fill"
        case "listening_broadcast_comment": "bubble.left.fill"
        case "listening_broadcast_reaction": "headphones"
        default: "bell.fill"
        }
    }

    private func notificationMessage(_ notification: RemoteSocialNotification) -> String {
        let actor = notification.actor.displayName
        let reviewTitle = notification.review?.subjectTitle
            ?? notification.review?.canonicalTrack?.title
            ?? "your review"
        let listTitle = notification.musicList?.title ?? "your list"
        switch notification.kind {
        case "follow_request": return "\(actor) wants to follow you"
        case "follow_accepted": return "\(actor) accepted your follow request"
        case "review_comment": return "\(actor) commented on \(reviewTitle)"
        case "review_reaction": return "\(actor) reacted to \(reviewTitle)"
        case "music_list_like": return "\(actor) liked \(listTitle)"
        case "music_list_comment": return "\(actor) commented on \(listTitle)"
        case "listening_broadcast_comment": return "\(actor) commented on your live listening"
        case "listening_broadcast_reaction": return "\(actor) reacted to your live listening"
        default: return "New activity from \(actor)"
        }
    }

    @ViewBuilder
    private func notificationRow(_ notification: RemoteSocialNotification) -> some View {
        if let reviewID = notification.reviewID,
           notification.kind == "review_comment" || notification.kind == "review_reaction" {
            NavigationLink {
                ReviewByIDDestination(
                    reviewID: reviewID,
                    notificationID: notification.readAt == nil ? notification.id : nil
                )
            } label: {
                notificationLabel(notification)
            }
            .accessibilityIdentifier("notification-review-\(reviewID.uuidString)")
        } else {
            Button {
                guard notification.readAt == nil else { return }
                Task { await store.markSocialNotificationsRead(notification.id) }
            } label: {
                notificationLabel(notification)
            }
            .buttonStyle(.plain)
        }
    }

    private func notificationLabel(_ notification: RemoteSocialNotification) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notificationIcon(notification.kind))
                .foregroundColor(.indigo)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(notificationMessage(notification))
                    .foregroundColor(.primary)
                    .font(notification.readAt == nil ? .subheadline.weight(.semibold) : .subheadline)
                Text(notification.createdAt, style: .relative)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if notification.readAt == nil {
                Circle().fill(Color.indigo).frame(width: 8, height: 8)
                    .accessibilityLabel("Unread")
            }
        }
    }
}

private struct ListeningDiaryView: View {
    @EnvironmentObject private var store: HarmonySessionStore
    @State private var isCreatingEntry = false
    @State private var editingEntry: RemoteListeningHistoryEntry?
    @State private var browseFilter = JournalBrowseFilter()

    private var entries: [RemoteListeningHistoryEntry] {
        browseJournalEntries(store.journalEntries, using: browseFilter)
    }

    var body: some View {
        List {
            Section {
                Button {
                    isCreatingEntry = true
                } label: {
                    Label("Log a listen", systemImage: "square.and.pencil")
                }
                .accessibilityIdentifier("diary-log-listen")

                Button {
                    Task { await store.quickLogCurrentTrackToJournal() }
                } label: {
                    if store.isSavingDiaryEntry {
                        ProgressView()
                    } else {
                        Label("Quick log the current track", systemImage: "plus.circle")
                    }
                }
                .disabled(store.nowPlaying == nil || store.isSavingDiaryEntry)
                .accessibilityIdentifier("diary-quick-log")
            } footer: {
                Text("Diary entries are dated listening events. Reviews and current ratings remain in the separate Reviews tab.")
            }

            Section("Listening journal") {
                if store.isRefreshingJournalEntries && store.journalEntries.isEmpty {
                    ProgressView("Loading your journal…")
                } else if store.journalEntries.isEmpty {
                    Text("Your dated listens will appear here. Log a listen without changing an existing review.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    diaryBrowseControls
                    if entries.isEmpty {
                        VStack(spacing: 6) {
                            Label("No matching listens", systemImage: "magnifyingglass")
                                .font(.headline)
                            Text("Try another search, scope, or sort option. Your journal entries have not been removed.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .accessibilityIdentifier("journal-filtered-empty-state")
                    } else {
                        ForEach(entries) { entry in
                            diaryEntryRow(entry)
                        }
                    }

                    if store.hasMoreJournalEntries {
                        Button {
                            Task { await store.loadMoreJournalEntries() }
                        } label: {
                            if store.isLoadingMoreJournalEntries {
                                ProgressView("Loading older entries…")
                            } else {
                                Label("Load older entries", systemImage: "arrow.down.circle")
                            }
                        }
                        .disabled(store.isLoadingMoreJournalEntries)
                        .accessibilityIdentifier("journal-load-older")
                    }
                }
            }
        }
        .navigationTitle("Diary")
        .task {
            await store.refreshAccountSettings()
            await store.refreshListeningHistory()
            await store.refreshJournalEntries()
        }
        .refreshable {
            await store.refreshListeningHistory()
            await store.refreshJournalEntries()
        }
        .sheet(isPresented: $isCreatingEntry) {
            DiaryEntryComposer(defaultVisibility: store.historySocialVisibility)
                .environmentObject(store)
        }
        .sheet(item: $editingEntry) { entry in
            DiaryEntryEditor(
                entry: entry,
                compatibleReviews: store.compatibleOwnTrackReviews(for: entry)
            )
            .environmentObject(store)
        }
        .accessibilityIdentifier("listening-diary-page")
    }

    private var diaryBrowseControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search title, artist, album, or tags", text: $browseFilter.query)
                .textInputAutocapitalization(.never)
                .accessibilityLabel("Search journal")
                .accessibilityIdentifier("journal-search")
            Picker("Journal scope", selection: $browseFilter.scope) {
                ForEach(JournalBrowseScope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("journal-scope")
            Picker("Sort journal", selection: $browseFilter.sort) {
                ForEach(JournalBrowseSort.allCases) { sort in
                    Text(sort.rawValue).tag(sort)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("journal-sort")
        }
        .accessibilityIdentifier("journal-browse-controls")
    }

    private func diaryEntryRow(_ entry: RemoteListeningHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                if let track = entry.canonicalTrack {
                    TrackArtwork(track: track.harmonyTrack, size: 40, cornerRadius: 8)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.canonicalTrack.map { "\($0.title) · \($0.artist)" } ?? "Unavailable track")
                        .font(.subheadline.weight(.semibold))
                    Text(entry.playedAt, format: .dateTime.month().day().year())
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if entry.isRelisten || !entry.tags.isEmpty || entry.rating != nil {
                        HStack(spacing: 5) {
                            if entry.isRelisten {
                                Label("Relisten", systemImage: "arrow.clockwise")
                            }
                            ForEach(entry.tags.prefix(3), id: \.self) { tag in
                                Text("#\(tag)")
                            }
                            if let rating = entry.rating {
                                Label("\(String(format: "%.1f", rating))", systemImage: "star.fill")
                                    .accessibilityLabel("Rated \(String(format: "%.1f", rating)) out of 5")
                            }
                        }
                        .font(.caption2)
                        .foregroundColor(.indigo)
                    }
                }
                Spacer()
                Image(systemName: entry.visibility.systemImage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .accessibilityLabel(entry.visibility.title)
                if entry.source == "manual" {
                    Button {
                        editingEntry = entry
                    } label: {
                        Image(systemName: "pencil.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Edit journal entry for \(entry.canonicalTrack?.title ?? "unavailable track")")
                    .accessibilityIdentifier("edit-diary-entry-\(entry.id.uuidString)")
                }
            }
            if let reviewID = entry.reviewID {
                LinkedDiaryReviewLink(
                    reviewID: reviewID,
                    accessibilityPrefix: "diary-linked-review"
                )
            }
        }
    }
}

private struct FollowingActivityView: View {
    @EnvironmentObject private var store: HarmonySessionStore
    @State private var filter = FollowingActivityFilter.all

    private var visibleItems: [RemoteFollowingActivityItem] {
        filteredFollowingActivity(store.followingActivity, using: filter)
    }

    var body: some View {
        List {
            Section("Following activity") {
                if store.isRefreshingFollowingActivity && store.followingActivity.isEmpty {
                    ProgressView("Loading activity…")
                        .accessibilityIdentifier("following-activity-loading")
                } else {
                    Picker("Activity type", selection: $filter) {
                        ForEach(FollowingActivityFilter.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("following-activity-filter")

                    if store.followingActivity.isEmpty {
                        Text("No follower-visible reviews, Diary entries, or lists yet.")
                            .foregroundColor(.secondary)
                            .accessibilityIdentifier("following-activity-empty")
                    } else if visibleItems.isEmpty {
                        Text("No \(filter.rawValue.lowercased()) match this loaded activity.")
                            .foregroundColor(.secondary)
                            .accessibilityIdentifier("following-activity-no-matches")
                    } else {
                        ForEach(visibleItems) { item in
                            FollowingActivityCard(item: item)
                        }
                    }

                    if store.hasMoreFollowingActivity {
                        Button {
                            Task { await store.loadMoreFollowingActivity() }
                        } label: {
                            if store.isLoadingMoreFollowingActivity {
                                ProgressView("Loading more activity…")
                            } else {
                                Label("Load more activity", systemImage: "arrow.down.circle")
                            }
                        }
                        .disabled(store.isLoadingMoreFollowingActivity)
                        .accessibilityIdentifier("following-activity-load-more")
                    }
                }
            }
        }
        .navigationTitle("Activity")
        .task {
            await store.refreshFollowingActivity()
            await store.activateSocialRealtime()
        }
        .refreshable {
            await store.refreshFollowingActivity()
        }
        .accessibilityIdentifier("following-activity-page")
    }
}

/// Resolves a review through the same privacy-enforcing repository path used by
/// notifications. Diary rows intentionally carry only an optional identifier:
/// Postgres masks it when the viewer cannot see the linked review.
private struct ReviewByIDDestination: View {
    @EnvironmentObject private var store: HarmonySessionStore
    let reviewID: UUID
    var notificationID: UUID? = nil
    @State private var review: RemoteMusicReview?
    @State private var didFinishLoading = false

    var body: some View {
        Group {
            if let review {
                ReviewDetailView(reviewID: reviewID, fallbackReview: review, onEdit: nil)
            } else if didFinishLoading {
                VStack(spacing: 10) {
                    Image(systemName: "text.book.closed")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("Review unavailable").font(.headline)
                    Text("It may have been removed or is no longer visible to you.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .accessibilityIdentifier("notification-review-unavailable")
            } else {
                ProgressView("Loading review…")
            }
        }
        .task {
            review = await store.loadReview(withID: reviewID)
            didFinishLoading = true
            if let notificationID {
                await store.markSocialNotificationsRead(notificationID)
            }
        }
    }
}

private struct LinkedDiaryReviewLink: View {
    let reviewID: UUID
    let accessibilityPrefix: String

    var body: some View {
        NavigationLink {
            ReviewByIDDestination(reviewID: reviewID)
        } label: {
            Label("View linked review", systemImage: "text.book.closed")
                .font(.caption.weight(.semibold))
        }
        .accessibilityIdentifier("\(accessibilityPrefix)-\(reviewID.uuidString)")
    }
}

private struct EavesdropBroadcastDetailView: View {
    @EnvironmentObject private var store: HarmonySessionStore
    let broadcast: EavesdropBroadcast
    @State private var commentDraft = ""

    private var detail: EavesdropBroadcastDetailState {
        store.eavesdropDetails[broadcast.id] ?? EavesdropBroadcastDetailState(broadcast: broadcast)
    }

    private var isActive: Bool {
        broadcast.expiresAt > Date()
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    if let track = broadcast.harmonyTrack {
                        TrackArtwork(track: track, size: 72, cornerRadius: 12)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(broadcast.title ?? "Unknown track").font(.headline)
                        Text(broadcast.artist ?? "Unknown artist").foregroundStyle(.secondary)
                        Text("Shared by \(broadcast.hostDisplayName)").font(.caption)
                    }
                }
                Text("Harmony starts the same song in your service. It does not stream audio or guarantee synchronized position.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Listen in") {
                if !isActive {
                    Label("Broadcast ended", systemImage: "clock.badge.xmark")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("eavesdrop-ended-\(broadcast.id.uuidString)")
                }
                if broadcast.destinations.isEmpty {
                    Text("No connected-provider mapping is available for this recording.")
                        .foregroundStyle(.secondary)
                }
                ForEach(MusicProvider.allCases) { provider in
                    if let destination = broadcast.destinations[provider] {
                        Button {
                            Task { _ = await store.startEavesdropPlayback(broadcast, provider: provider) }
                        } label: {
                            Label("Play in \(provider.name)", systemImage: "play.fill")
                        }
                        .disabled(!isActive || store.mutatingEavesdropBroadcastIDs.contains(broadcast.id))
                        .accessibilityIdentifier("eavesdrop-listen-\(provider.rawValue)-\(broadcast.id.uuidString)")
                        if let deepLink = destination.deepLink {
                            Link(destination: deepLink) {
                                Label("Open in \(provider.name)", systemImage: "arrow.up.right.square")
                            }
                        }
                    }
                }
            }

            Section("Reactions") {
                HStack {
                    reactionButton(kind: "heart", label: "Heart", symbol: "heart")
                    reactionButton(kind: "fire", label: "Fire", symbol: "flame")
                    reactionButton(
                        kind: "headphones",
                        label: "Headphones",
                        symbol: "headphones",
                        selectedSymbol: "headphones.circle.fill"
                    )
                }
            }

            Section("Comments") {
                if detail.comments.isEmpty {
                    Text("No comments yet.").foregroundStyle(.secondary)
                }
                ForEach(detail.comments) { comment in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(comment.author.displayName).font(.caption.bold())
                            Text(comment.body)
                        }
                        Spacer()
                        if store.canDeleteEavesdropComment(comment, broadcast: broadcast) {
                            Button(role: .destructive) {
                                Task { await store.deleteEavesdropComment(comment, from: broadcast) }
                            } label: { Image(systemName: "trash") }
                            .accessibilityIdentifier("eavesdrop-comment-delete-\(comment.id.uuidString)")
                        }
                    }
                    .accessibilityIdentifier("eavesdrop-comment-\(comment.id.uuidString)")
                }
                HStack {
                    TextField("Add a live comment", text: $commentDraft, axis: .vertical)
                        .lineLimit(1...4)
                        .accessibilityIdentifier("eavesdrop-comment-field-\(broadcast.id.uuidString)")
                    Button {
                        let submitted = commentDraft
                        Task {
                            if await store.addEavesdropComment(to: broadcast, body: submitted) {
                                commentDraft = ""
                            }
                        }
                    } label: { Image(systemName: "paperplane.fill") }
                    .disabled(!isActive || commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("eavesdrop-comment-post-\(broadcast.id.uuidString)")
                }
            }
        }
        .navigationTitle("Listening with \(broadcast.hostDisplayName)")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("eavesdrop-detail-\(broadcast.id.uuidString)")
        .task { await store.refreshEavesdropDetail(broadcast) }
        .refreshable { await store.refreshEavesdropDetail(broadcast) }
    }

    private func reactionButton(
        kind: String,
        label: String,
        symbol: String,
        selectedSymbol: String? = nil
    ) -> some View {
        let selected = store.hasEavesdropReaction(broadcast.id, kind: kind)
        let count = detail.reactions.filter { $0.kind == kind }.count
        return Button {
            Task { await store.toggleEavesdropReaction(broadcast, kind: kind) }
        } label: {
            VStack {
                Image(systemName: selected ? (selectedSymbol ?? "\(symbol).fill") : symbol)
                Text("\(count)").font(.caption.monospacedDigit())
            }
            .frame(maxWidth: .infinity)
        }
        .disabled(!isActive || store.mutatingEavesdropBroadcastIDs.contains(broadcast.id))
        .accessibilityLabel("\(label), \(count) reactions")
        .accessibilityIdentifier("eavesdrop-reaction-\(kind)-\(broadcast.id.uuidString)")
    }
}

private enum ReviewsShelf: String, CaseIterable, Identifiable {
    case reviews = "Reviews"
    case ratings = "Ratings"
    var id: String { rawValue }
}

private enum RatingsSubjectScope: String, CaseIterable, Identifiable {
    case all = "All"
    case songs = "Songs"
    case albums = "Albums"
    var id: String { rawValue }
}

struct MusicRatingDistributionBucket: Equatable, Identifiable {
    let rating: Double
    let count: Int
    var id: Double { rating }
}

func musicRatingDistribution(
    _ states: [RemoteTrackSubjectState]
) -> [MusicRatingDistributionBucket] {
    musicRatingDistribution(ratings: states.compactMap(\.defaultRating))
}

func musicRatingDistribution(
    ratings: [Double]
) -> [MusicRatingDistributionBucket] {
    let counts = Dictionary(grouping: ratings) { rating in
        min(10, max(1, Int((rating * 2).rounded())))
    }
    return (1...10).map { halfStars in
        MusicRatingDistributionBucket(
            rating: Double(halfStars) / 2,
            count: counts[halfStars]?.count ?? 0
        )
    }
}

enum FollowingActivityPresentationKind: String, Equatable {
    case diary
    case review
    case musicList
}

enum FollowingActivityFilter: String, CaseIterable, Identifiable, Equatable {
    case all = "All"
    case reviews = "Reviews"
    case diary = "Diary"
    case lists = "Lists"

    var id: String { rawValue }
}

func followingActivityPresentationKind(
    for payload: RemoteFollowingActivityPayload
) -> FollowingActivityPresentationKind {
    switch payload {
    case .diary: .diary
    case .review: .review
    case .musicList: .musicList
    }
}

/// A presentation-only transformation. `filter` preserves source order and
/// never changes the raw feed used by the store's pagination cursor.
func filteredFollowingActivity(
    _ activity: [RemoteFollowingActivityItem],
    using filter: FollowingActivityFilter
) -> [RemoteFollowingActivityItem] {
    guard filter != .all else { return activity }
    return activity.filter { item in
        switch (filter, item.payload) {
        case (.reviews, .review), (.diary, .diary), (.lists, .musicList): true
        default: false
        }
    }
}

enum ReviewDraftSubject: Hashable {
    case track(HarmonyTrack)
    case album(ReviewableAlbum)

    var title: String {
        switch self {
        case .track(let track): track.title
        case .album(let album): album.title
        }
    }

    var artist: String {
        switch self {
        case .track(let track): track.artist
        case .album(let album): album.artist
        }
    }

    var kind: String {
        switch self {
        case .track: "Song"
        case .album: "Album"
        }
    }
}

enum ReviewDiaryRatingMode: String, CaseIterable, Identifiable {
    case review = "Review rating"
    case unrated = "Unrated"
    case custom = "Different rating"

    var id: String { rawValue }
}

struct ReviewDraft: Equatable {
    var subject: ReviewDraftSubject?
    var rating: Double?
    var isLoved = false
    var containsSpoilers = false
    var body = ""
    var visibility: SocialVisibilityOption = .privateOnly
    var addToDiary = false
    var listenedOn = Date()
    var isRelisten = false
    var tagsText = ""
    var diaryVisibility: SocialVisibilityOption = .privateOnly
    var diaryRatingMode = ReviewDiaryRatingMode.review
    var customDiaryRating = 4.0

    var diaryDraft: DiaryEntryDraft {
        DiaryEntryDraft(
            listenedOn: listenedOn,
            isRelisten: isRelisten,
            tagsText: tagsText,
            rating: resolvedDiaryRating,
            visibility: diaryVisibility
        )
    }

    var diaryRequest: TrackReviewDiaryRequest? {
        guard addToDiary,
              case .track = subject,
              diaryDraft.tagValidationMessage == nil else { return nil }
        return TrackReviewDiaryRequest(
            listenedAt: diaryDraft.listenedOnForSubmission,
            isRelisten: isRelisten,
            tags: diaryDraft.normalizedTags,
            rating: resolvedDiaryRating,
            visibility: diaryVisibility
        )
    }

    var resolvedDiaryRating: Double? {
        switch diaryRatingMode {
        case .review: rating
        case .unrated: nil
        case .custom: customDiaryRating
        }
    }
}

enum ReviewPickerMode: String, CaseIterable, Identifiable {
    case songs = "Songs"
    case albums = "Albums"

    var id: String { rawValue }
}

func deduplicatedReviewAlbums(from tracks: [HarmonyTrack]) -> [ReviewableAlbum] {
    var seen = Set<String>()
    return tracks.compactMap(\.reviewableAlbum).filter { album in
        seen.insert("\(album.provider.rawValue):\(album.providerID)").inserted
    }
}

struct DiaryEntryDraft: Equatable {
    var track: HarmonyTrack?
    var listenedOn = Date()
    var isRelisten = false
    var tagsText = ""
    var rating: Double?
    var visibility: SocialVisibilityOption = .privateOnly
    var linkedReviewID: UUID?

    var normalizedTags: [String] {
        var seen = Set<String>()
        return tagsText.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    var tagValidationMessage: String? {
        if normalizedTags.count > 10 { return "Use no more than 10 tags." }
        if normalizedTags.contains(where: { $0.count > 30 }) { return "Each tag must be 30 characters or fewer." }
        return nil
    }

    var listenedOnForSubmission: Date {
        let calendar = Calendar.current
        if calendar.isDateInToday(listenedOn) { return Date() }
        return calendar.date(byAdding: .hour, value: 12, to: calendar.startOfDay(for: listenedOn)) ?? listenedOn
    }
}

enum JournalBrowseScope: String, CaseIterable, Identifiable {
    case all = "All"
    case relistens = "Relistens"
    case linkedOpinions = "Linked opinions"

    var id: String { rawValue }
}

enum JournalBrowseSort: String, CaseIterable, Identifiable {
    case newest = "Newest"
    case oldest = "Oldest"

    var id: String { rawValue }
}

struct JournalBrowseFilter: Equatable {
    var query = ""
    var scope = JournalBrowseScope.all
    var sort = JournalBrowseSort.newest
}

enum ReviewBrowseScope: String, CaseIterable, Identifiable {
    case all = "All"
    case songs = "Songs"
    case albums = "Albums"
    case loved = "Loved"

    var id: String { rawValue }
}

enum ReviewBrowseSort: String, CaseIterable, Identifiable {
    case newest = "Newest"
    case highestRated = "Highest rated"
    case lowestRated = "Lowest rated"

    var id: String { rawValue }
}

struct ReviewBrowseFilter: Equatable {
    var query = ""
    var scope = ReviewBrowseScope.all
    var sort = ReviewBrowseSort.newest
}

func browseMusicReviews(
    _ reviews: [RemoteMusicReview],
    using filter: ReviewBrowseFilter
) -> [RemoteMusicReview] {
    let query = journalSearchKey(filter.query.trimmingCharacters(in: .whitespacesAndNewlines))
    return reviews.filter { review in
        switch filter.scope {
        case .all: true
        case .songs: review.subjectKind == "track"
        case .albums: review.subjectKind == "album"
        case .loved: review.isLoved
        }
    }
    .filter { review in
        guard !query.isEmpty else { return true }
        let values = [
            review.subjectTitle,
            review.subjectArtist,
            review.canonicalTrack?.title,
            review.canonicalTrack?.artist,
            review.canonicalTrack?.album,
            review.body
        ].compactMap { $0 }
        return values.contains { journalSearchKey($0).contains(query) }
    }
    .sorted { left, right in
        switch filter.sort {
        case .newest:
            if left.createdAt == right.createdAt { return left.id.uuidString > right.id.uuidString }
            return left.createdAt > right.createdAt
        case .highestRated:
            if left.rating == right.rating {
                if left.createdAt == right.createdAt { return left.id.uuidString > right.id.uuidString }
                return left.createdAt > right.createdAt
            }
            switch (left.rating, right.rating) {
            case (.some(let leftRating), .some(let rightRating)): return leftRating > rightRating
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return false
            }
        case .lowestRated:
            if left.rating == right.rating {
                if left.createdAt == right.createdAt { return left.id.uuidString > right.id.uuidString }
                return left.createdAt > right.createdAt
            }
            switch (left.rating, right.rating) {
            case (.some(let leftRating), .some(let rightRating)): return leftRating < rightRating
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return false
            }
        }
    }
}

enum MusicShelfScope: String, CaseIterable, Identifiable {
    case all = "All"
    case loved = "Loved"
    case wantToListen = "Want to listen"
    case rated = "Rated"
    case listened = "Listened"

    var id: String { rawValue }
    var compactTitle: String { self == .wantToListen ? "Want" : rawValue }
}

struct MusicShelfFilter: Equatable {
    var query = ""
    var scope = MusicShelfScope.all
}

func browseTrackSubjectShelf(
    _ states: [RemoteTrackSubjectState],
    using filter: MusicShelfFilter
) -> [RemoteTrackSubjectState] {
    let query = journalSearchKey(filter.query.trimmingCharacters(in: .whitespacesAndNewlines))
    return states.filter { state in
        switch filter.scope {
        case .all: true
        case .loved: state.isLoved
        case .wantToListen: state.wantToListen
        case .rated: state.defaultRating != nil
        case .listened: state.hasListened
        }
    }
    .filter { state in
        guard !query.isEmpty else { return true }
        let values = [
            state.canonicalTrack?.title,
            state.canonicalTrack?.artist,
            state.canonicalTrack?.album
        ].compactMap { $0 }
        return values.contains { journalSearchKey($0).contains(query) }
    }
    .sorted { left, right in
        if left.updatedAt == right.updatedAt {
            return left.canonicalTrackID.uuidString > right.canonicalTrackID.uuidString
        }
        return left.updatedAt > right.updatedAt
    }
}

func browseJournalEntries(
    _ entries: [RemoteListeningHistoryEntry],
    using filter: JournalBrowseFilter
) -> [RemoteListeningHistoryEntry] {
    let query = journalSearchKey(filter.query.trimmingCharacters(in: .whitespacesAndNewlines))
    return entries.enumerated()
        .filter { _, entry in
            switch filter.scope {
            case .all: true
            case .relistens: entry.isRelisten
            case .linkedOpinions: entry.reviewID != nil
            }
        }
        .filter { _, entry in
            guard !query.isEmpty else { return true }
            let searchableValues = [
                entry.canonicalTrack?.title,
                entry.canonicalTrack?.artist,
                entry.canonicalTrack?.album
            ].compactMap { $0 } + entry.tags
            return searchableValues.contains { journalSearchKey($0).contains(query) }
        }
        .sorted { left, right in
            if left.element.playedAt == right.element.playedAt {
                return left.offset < right.offset
            }
            switch filter.sort {
            case .newest: return left.element.playedAt > right.element.playedAt
            case .oldest: return left.element.playedAt < right.element.playedAt
            }
        }
        .map(\.element)
}

private func journalSearchKey(_ value: String) -> String {
    value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
}

struct ReviewsView: View {
    @EnvironmentObject private var store: HarmonySessionStore
    @State private var shelf = ReviewsShelf.reviews
    @State private var draft = ReviewDraft()
    @State private var hasSeededDraftVisibility = false
    @State private var isComposingReview = false
    @State private var isChoosingReviewSubject = false
    @State private var reviewBrowseFilter = ReviewBrowseFilter()
    @State private var ratingsSubjectScope = RatingsSubjectScope.all
    @State private var editingReview: RemoteMusicReview?
    @State private var editingRating: Double?
    @State private var editingBody = ""
    @State private var editingVisibility = SocialVisibilityOption.privateOnly
    @State private var editingIsLoved = false
    @State private var editingContainsSpoilers = false

    private var ownReviews: [RemoteMusicReview] {
        store.ownerReviews
    }

    private var browsedOwnReviews: [RemoteMusicReview] {
        browseMusicReviews(ownReviews, using: reviewBrowseFilter)
    }

    private var ratedTrackStates: [RemoteTrackSubjectState] {
        store.trackSubjectShelf.filter { $0.defaultRating != nil }
    }

    private var ratedAlbumStates: [RemoteAlbumSubjectState] {
        store.albumSubjectShelf.filter { $0.defaultRating != nil }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Reviews shelf", selection: $shelf) {
                        ForEach(ReviewsShelf.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("reviews-shelf-picker")
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } footer: {
                    Text("Reviews are authored opinions. Ratings are your current song and album scores. Listening events stay in Diary under Listen.")
                }

                switch shelf {
                case .reviews:
                    personalReviews
                case .ratings:
                    personalRatings
                }
            }
            .navigationTitle("Reviews")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isComposingReview = true
                    } label: {
                        Label("Write review", systemImage: "square.and.pencil")
                    }
                    .accessibilityIdentifier("reviews-write-toolbar")
                }
            }
            .task {
                await store.refreshAccountSettings()
                if !hasSeededDraftVisibility {
                    draft.visibility = store.reviewsSocialVisibility
                    draft.diaryVisibility = store.historySocialVisibility
                    hasSeededDraftVisibility = true
                }
                await store.refreshMusicReviews()
                await store.refreshOwnerReviews()
                await store.refreshTrackSubjectShelf()
                await store.refreshAlbumSubjectShelf()
                await store.activateSocialRealtime()
            }
            .refreshable {
                await store.refreshMusicReviews()
                await store.refreshOwnerReviews()
                await store.refreshTrackSubjectShelf()
                await store.refreshAlbumSubjectShelf()
            }
        }
        .sheet(item: $editingReview) { review in
            NavigationStack {
                Form {
                    Section("Rating") {
                        OptionalReviewRatingControl(
                            rating: $editingRating,
                            accessibilityPrefix: "edit-review"
                        )
                    }
                    Section("Review") {
                        TextField("Review text", text: $editingBody, axis: .vertical)
                            .lineLimit(3...10)
                        Toggle("Loved", isOn: $editingIsLoved)
                        Toggle("Contains spoilers", isOn: $editingContainsSpoilers)
                    }
                    Section("Visibility") {
                        Picker("Audience", selection: $editingVisibility) {
                            ForEach(SocialVisibilityOption.allCases) { visibility in
                                Text(visibility.title).tag(visibility)
                            }
                        }
                    }
                }
                .navigationTitle("Edit review")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { editingReview = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            Task {
                                let didSave = await store.updateReview(
                                    review.id,
                                    rating: editingRating,
                                    body: editingBody,
                                    visibility: editingVisibility,
                                    isLoved: editingIsLoved,
                                    containsSpoilers: editingContainsSpoilers
                                )
                                if didSave { editingReview = nil }
                            }
                        }
                        .disabled(editingRating == nil && editingBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .sheet(isPresented: $isComposingReview) {
            reviewComposerDestination
        }
    }

    private var reviewComposerDestination: some View {
        NavigationStack {
            Form {
                reviewComposer
            }
            .navigationTitle("Write a review")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("review-composer")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { isComposingReview = false }
                }
            }
        }
        .sheet(isPresented: $isChoosingReviewSubject) {
            ReviewSubjectPicker { subject in
                var nextDraft = ReviewDraft()
                nextDraft.subject = subject
                nextDraft.visibility = draft.visibility
                nextDraft.diaryVisibility = draft.diaryVisibility
                draft = nextDraft
                isChoosingReviewSubject = false
            }
            .environmentObject(store)
        }
    }

    private var reviewComposer: some View {
        Section("Review music") {
            Button {
                isChoosingReviewSubject = true
            } label: {
                Label(draft.subject == nil ? "Choose a song or album" : "Choose different music", systemImage: "magnifyingglass")
            }

            if let subject = draft.subject ?? store.nowPlaying.map({ .track($0.track) }) {
                HStack(spacing: 12) {
                    reviewSubjectArtwork(subject)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(subject.title).font(.headline)
                        Text(subject.artist).font(.subheadline).foregroundColor(.secondary)
                        Text(subject.kind).font(.caption).foregroundColor(.secondary)
                    }
                }
                OptionalReviewRatingControl(
                    rating: $draft.rating,
                    accessibilityPrefix: "review-composer"
                )
                Toggle(isOn: $draft.isLoved) {
                    Label("Loved", systemImage: draft.isLoved ? "heart.fill" : "heart")
                }
                Toggle("Contains spoilers", isOn: $draft.containsSpoilers)
                TextField("Write your review (optional)", text: $draft.body, axis: .vertical)
                    .lineLimit(3...8)
                Picker("Audience", selection: $draft.visibility) {
                    ForEach(SocialVisibilityOption.allCases) { visibility in
                        Text(visibility.title).tag(visibility)
                    }
                }

                if case .track = subject {
                    Divider()
                    Toggle("Also add to Diary", isOn: $draft.addToDiary)
                        .accessibilityIdentifier("review-add-to-diary")
                    if draft.addToDiary {
                        DatePicker(
                            "Listened on",
                            selection: $draft.listenedOn,
                            in: ...Date(),
                            displayedComponents: .date
                        )
                        Toggle("Relisten", isOn: $draft.isRelisten)
                        TextField("Tags, separated by commas", text: $draft.tagsText)
                            .textInputAutocapitalization(.never)
                            .accessibilityIdentifier("review-diary-tags")
                        if let message = draft.diaryDraft.tagValidationMessage {
                            Text(message).font(.footnote).foregroundColor(.red)
                        }
                        Picker("Diary rating", selection: $draft.diaryRatingMode) {
                            ForEach(ReviewDiaryRatingMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .accessibilityIdentifier("review-diary-rating-mode")
                        if draft.diaryRatingMode == .custom {
                            RatingPicker(rating: $draft.customDiaryRating)
                                .accessibilityIdentifier("review-diary-custom-rating")
                        }
                        Picker("Diary audience", selection: $draft.diaryVisibility) {
                            ForEach(SocialVisibilityOption.allCases) { visibility in
                                Text(visibility.title).tag(visibility)
                            }
                        }
                        Text(draft.resolvedDiaryRating == nil
                            ? "The Diary entry will be unrated and link back to this review."
                            : "The Diary entry keeps this rating as a historical snapshot and links back to the review.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                Button(draft.addToDiary ? "Publish review and log listen" : (draft.visibility == .followers ? "Publish to followers" : "Save private review")) {
                    let selectedSubject = subject
                    let submittedDraft = draft
                    Task {
                        let didPublish: Bool
                        switch selectedSubject {
                        case .track(let track):
                            didPublish = await store.publishTrackReview(
                                track,
                                rating: submittedDraft.rating,
                                body: submittedDraft.body,
                                isLoved: submittedDraft.isLoved,
                                containsSpoilers: submittedDraft.containsSpoilers,
                                visibility: submittedDraft.visibility,
                                diary: submittedDraft.diaryRequest
                            )
                        case .album(let album):
                            didPublish = await store.publishAlbumReview(
                                album,
                                rating: submittedDraft.rating,
                                body: submittedDraft.body,
                                isLoved: submittedDraft.isLoved,
                                containsSpoilers: submittedDraft.containsSpoilers,
                                visibility: submittedDraft.visibility
                            )
                        }
                        if didPublish {
                            draft = ReviewDraft(
                                subject: submittedDraft.subject,
                                visibility: submittedDraft.visibility,
                                diaryVisibility: submittedDraft.diaryVisibility
                            )
                            isComposingReview = false
                        }
                    }
                }
                .disabled(
                    store.isPublishingMusicReview
                        || (draft.rating == nil && draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        || (draft.addToDiary && draft.diaryDraft.tagValidationMessage != nil)
                )
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "text.book.closed")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Choose something to review").font(.headline)
                    Text("Search your connected catalogs without adding music to the party queue or listening journal.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private func reviewSubjectArtwork(_ subject: ReviewDraftSubject) -> some View {
        switch subject {
        case .track(let track):
            TrackArtwork(track: track, size: 48, cornerRadius: 10)
        case .album(let album):
            if let artworkURL = album.artworkURL {
                AsyncImage(url: artworkURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else {
                        Image(systemName: "square.stack").foregroundColor(.indigo)
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                Image(systemName: "square.stack")
                    .foregroundColor(.indigo)
                    .frame(width: 48, height: 48)
            }
        }
    }

    private var personalReviews: some View {
        Section("My reviews") {
            Button {
                isComposingReview = true
            } label: {
                Label("Write a review", systemImage: "square.and.pencil")
            }
            .accessibilityIdentifier("reviews-write-review")
            if ownReviews.isEmpty {
                Text("Your ratings and reviews will appear here independently of your listening journal.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                ratingsSummary
                reviewBrowseControls
                if browsedOwnReviews.isEmpty {
                    VStack(spacing: 6) {
                        Label("No matching reviews", systemImage: "magnifyingglass")
                            .font(.headline)
                        Text("Try another search, scope, or sort option. Your reviews have not been removed.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .accessibilityIdentifier("reviews-filtered-empty-state")
                } else {
                    ForEach(browsedOwnReviews) { review in reviewCard(review) }
                }
                if store.hasMoreOwnerReviews {
                    Button {
                        Task { await store.loadMoreOwnerReviews() }
                    } label: {
                        if store.isLoadingMoreOwnerReviews {
                            ProgressView("Loading older reviews…")
                        } else {
                            Label("Load older reviews", systemImage: "arrow.down.circle")
                        }
                    }
                    .disabled(store.isLoadingMoreOwnerReviews)
                    .accessibilityIdentifier("reviews-load-older")
                }
            }
        }
    }

    private var personalRatings: some View {
        let visibleRatings = (ratingsSubjectScope == .all || ratingsSubjectScope == .songs
            ? ratedTrackStates.compactMap(\.defaultRating)
            : [])
            + (ratingsSubjectScope == .all || ratingsSubjectScope == .albums
                ? ratedAlbumStates.compactMap(\.defaultRating)
                : [])
        return Group {
            Section {
                Picker("Rating subject", selection: $ratingsSubjectScope) {
                    ForEach(RatingsSubjectScope.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("ratings-subject-scope")

                if !visibleRatings.isEmpty {
                    SubjectRatingDistributionView(
                        ratings: visibleRatings,
                        label: ratingsSubjectScope == .all
                            ? "loaded song and album ratings"
                            : "loaded \(ratingsSubjectScope.rawValue.lowercased()) ratings"
                    )
                }
            }

            if ratingsSubjectScope != .albums {
                Section("Song ratings") {
                    if store.isRefreshingTrackSubjectShelf && ratedTrackStates.isEmpty {
                        ProgressView("Loading song ratings…")
                    } else if ratedTrackStates.isEmpty {
                        Text("No song ratings yet.").foregroundColor(.secondary)
                    } else {
                        ForEach(ratedTrackStates) { state in
                            NavigationLink {
                                OwnerTrackDetailView(initialState: state)
                            } label: {
                                TrackRatingRow(state: state)
                            }
                            .accessibilityIdentifier("rating-open-song-\(state.canonicalTrackID.uuidString)")
                        }
                    }

                    if store.hasMoreTrackSubjectShelf {
                        Button {
                            Task { await store.loadMoreTrackSubjectShelf() }
                        } label: {
                            if store.isLoadingMoreTrackSubjectShelf {
                                ProgressView().frame(maxWidth: .infinity)
                            } else {
                                Text("Load more song ratings").frame(maxWidth: .infinity)
                            }
                        }
                        .disabled(store.isLoadingMoreTrackSubjectShelf)
                        .accessibilityIdentifier("ratings-songs-load-more")
                    }
                }
            }

            if ratingsSubjectScope != .songs {
                Section("Album ratings") {
                    if store.isRefreshingAlbumSubjectShelf && ratedAlbumStates.isEmpty {
                        ProgressView("Loading album ratings…")
                    } else if ratedAlbumStates.isEmpty {
                        Text("No album ratings yet.").foregroundColor(.secondary)
                    } else {
                        ForEach(ratedAlbumStates) { state in
                            if let album = state.canonicalAlbum {
                                NavigationLink {
                                    CanonicalAlbumDetailView(album: album, initialState: state)
                                } label: {
                                    AlbumRatingRow(state: state)
                                }
                                .accessibilityIdentifier("rating-open-album-\(state.canonicalAlbumID.uuidString)")
                            } else {
                                AlbumRatingRow(state: state)
                            }
                        }
                    }

                    if store.hasMoreAlbumSubjectShelf {
                        Button {
                            Task { await store.loadMoreAlbumSubjectShelf() }
                        } label: {
                            if store.isLoadingMoreAlbumSubjectShelf {
                                ProgressView().frame(maxWidth: .infinity)
                            } else {
                                Text("Load more album ratings").frame(maxWidth: .infinity)
                            }
                        }
                        .disabled(store.isLoadingMoreAlbumSubjectShelf)
                        .accessibilityIdentifier("ratings-albums-load-more")
                    }
                }
            }

            if visibleRatings.isEmpty
                && !store.isRefreshingTrackSubjectShelf
                && !store.isRefreshingAlbumSubjectShelf {
                Section {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("No ratings in this shelf").font(.headline)
                        Text("Rate a song or album without writing a review. Reviews keep their own authored rating snapshots.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .accessibilityIdentifier("ratings-empty-state")
                }
            }
        }
    }

    private var ratingsSummary: some View {
        let stats = store.ownerReviewStats
        let averageLabel = stats.averageRating.map { String(format: "%.1f", $0) } ?? "—"
        return HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 2) {
                Text(averageLabel).font(.title2.weight(.bold))
                Text(stats.averageRating == nil ? "No rated reviews" : "Average rating")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                Text("\(stats.reviewCount)").font(.title2.weight(.bold))
                Text(stats.reviewCount == 1 ? "Review" : "Reviews").font(.caption).foregroundColor(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                Label("\(stats.lovedCount)", systemImage: "heart.fill")
                    .font(.title2.weight(.bold))
                    .foregroundColor(.pink)
                Text("Loved").font(.caption).foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            stats.averageRating.map {
                "\(stats.reviewCount) reviews, average rating \(String(format: "%.1f", $0)) out of 5, \(stats.lovedCount) loved"
            } ?? "\(stats.reviewCount) reviews, no rated reviews, \(stats.lovedCount) loved"
        )
        .accessibilityIdentifier("reviews-ratings-summary")
    }

    private var reviewBrowseControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search title, artist, album, or review", text: $reviewBrowseFilter.query)
                .textInputAutocapitalization(.never)
                .accessibilityLabel("Search reviews")
                .accessibilityIdentifier("reviews-search")
            Picker("Review scope", selection: $reviewBrowseFilter.scope) {
                ForEach(ReviewBrowseScope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("reviews-scope")
            Picker("Sort reviews", selection: $reviewBrowseFilter.sort) {
                ForEach(ReviewBrowseSort.allCases) { sort in
                    Text(sort.rawValue).tag(sort)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("reviews-sort")
        }
        .accessibilityIdentifier("reviews-browse-controls")
    }

    private func reviewCard(_ review: RemoteMusicReview) -> some View {
        ReviewCard(review: review) { selected in
            editingReview = selected
            editingRating = selected.rating
            editingBody = selected.body
            editingVisibility = selected.visibility
            editingIsLoved = selected.isLoved
            editingContainsSpoilers = selected.containsSpoilers
        }
    }
}

private struct FollowingActivityCard: View {
    @EnvironmentObject private var store: HarmonySessionStore
    let item: RemoteFollowingActivityItem

    private var kindIdentifier: String {
        followingActivityPresentationKind(for: item.payload).rawValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink {
                MemberProfileView(profileID: item.actorID, displayName: item.actor.displayName)
            } label: {
                HStack(spacing: 9) {
                    ProfileInitials(displayName: item.actor.displayName, size: 34)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.actor.displayName).font(.subheadline.weight(.semibold))
                        Text(item.publishedAt, style: .relative)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("activity-actor-\(item.actorID.uuidString)")

            switch item.payload {
            case .review(let review):
                NavigationLink {
                    ReviewDetailView(reviewID: review.id, fallbackReview: review) { _ in }
                } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        ReviewSubjectSummary(review: review)
                        HStack(spacing: 7) {
                            if let rating = review.rating {
                                Label(String(format: "%.1f", rating), systemImage: "star.fill")
                            } else {
                                Text("No rating")
                            }
                            if review.isLoved { Label("Loved", systemImage: "heart.fill") }
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.indigo)
                        if review.containsSpoilers {
                            Label("Review contains spoilers", systemImage: "eye.slash")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        } else if !review.body.isEmpty {
                            Text(review.body).font(.footnote).lineLimit(3)
                        }
                    }
                }
                .buttonStyle(.plain)
            case .diary(let entry):
                ActivityDiarySummary(entry: entry)
                if let reviewID = entry.reviewID {
                    LinkedDiaryReviewLink(
                        reviewID: reviewID,
                        accessibilityPrefix: "activity-diary-linked-review"
                    )
                }
            case .musicList(let list):
                NavigationLink {
                    MusicListDetailView(listID: list.id)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(list.isRanked ? "Published a ranked list" : "Published a list", systemImage: "list.number")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.indigo)
                        Text(list.title).font(.headline)
                        if !list.description.isEmpty {
                            Text(list.description).font(.footnote).lineLimit(3)
                        }
                        if !list.tags.isEmpty {
                            Text(list.tags.prefix(4).map { "#\($0)" }.joined(separator: "  "))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            Label("Shared with followers", systemImage: "person.2.fill")
                .font(.caption2)
                .foregroundColor(.secondary)
                .accessibilityIdentifier("activity-privacy-\(item.id.uuidString)")
        }
        .accessibilityIdentifier("following-activity-card-\(kindIdentifier)-\(item.id.uuidString)")
    }
}

private struct ActivityDiarySummary: View {
    let entry: RemoteListeningHistoryEntry

    var body: some View {
        HStack(spacing: 12) {
            if let track = entry.canonicalTrack {
                TrackArtwork(track: track.harmonyTrack, size: 48, cornerRadius: 9)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.canonicalTrack?.title ?? "Unavailable track").font(.headline)
                if let artist = entry.canonicalTrack?.artist {
                    Text(artist).font(.subheadline).foregroundColor(.secondary)
                }
                HStack(spacing: 7) {
                    Label(entry.isRelisten ? "Listened again" : "Logged a listen", systemImage: entry.isRelisten ? "arrow.clockwise" : "calendar")
                    if let rating = entry.rating {
                        Label(String(format: "%.1f", rating), systemImage: "star.fill")
                            .accessibilityLabel(Text("Rated \(rating, specifier: "%.1f") out of 5"))
                    }
                }
                .font(.caption)
                .foregroundColor(.indigo)
                if !entry.tags.isEmpty {
                    Text(entry.tags.prefix(3).map { "#\($0)" }.joined(separator: "  "))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

private enum MemberProfileShelf: String, CaseIterable, Identifiable {
    case reviews = "Reviews"
    case diary = "Diary"
    case loved = "Loved"
    case lists = "Lists"
    var id: String { rawValue }
}

struct MemberProfileView: View {
    @EnvironmentObject private var store: HarmonySessionStore
    let profileID: UUID
    let displayName: String
    @State private var shelf = MemberProfileShelf.reviews

    private var shelfState: PublicProfileShelfState? { store.publicProfileShelves[profileID] }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    ProfileInitials(displayName: displayName, size: 54)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(displayName).font(.title3.weight(.semibold))
                        Text(relationshipDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Label("Only content this listener has shared with you appears here.", systemImage: "person.2.fill")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .accessibilityIdentifier("member-profile-privacy")
            }

            Section {
                Picker("Profile shelf", selection: $shelf) {
                    ForEach(MemberProfileShelf.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("member-profile-shelf-picker")
            }

            switch shelf {
            case .reviews: reviewsShelf
            case .diary: diaryShelf
            case .loved: lovedShelf
            case .lists: listsShelf
            }
        }
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("member-profile-page-\(profileID.uuidString)")
        .task(id: shelf) { await refreshSelectedShelf() }
        .refreshable { await refreshSelectedShelf() }
    }

    @ViewBuilder
    private var reviewsShelf: some View {
        let state = shelfState?.reviews
        Section("Reviews") {
            if state?.isRefreshing == true && state?.items.isEmpty != false {
                ProgressView("Loading reviews…")
            } else if state?.items.isEmpty != false {
                Text("No reviews have been shared with you.").foregroundColor(.secondary)
            } else {
                ForEach(state?.items ?? []) { review in
                    ReviewCard(review: review) { _ in }
                        .accessibilityIdentifier("member-profile-review-\(review.id.uuidString)")
                }
                profileLoadMore(
                    title: "Load more reviews",
                    isLoading: state?.isLoadingMore == true,
                    hasMore: state?.hasMore == true
                ) { await store.loadMorePublicProfileReviews(for: profileID) }
            }
        }
    }

    @ViewBuilder
    private var diaryShelf: some View {
        let state = shelfState?.diary
        Section("Diary") {
            if state?.isRefreshing == true && state?.items.isEmpty != false {
                ProgressView("Loading diary…")
            } else if state?.items.isEmpty != false {
                Text("No Diary entries have been shared with you.").foregroundColor(.secondary)
            } else {
                ForEach(state?.items ?? []) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        ActivityDiarySummary(entry: entry)
                            .accessibilityIdentifier("member-profile-diary-\(entry.id.uuidString)")
                        Text(entry.playedAt, format: .dateTime.month().day().year())
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        if let reviewID = entry.reviewID {
                            LinkedDiaryReviewLink(
                                reviewID: reviewID,
                                accessibilityPrefix: "member-profile-diary-review"
                            )
                        }
                    }
                }
                profileLoadMore(
                    title: "Load more diary entries",
                    isLoading: state?.isLoadingMore == true,
                    hasMore: state?.hasMore == true
                ) { await store.loadMorePublicProfileDiary(for: profileID) }
            }
        }
    }

    @ViewBuilder
    private var lovedShelf: some View {
        let state = shelfState?.loved
        Section("Loved") {
            if state?.isRefreshing == true && state?.items.isEmpty != false {
                ProgressView("Loading loved tracks…")
            } else if state?.items.isEmpty != false {
                Text("No Loved tracks have been shared with you.").foregroundColor(.secondary)
            } else {
                ForEach(state?.items ?? []) { loved in
                    HStack(spacing: 12) {
                        if let track = loved.canonicalTrack {
                            TrackArtwork(track: track.harmonyTrack, size: 44, cornerRadius: 8)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(loved.canonicalTrack?.title ?? "Unavailable track").font(.headline)
                            Text(loved.canonicalTrack?.artist ?? "Unknown artist")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "heart.fill")
                            .foregroundColor(.pink)
                            .accessibilityLabel("Loved")
                    }
                    .accessibilityIdentifier("member-profile-loved-\(loved.canonicalTrackID.uuidString)")
                }
                profileLoadMore(
                    title: "Load more loved tracks",
                    isLoading: state?.isLoadingMore == true,
                    hasMore: state?.hasMore == true
                ) { await store.loadMorePublicProfileLoved(for: profileID) }
            }
        }
    }

    @ViewBuilder
    private var listsShelf: some View {
        let state = shelfState?.lists
        Section("Lists") {
            if state?.isRefreshing == true && state?.items.isEmpty != false {
                ProgressView("Loading lists…")
            } else if state?.items.isEmpty != false {
                Text("No lists have been shared with you.").foregroundColor(.secondary)
            } else {
                ForEach(state?.items ?? []) { list in
                    NavigationLink {
                        MusicListDetailView(listID: list.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(list.title).font(.headline)
                                Spacer()
                                if list.isRanked {
                                    Label("Ranked", systemImage: "list.number")
                                        .font(.caption2)
                                        .foregroundColor(.indigo)
                                }
                            }
                            if !list.description.isEmpty {
                                Text(list.description).font(.footnote).lineLimit(2)
                            }
                            if !list.tags.isEmpty {
                                Text(list.tags.prefix(4).map { "#\($0)" }.joined(separator: "  "))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .accessibilityIdentifier("member-profile-list-\(list.id.uuidString)")
                }
                profileLoadMore(
                    title: "Load more lists",
                    isLoading: state?.isLoadingMore == true,
                    hasMore: state?.hasMore == true
                ) { await store.loadMorePublicProfileLists(for: profileID) }
            }
        }
    }

    @ViewBuilder
    private func profileLoadMore(
        title: String,
        isLoading: Bool,
        hasMore: Bool,
        action: @escaping () async -> Void
    ) -> some View {
        if hasMore {
            Button {
                Task { await action() }
            } label: {
                if isLoading { ProgressView() } else { Text(title) }
            }
            .disabled(isLoading)
        }
    }

    private func refreshSelectedShelf() async {
        switch shelf {
        case .reviews: await store.refreshPublicProfileReviews(for: profileID)
        case .diary: await store.refreshPublicProfileDiary(for: profileID)
        case .loved: await store.refreshPublicProfileLoved(for: profileID)
        case .lists: await store.refreshPublicProfileLists(for: profileID)
        }
    }

    private var relationshipDescription: String {
        switch store.socialRelationship(with: profileID) {
        case .none: "Discoverable profile"
        case .outgoingRequested: "Follow request pending"
        case .incomingRequested: "Wants to follow you"
        case .following: "You follow this listener"
        case .followsYou: "Follows you"
        case .mutual: "You follow each other"
        case .blocked: "Blocked"
        }
    }
}

private struct ProfileInitials: View {
    let displayName: String
    let size: CGFloat

    private var initials: String {
        displayName.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    var body: some View {
        Text(initials)
            .font(.caption.bold())
            .foregroundColor(.indigo)
            .frame(width: size, height: size)
            .background(Color.indigo.opacity(0.12))
            .clipShape(Circle())
            .accessibilityHidden(true)
    }
}

private struct MusicShelfView: View {
    @EnvironmentObject private var store: HarmonySessionStore
    @State private var filter = MusicShelfFilter()

    private var visibleStates: [RemoteTrackSubjectState] {
        browseTrackSubjectShelf(store.trackSubjectShelf, using: filter)
    }

    var body: some View {
        List {
            Section {
                TextField("Search by song, artist, or album", text: $filter.query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("music-shelf-search")

                Picker("Music shelf scope", selection: $filter.scope) {
                    ForEach(MusicShelfScope.allCases) { scope in
                        Text(scope.compactTitle)
                            .tag(scope)
                            .accessibilityLabel(scope.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("music-shelf-scope")
            }

            Section("Your tracks") {
                if store.isRefreshingTrackSubjectShelf && store.trackSubjectShelf.isEmpty {
                    ProgressView("Loading music shelf…")
                } else if visibleStates.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(filter.query.isEmpty && filter.scope == .all ? "Your music shelf is empty" : "No matching music")
                            .font(.headline)
                        Text(filter.query.isEmpty && filter.scope == .all
                            ? "Music you rate, love, save, or mark listened will appear here."
                            : "Try another search or shelf filter. Your saved music has not been removed.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .accessibilityIdentifier("music-shelf-empty-state")
                } else {
                    ForEach(visibleStates) { state in
                        NavigationLink {
                            OwnerTrackDetailView(initialState: state)
                        } label: {
                            MusicShelfRow(state: state)
                        }
                        .accessibilityIdentifier("music-shelf-open-\(state.canonicalTrackID.uuidString)")
                    }
                }

                if store.hasMoreTrackSubjectShelf {
                    Button {
                        Task { await store.loadMoreTrackSubjectShelf() }
                    } label: {
                        if store.isLoadingMoreTrackSubjectShelf {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Load more")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(store.isLoadingMoreTrackSubjectShelf)
                    .accessibilityIdentifier("music-shelf-load-more")
                }
            }
        }
        .navigationTitle("Music shelf")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("music-shelf-page")
        .task {
#if DEBUG
            guard !ProcessInfo.processInfo.arguments.contains("--ui-test-diary-editor") else { return }
#endif
            await store.refreshTrackSubjectShelf()
        }
        .refreshable { await store.refreshTrackSubjectShelf() }
    }
}

private struct OwnerTrackDetailView: View {
    @EnvironmentObject private var store: HarmonySessionStore
    let initialState: RemoteTrackSubjectState
    let canonicalTrack: RemoteCatalogTrack?
    let track: HarmonyTrack
    @State private var draft: TrackSubjectStateDraft
    @State private var savedDraft: TrackSubjectStateDraft
    @State private var saveMessage: String?
    @State private var showingAddToList = false

    init(initialState: RemoteTrackSubjectState) {
        self.initialState = initialState
        self.canonicalTrack = initialState.canonicalTrack
        let track = initialState.canonicalTrack?.harmonyTrack ?? HarmonyTrack(
            id: initialState.canonicalTrackID,
            title: "Unavailable track",
            artist: "Unknown artist",
            album: "",
            duration: 0,
            symbol: "music.note",
            mappings: []
        )
        self.track = track
        let draft = TrackSubjectStateDraft(state: initialState)
        _draft = State(initialValue: draft)
        _savedDraft = State(initialValue: draft)
    }

    private var relatedDiaryEntries: [RemoteListeningHistoryEntry] {
        store.journalEntries.filter { $0.canonicalTrack?.id == initialState.canonicalTrackID }
    }

    private var relatedReviews: [RemoteMusicReview] {
        store.musicReviews.filter {
            store.isOwnReview($0)
                && $0.subjectKind == "track"
                && $0.canonicalTrack?.id == initialState.canonicalTrackID
        }
    }

    private var isSaving: Bool {
        canonicalTrack.map { store.isSavingTrackSubjectState(for: $0) } ?? false
    }

    private var isDirty: Bool { draft != savedDraft }

    private var listenedBinding: Binding<Bool> {
        Binding(
            get: { draft.hasListened },
            set: { isListened in
                draft.hasListened = isListened
                if isListened { draft.wantToListen = false }
                if !isListened { draft.defaultRating = nil }
                saveMessage = nil
            }
        )
    }

    private var lovedBinding: Binding<Bool> {
        Binding(
            get: { draft.isLoved },
            set: { draft.isLoved = $0; saveMessage = nil }
        )
    }

    private var wantBinding: Binding<Bool> {
        Binding(
            get: { draft.wantToListen },
            set: { wantsToListen in
                draft.wantToListen = wantsToListen
                if wantsToListen {
                    draft.hasListened = false
                    draft.defaultRating = nil
                }
                saveMessage = nil
            }
        )
    }

    private var hasDefaultRating: Binding<Bool> {
        Binding(
            get: { draft.defaultRating != nil },
            set: { isRated in
                draft.defaultRating = isRated ? (draft.defaultRating ?? 4.0) : nil
                if isRated {
                    draft.hasListened = true
                    draft.wantToListen = false
                }
                saveMessage = nil
            }
        )
    }

    private var defaultRating: Binding<Double> {
        Binding(
            get: { draft.defaultRating ?? 4.0 },
            set: { rating in
                draft.defaultRating = rating
                draft.hasListened = true
                draft.wantToListen = false
                saveMessage = nil
            }
        )
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    TrackArtwork(track: track, size: 132, cornerRadius: 18)
                    VStack(spacing: 4) {
                        Text(track.title)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                        Text(track.artist)
                            .font(.headline)
                            .foregroundColor(.secondary)
                        if !track.album.isEmpty {
                            Text(track.album)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .accessibilityIdentifier("owner-track-detail-header")
            }

            Section("Your music") {
                Toggle(isOn: listenedBinding) {
                    Label("Listened", systemImage: draft.hasListened ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .accessibilityIdentifier("owner-track-listened")

                Toggle(isOn: lovedBinding) {
                    Label("Loved", systemImage: draft.isLoved ? "heart.fill" : "heart")
                }
                .accessibilityIdentifier("owner-track-loved")

                Toggle(isOn: wantBinding) {
                    Label("Want to listen", systemImage: draft.wantToListen ? "bookmark.fill" : "bookmark")
                }
                .accessibilityIdentifier("owner-track-want")

                Toggle("Set an overall rating", isOn: hasDefaultRating)
                    .accessibilityIdentifier("owner-track-rating-toggle")
                RatingPicker(rating: defaultRating)
                    .accessibilityLabel(draft.defaultRating == nil ? "Overall rating, unrated" : "Overall rating")
                    .accessibilityIdentifier("owner-track-rating")
                    .disabled(draft.defaultRating == nil)
                    .opacity(draft.defaultRating == nil ? 0.55 : 1)

                Text("This is your current overall rating for the song. Ratings on individual Diary entries are historical snapshots and are never rewritten when this changes.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .accessibilityIdentifier("owner-track-rating-semantics")

                Text("Listened is retained while this song has any listening history or an active review. Remove those records before clearing it here.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .accessibilityIdentifier("owner-track-listened-semantics")

                Button {
                    save()
                } label: {
                    if isSaving {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text("Save music status").frame(maxWidth: .infinity)
                    }
                }
                .disabled(isSaving || !isDirty || canonicalTrack == nil)
                .accessibilityIdentifier("owner-track-save")

                if let saveMessage {
                    Text(saveMessage)
                        .font(.footnote)
                        .foregroundColor(saveMessage.hasPrefix("Saved") ? .secondary : .red)
                        .accessibilityIdentifier("owner-track-save-message")
                }
            }

            Section("Collections") {
                Button {
                    showingAddToList = true
                } label: {
                    Label("Add to a list", systemImage: "text.badge.plus")
                }
                .disabled(canonicalTrack == nil)
                .accessibilityIdentifier("owner-track-add-to-list")

                Text("Adding to a list does not play or queue this song and does not change your Diary or rating.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Diary") {
                if relatedDiaryEntries.isEmpty {
                    Text("No loaded Diary entries for this song yet.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(relatedDiaryEntries) { entry in
                        ActivityDiarySummary(entry: entry)
                            .accessibilityIdentifier("owner-track-diary-\(entry.id.uuidString)")
                    }
                }
            }

            Section("Reviews") {
                if relatedReviews.isEmpty {
                    Text("You have not reviewed this song yet.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(relatedReviews) { review in
                        NavigationLink {
                            ReviewDetailView(reviewID: review.id, fallbackReview: review) { _ in }
                        } label: {
                            ReviewSummary(review: review)
                        }
                        .accessibilityIdentifier("owner-track-review-\(review.id.uuidString)")
                    }
                }
            }
        }
        .navigationTitle(track.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("owner-track-detail-page")
        .task { await refreshCurrentState() }
        .sheet(isPresented: $showingAddToList) {
            AddTrackToMusicListSheet(track: track)
                .environmentObject(store)
        }
    }

    private func save() {
        guard !isSaving, isDirty, let canonicalTrack else { return }
        let submittedDraft = draft.normalizedForSubmission
        Task {
            let didSave = await store.saveTrackSubjectStateDraft(submittedDraft, for: canonicalTrack)
            if didSave {
                let persistedDraft = store.trackSubjectStateDraft(for: canonicalTrack)
                draft = persistedDraft
                savedDraft = persistedDraft
                saveMessage = persistedDraft == submittedDraft
                    ? "Saved"
                    : "Saved. Listened remains on because this song has Diary history or an active review."
            } else {
                saveMessage = store.collaborationMessage.isEmpty
                    ? "Could not save. Your changes are still here—try again."
                    : store.collaborationMessage
            }
        }
    }

    private func refreshCurrentState() async {
        guard let canonicalTrack, !isDirty else { return }
        guard let refreshed = await store.refreshTrackSubjectState(for: canonicalTrack) else { return }
        guard !isDirty else { return }
        let refreshedDraft = TrackSubjectStateDraft(state: refreshed)
        draft = refreshedDraft
        savedDraft = refreshedDraft
    }
}

private struct MusicShelfRow: View {
    let state: RemoteTrackSubjectState

    var body: some View {
        HStack(spacing: 12) {
            if let track = state.canonicalTrack {
                TrackArtwork(track: track.harmonyTrack, size: 48, cornerRadius: 9)
            } else {
                Image(systemName: "music.note")
                    .foregroundColor(.indigo)
                    .frame(width: 48, height: 48)
                    .background(Color.indigo.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(state.canonicalTrack?.title ?? "Unavailable track")
                    .font(.headline)
                if let track = state.canonicalTrack {
                    Text(([track.artist] + [track.album].compactMap { $0 }).filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    if state.hasListened { MusicShelfBadge(title: "Listened", systemImage: "checkmark.circle.fill") }
                    if state.isLoved { MusicShelfBadge(title: "Loved", systemImage: "heart.fill") }
                    if state.wantToListen { MusicShelfBadge(title: "Want to listen", systemImage: "bookmark.fill") }
                    if let rating = state.defaultRating {
                        MusicShelfBadge(title: String(format: "%.1f", rating), systemImage: "star.fill")
                            .accessibilityLabel(Text("Rated \(rating, specifier: "%.1f") out of 5"))
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("music-shelf-row-\(state.canonicalTrackID.uuidString)")
    }
}

private struct MusicShelfBadge: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundColor(.indigo)
            .lineLimit(1)
    }
}

private struct ReviewSubjectPicker: View {
    @EnvironmentObject private var store: HarmonySessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var mode: ReviewPickerMode
    let availableModes: [ReviewPickerMode]
    let onSelect: (ReviewDraftSubject) -> Void

    init(
        availableModes: [ReviewPickerMode] = ReviewPickerMode.allCases,
        onSelect: @escaping (ReviewDraftSubject) -> Void
    ) {
        let modes = availableModes.isEmpty ? [.songs] : availableModes
        self.availableModes = modes
        self.onSelect = onSelect
        _mode = State(initialValue: modes[0])
    }

    private var searchState: CatalogSearchState {
        store.catalogSearchState(for: .reviews)
    }

    private var tracks: [HarmonyTrack] {
        guard !query.isEmpty else { return store.catalog }
        return searchState.results ?? store.catalog.filter {
            "\($0.title) \($0.artist) \($0.album)".localizedCaseInsensitiveContains(query)
        }
    }

    private var albums: [ReviewableAlbum] {
        deduplicatedReviewAlbums(from: tracks)
    }

    var body: some View {
        NavigationStack {
            List {
                if availableModes.count > 1 {
                    Picker("Media type", selection: $mode) {
                        ForEach(availableModes) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                if searchState.isSearching {
                    ProgressView("Searching connected catalogs…")
                } else if let message = searchState.message {
                    Text(message).font(.footnote).foregroundColor(.secondary)
                }

                if mode == .songs {
                    ForEach(tracks) { track in
                        Button {
                            onSelect(.track(track))
                        } label: {
                            HStack(spacing: 12) {
                                TrackArtwork(track: track, size: 42)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.title).font(.headline).foregroundColor(.primary)
                                    Text("\(track.artist) · \(track.album)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .accessibilityLabel("Review song \(track.title) by \(track.artist)")
                    }
                } else if albums.isEmpty, !searchState.isSearching {
                    Text("No albums found for this search.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(albums, id: \.id) { album in
                        Button {
                            onSelect(.album(album))
                        } label: {
                            HStack(spacing: 12) {
                                if let artworkURL = album.artworkURL {
                                    AsyncImage(url: artworkURL) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: {
                                        Image(systemName: "square.stack").foregroundColor(.indigo)
                                    }
                                    .frame(width: 42, height: 42)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                } else {
                                    Image(systemName: "square.stack")
                                        .foregroundColor(.indigo)
                                        .frame(width: 42, height: 42)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(album.title).font(.headline).foregroundColor(.primary)
                                    Text(album.artist)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .accessibilityLabel("Review album \(album.title) by \(album.artist)")
                    }
                }
            }
            .searchable(text: $query, prompt: "Search songs and albums")
            .navigationTitle("Choose music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task(id: query) {
                guard !query.isEmpty else {
                    store.resetCatalogSearch(.reviews)
                    return
                }
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                await store.searchCatalog(query: query, purpose: .reviews)
            }
            .onDisappear { store.resetCatalogSearch(.reviews) }
        }
    }
}

private struct DiaryEntryComposer: View {
    @EnvironmentObject private var store: HarmonySessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: DiaryEntryDraft
    @State private var isChoosingTrack = false

    init(defaultVisibility: SocialVisibilityOption) {
        _draft = State(initialValue: DiaryEntryDraft(visibility: defaultVisibility))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Music") {
                    Button {
                        isChoosingTrack = true
                    } label: {
                        Label(draft.track == nil ? "Choose a song" : "Choose a different song", systemImage: "magnifyingglass")
                    }
                    if let track = draft.track {
                        HStack(spacing: 12) {
                            TrackArtwork(track: track, size: 46, cornerRadius: 9)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title).font(.headline)
                                Text(track.artist).font(.subheadline).foregroundColor(.secondary)
                            }
                        }
                    }
                }

                Section("Listen") {
                    DatePicker("Listened on", selection: $draft.listenedOn, in: ...Date(), displayedComponents: .date)
                    Toggle("Relisten", isOn: $draft.isRelisten)
                    TextField("Tags, separated by commas", text: $draft.tagsText, axis: .vertical)
                        .lineLimit(2...4)
                        .textInputAutocapitalization(.never)
                    if let message = draft.tagValidationMessage {
                        Text(message).font(.footnote).foregroundColor(.red)
                    } else if !draft.normalizedTags.isEmpty {
                        Text(draft.normalizedTags.map { "#\($0)" }.joined(separator: "  "))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    OptionalDiaryRatingControl(
                        rating: $draft.rating,
                        accessibilityPrefix: "diary-create"
                    )
                }

                Section("Visibility") {
                    Picker("Audience", selection: $draft.visibility) {
                        ForEach(SocialVisibilityOption.allCases) { visibility in
                            Text(visibility.title).tag(visibility)
                        }
                    }
                }
            }
            .navigationTitle("Log a listen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let track = draft.track else { return }
                        let submittedDraft = draft
                        Task {
                            let didSave = await store.createDiaryEntry(
                                track: track,
                                listenedOn: submittedDraft.listenedOnForSubmission,
                                isRelisten: submittedDraft.isRelisten,
                                tags: submittedDraft.normalizedTags,
                                rating: submittedDraft.rating,
                                visibility: submittedDraft.visibility
                            )
                            if didSave { dismiss() }
                        }
                    }
                    .disabled(draft.track == nil || draft.tagValidationMessage != nil || store.isSavingDiaryEntry)
                }
            }
        }
        .sheet(isPresented: $isChoosingTrack) {
            ReviewSubjectPicker(availableModes: [.songs]) { subject in
                guard case .track(let track) = subject else { return }
                draft.track = track
                isChoosingTrack = false
            }
            .environmentObject(store)
        }
    }
}

private struct DiaryEntryEditor: View {
    @EnvironmentObject private var store: HarmonySessionStore
    @Environment(\.dismiss) private var dismiss
    let entry: RemoteListeningHistoryEntry
    let compatibleReviews: [RemoteMusicReview]
    @State private var draft: DiaryEntryDraft

    init(entry: RemoteListeningHistoryEntry, compatibleReviews: [RemoteMusicReview]) {
        self.entry = entry
        self.compatibleReviews = compatibleReviews
        let linkedReviewID = entry.reviewID.flatMap { reviewID in
            compatibleReviews.contains(where: { $0.id == reviewID }) ? reviewID : nil
        }
        _draft = State(initialValue: DiaryEntryDraft(
            track: entry.canonicalTrack?.harmonyTrack,
            listenedOn: entry.playedAt,
            isRelisten: entry.isRelisten,
            tagsText: entry.tags.joined(separator: ", "),
            rating: entry.rating,
            visibility: entry.visibility,
            linkedReviewID: linkedReviewID
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Music") {
                    HStack(spacing: 12) {
                        if let track = draft.track {
                            TrackArtwork(track: track, size: 46, cornerRadius: 9)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.canonicalTrack?.title ?? "Unavailable track").font(.headline)
                            if let artist = entry.canonicalTrack?.artist {
                                Text(artist).font(.subheadline).foregroundColor(.secondary)
                            }
                        }
                    }
                }

                Section("Listen") {
                    DatePicker("Listened on", selection: $draft.listenedOn, in: ...Date(), displayedComponents: .date)
                        .accessibilityIdentifier("diary-edit-listened-on")
                    Toggle("Relisten", isOn: $draft.isRelisten)
                        .accessibilityIdentifier("diary-edit-relisten")
                    TextField("Tags, separated by commas", text: $draft.tagsText, axis: .vertical)
                        .lineLimit(2...4)
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("diary-edit-tags")
                    if let message = draft.tagValidationMessage {
                        Text(message).font(.footnote).foregroundColor(.red)
                    } else if !draft.normalizedTags.isEmpty {
                        Text(draft.normalizedTags.map { "#\($0)" }.joined(separator: "  "))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    OptionalDiaryRatingControl(
                        rating: $draft.rating,
                        accessibilityPrefix: "diary-edit"
                    )
                }

                Section("Opinion") {
                    Picker("Linked opinion", selection: $draft.linkedReviewID) {
                        Text("No linked opinion").tag(UUID?.none)
                        ForEach(compatibleReviews) { review in
                            Text("\(review.rating.map { String(format: "%.1f ★", $0) } ?? "No rating") · \(review.subjectTitle ?? review.canonicalTrack?.title ?? "Song review")")
                                .tag(Optional(review.id))
                        }
                    }
                    .accessibilityIdentifier("diary-edit-linked-opinion")
                    if compatibleReviews.isEmpty {
                        Text("No compatible song opinions are available. Harmony only links reviews whose canonical track ID exactly matches this listen.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                Section("Visibility") {
                    Picker("Audience", selection: $draft.visibility) {
                        ForEach(SocialVisibilityOption.allCases) { visibility in
                            Text(visibility.title).tag(visibility)
                        }
                    }
                    .accessibilityIdentifier("diary-edit-audience")
                }
            }
            .navigationTitle("Edit journal entry")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("diary-entry-editor")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save changes") {
                        let submittedDraft = draft
                        Task {
                            let didSave = await store.updateDiaryEntry(
                                entry,
                                listenedOn: submittedDraft.listenedOnForSubmission,
                                isRelisten: submittedDraft.isRelisten,
                                tags: submittedDraft.normalizedTags,
                                rating: submittedDraft.rating,
                                visibility: submittedDraft.visibility,
                                reviewID: submittedDraft.linkedReviewID
                            )
                            if didSave { dismiss() }
                        }
                    }
                    .accessibilityIdentifier("diary-edit-save")
                    .disabled(draft.tagValidationMessage != nil || store.isSavingDiaryEntry)
                }
            }
        }
    }
}

struct OptionalReviewRatingControl: View {
    @Binding var rating: Double?
    let accessibilityPrefix: String

    private var isRating: Binding<Bool> {
        Binding(
            get: { rating != nil },
            set: { enabled in rating = enabled ? (rating ?? 4.0) : nil }
        )
    }

    private var selectedRating: Binding<Double> {
        Binding(
            get: { rating ?? 4.0 },
            set: { rating = $0 }
        )
    }

    var body: some View {
        Toggle("Add a rating", isOn: isRating)
            .accessibilityIdentifier("\(accessibilityPrefix)-rating-toggle")
        if rating != nil {
            RatingPicker(rating: selectedRating)
                .accessibilityLabel("Review rating")
                .accessibilityIdentifier("\(accessibilityPrefix)-rating")
        } else {
            Text("No rating")
                .font(.footnote)
                .foregroundColor(.secondary)
                .accessibilityIdentifier("\(accessibilityPrefix)-no-rating")
        }
    }
}

private struct OptionalDiaryRatingControl: View {
    @Binding var rating: Double?
    let accessibilityPrefix: String

    private var isRating: Binding<Bool> {
        Binding(
            get: { rating != nil },
            set: { enabled in rating = enabled ? (rating ?? 4.0) : nil }
        )
    }

    private var selectedRating: Binding<Double> {
        Binding(
            get: { rating ?? 4.0 },
            set: { rating = $0 }
        )
    }

    var body: some View {
        Toggle("Rate this listen", isOn: isRating)
            .accessibilityIdentifier("\(accessibilityPrefix)-rating-toggle")
        RatingPicker(rating: selectedRating)
            .accessibilityLabel(rating == nil ? "Diary rating, unrated" : "Diary rating")
            .accessibilityIdentifier("\(accessibilityPrefix)-rating")
            .disabled(rating == nil)
            .opacity(rating == nil ? 0.55 : 1)
    }
}

struct RatingPicker: View {
    @Binding var rating: Double

    var body: some View {
        Stepper(value: $rating, in: 0.5...5, step: 0.5) {
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    ForEach(1...5, id: \.self) { star in
                        Image(systemName: symbol(for: Double(star)))
                            .foregroundColor(.orange)
                    }
                }
                Text(String(format: "%.1f", rating))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
            }
        }
        .accessibilityLabel("Rating")
        .accessibilityValue("\(String(format: "%.1f", rating)) out of 5")
    }

    private func symbol(for star: Double) -> String {
        if rating >= star { return "star.fill" }
        if rating >= star - 0.5 { return "star.leadinghalf.filled" }
        return "star"
    }
}

struct ReviewCard: View {
    @EnvironmentObject private var store: HarmonySessionStore
    let review: RemoteMusicReview
    let onEdit: ((RemoteMusicReview) -> Void)?
    @State private var showingDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink {
                ReviewDetailView(reviewID: review.id, fallbackReview: review, onEdit: onEdit)
            } label: {
                ReviewSummary(review: review)
            }
            .buttonStyle(.plain)

            HStack {
                Label("\(review.heartCount)", systemImage: "heart")
                Label("\(review.commentCount)", systemImage: "bubble.left")
                Text(review.createdAt, format: .dateTime.month().day().year())
                Spacer()
                Text("Read review")
                Image(systemName: "chevron.right")
            }
            .font(.caption)
            .foregroundColor(.secondary)

            if store.isOwnReview(review) {
                HStack {
                    Spacer()
                    Menu {
                        if let onEdit {
                            Button("Edit review") { onEdit(review) }
                        }
                        Button("Delete review", role: .destructive) { showingDeleteConfirmation = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("Review options")
                }
            }
        }
        .disabled(store.mutatingReviewIDs.contains(review.id))
        .confirmationDialog("Delete this review?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete review", role: .destructive) { Task { await store.deleteReview(review.id) } }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct SubjectRatingDistributionView: View {
    let ratings: [Double]
    let label: String

    private var buckets: [MusicRatingDistributionBucket] {
        musicRatingDistribution(ratings: ratings)
    }

    private var maximumCount: Int {
        max(1, buckets.map(\.count).max() ?? 1)
    }

    private var average: Double {
        return ratings.reduce(0, +) / Double(max(1, ratings.count))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(String(format: "%.2f", average))
                        .font(.title2.weight(.bold))
                    Text("Average of \(label)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text("\(ratings.count) rated")
                    .font(.subheadline.weight(.semibold))
            }

            HStack(alignment: .bottom, spacing: 4) {
                ForEach(buckets) { bucket in
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.orange)
                            .frame(
                                height: bucket.count == 0
                                    ? 2
                                    : max(5, 56 * CGFloat(bucket.count) / CGFloat(maximumCount))
                            )
                        if bucket.rating == 0.5 || bucket.rating == 2.5 || bucket.rating == 5.0 {
                            Text(bucket.rating.formatted(.number.precision(.fractionLength(1))))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        } else {
                            Text(" ").font(.caption2)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(bucket.rating, specifier: "%.1f") stars")
                    .accessibilityValue("\(bucket.count) ratings")
                }
            }
            .frame(height: 78, alignment: .bottom)
        }
        .accessibilityIdentifier("ratings-distribution")
    }
}

private struct TrackRatingRow: View {
    let state: RemoteTrackSubjectState

    var body: some View {
        HStack(spacing: 12) {
            if let track = state.canonicalTrack {
                TrackArtwork(track: track.harmonyTrack, size: 44, cornerRadius: 8)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(state.canonicalTrack?.title ?? "Unavailable song").font(.headline)
                Text(state.canonicalTrack?.artist ?? "Unknown artist")
                    .font(.caption).foregroundColor(.secondary)
                Text("Song").font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
            RatingStatus(rating: state.defaultRating, isLoved: state.isLoved)
        }
    }
}

private struct AlbumRatingRow: View {
    let state: RemoteAlbumSubjectState

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let artwork = state.canonicalAlbum?.artworkURL {
                    AsyncImage(url: artwork) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() }
                        else { Image(systemName: "square.stack").foregroundColor(.secondary) }
                    }
                } else {
                    Image(systemName: "square.stack").foregroundColor(.secondary)
                }
            }
            .frame(width: 44, height: 44)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(state.canonicalAlbum?.title ?? "Unavailable album").font(.headline)
                Text(state.canonicalAlbum?.artist ?? "Unknown artist")
                    .font(.caption).foregroundColor(.secondary)
                Text("Album").font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
            RatingStatus(rating: state.defaultRating, isLoved: state.isLoved)
        }
    }
}

private struct RatingStatus: View {
    let rating: Double?
    let isLoved: Bool

    var body: some View {
        HStack(spacing: 5) {
            if let rating {
                Text("\(rating, specifier: "%.1f") ★")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.orange)
            }
            if isLoved {
                Image(systemName: "heart.fill")
                    .foregroundColor(.pink)
                    .accessibilityLabel("Loved")
            }
        }
    }
}

private struct ReviewSummary: View {
    let review: RemoteMusicReview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(review.profile.displayName)
                    .font(.headline)
                if let rating = review.rating {
                    Text("\(String(format: "%.1f", rating)) ★")
                        .font(.headline)
                        .foregroundColor(.orange)
                } else {
                    Text("No rating")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                if review.isLoved {
                    Image(systemName: "heart.fill")
                        .foregroundColor(.pink)
                        .accessibilityLabel("Loved")
                }
            }

            ReviewSubjectSummary(review: review)

            if review.containsSpoilers {
                Label("Contains spoilers", systemImage: "eye.slash")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else if !review.body.isEmpty {
                Text(review.body)
                    .lineLimit(3)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityHint("Opens the full review, reactions, and comments")
    }
}

private struct ReviewSubjectSummary: View {
    let review: RemoteMusicReview

    var body: some View {
        HStack(spacing: 10) {
            if let artworkURL = review.canonicalTrack?.artworkURL
                ?? review.canonicalAlbum?.artworkURL
                ?? review.subjectArtworkURL {
                AsyncImage(url: artworkURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: review.subjectKind == "album" ? "square.stack" : "music.note")
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(review.canonicalTrack?.title ?? review.canonicalAlbum?.title ?? review.subjectTitle ?? "Unavailable music")
                    .font(.subheadline.weight(.semibold))
                Text(review.canonicalTrack?.artist ?? review.canonicalAlbum?.artist ?? review.subjectArtist ?? "Unknown artist")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(review.subjectKind.capitalized)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }
}

private struct ReviewDetailView: View {
    @EnvironmentObject private var store: HarmonySessionStore
    @Environment(\.dismiss) private var dismiss
    let reviewID: UUID
    let fallbackReview: RemoteMusicReview
    let onEdit: ((RemoteMusicReview) -> Void)?
    @State private var commentDraft = ""
    @State private var isShowingSpoilers = false
    @State private var showingDeleteConfirmation = false

    private var review: RemoteMusicReview {
        store.review(withID: reviewID) ?? fallbackReview
    }

    private var engagementDetail: ReviewDetailEngagementState {
        store.reviewEngagementDetail(for: reviewID)
    }

    var body: some View {
        List {
            Section {
                if let album = review.canonicalAlbum {
                    NavigationLink {
                        CanonicalAlbumDetailView(
                            album: album,
                            initialState: store.albumSubjectState(for: album)
                        )
                    } label: {
                        ReviewSubjectSummary(review: review)
                    }
                    .accessibilityIdentifier("review-open-canonical-album-\(album.id.uuidString)")
                } else {
                    ReviewSubjectSummary(review: review)
                }
                HStack(spacing: 8) {
                    NavigationLink {
                        MemberProfileView(
                            profileID: review.profileID,
                            displayName: review.profile.displayName
                        )
                    } label: {
                        Label(review.profile.displayName, systemImage: "person.crop.circle")
                            .font(.headline)
                    }
                    .accessibilityIdentifier("review-author-\(review.profileID.uuidString)")
                    if let rating = review.rating {
                        Text("\(String(format: "%.1f", rating)) ★")
                            .foregroundColor(.orange)
                    } else {
                        Text("No rating")
                            .foregroundColor(.secondary)
                    }
                    if review.isLoved {
                        Label("Loved", systemImage: "heart.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.pink)
                    }
                }

                if review.containsSpoilers && !isShowingSpoilers {
                    Button {
                        isShowingSpoilers = true
                    } label: {
                        Label("Reveal review — contains spoilers", systemImage: "eye.slash")
                    }
                    .accessibilityHint("Shows the hidden review text")
                } else if !review.body.isEmpty {
                    Text(review.body)
                        .textSelection(.enabled)
                }

                if let deepLink = review.subjectDeepLink {
                    Link(destination: deepLink) {
                        Label("Open in music provider", systemImage: "arrow.up.right.square")
                    }
                }
            }

            Section("Reactions") {
                Button { Task { await store.toggleReviewHeart(review.id) } } label: {
                    Label(
                        store.hasHeart(on: review.id) ? "Remove heart" : "Heart this review",
                        systemImage: store.hasHeart(on: review.id) ? "heart.fill" : "heart"
                    )
                }
                if let engagement = engagementDetail.engagement {
                    Text("\(engagement.heartCount) hearts")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ProgressView("Loading reactions…")
                }
            }

            Section("Comments") {
                if (engagementDetail.isRefreshing || engagementDetail.comments.isRefreshing)
                    && engagementDetail.comments.items.isEmpty {
                    ProgressView("Loading comments…")
                } else if engagementDetail.comments.items.isEmpty {
                    Text("No comments yet. Start the conversation.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(engagementDetail.comments.items) { comment in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(comment.profile.displayName).font(.caption.bold())
                                Text(comment.body)
                            }
                            Spacer()
                            if store.canDeleteReviewComment(comment, from: review) {
                                Button(role: .destructive) {
                                    Task { await store.deleteReviewComment(comment, from: review) }
                                } label: {
                                    Image(systemName: "trash").font(.caption)
                                }
                                .accessibilityLabel(
                                    store.isOwnComment(comment)
                                        ? "Delete your comment"
                                        : "Remove comment from your review"
                                )
                                .accessibilityIdentifier("review-comment-delete-\(comment.id.uuidString)")
                            }
                        }
                    }
                }

                if engagementDetail.comments.hasMore {
                    Button {
                        Task { await store.loadMoreReviewComments(review.id) }
                    } label: {
                        if engagementDetail.comments.isLoadingMore {
                            ProgressView("Loading older comments…")
                        } else {
                            Label("Load older comments", systemImage: "arrow.down.circle")
                        }
                    }
                    .disabled(engagementDetail.comments.isLoadingMore)
                    .accessibilityIdentifier("review-comments-load-more")
                }

                HStack {
                    TextField("Add a comment", text: $commentDraft, axis: .vertical)
                        .lineLimit(1...4)
                    Button {
                        let body = commentDraft
                        Task {
                            if await store.addReviewComment(to: review.id, body: body) {
                                commentDraft = ""
                            }
                        }
                    } label: {
                        Image(systemName: "paperplane.fill")
                    }
                    .disabled(commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Post comment")
                }
            }
        }
        .navigationTitle(review.canonicalTrack?.title ?? review.canonicalAlbum?.title ?? review.subjectTitle ?? "Review")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(store.mutatingReviewIDs.contains(review.id))
        .task(id: reviewID) {
            await store.refreshReviewDetail(reviewID)
        }
        .toolbar {
            if store.isOwnReview(review) {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if let onEdit {
                            Button("Edit review") { onEdit(review) }
                        }
                        Button("Delete review", role: .destructive) { showingDeleteConfirmation = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Review options")
                }
            }
        }
        .confirmationDialog("Delete this review?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete review", role: .destructive) {
                Task {
                    if await store.deleteReview(review.id) { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private extension RemoteCatalogTrack {
    var harmonyTrack: HarmonyTrack {
        HarmonyTrack(
            id: id ?? UUID(),
            canonicalTrackID: id,
            title: title,
            artist: artist,
            album: album ?? "",
            duration: TimeInterval(durationMilliseconds ?? 0) / 1000,
            symbol: "music.note",
            artworkURL: artworkURL,
            isExplicit: isExplicit,
            isrc: isrc,
            mappings: []
        )
    }
}
