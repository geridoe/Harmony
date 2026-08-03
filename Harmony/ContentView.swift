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
        NavigationView {
            List {
                Section {
                    if store.socialNotifications.isEmpty {
                        Text("No social notifications yet.").foregroundColor(.secondary)
                    } else {
                        ForEach(store.socialNotifications) { notification in
                            Button {
                                guard notification.readAt == nil else { return }
                                Task { await store.markSocialNotificationsRead(notification.id) }
                            } label: {
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
                            .buttonStyle(.plain)
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

                Section("People") {
                    if store.isRefreshingSocialProfiles && store.socialProfiles.isEmpty {
                        ProgressView("Loading people…")
                    } else if store.socialProfiles.isEmpty {
                        Text("No other Harmony listeners are available yet.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(store.socialProfiles) { profile in
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
                    if store.isRefreshingListeningFeed && store.listeningFeed.isEmpty {
                        ProgressView("Loading listener activity…")
                    } else if store.listeningFeed.isEmpty {
                        Text("No approved listeners are sharing activity right now.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(store.listeningFeed) { presence in
                            HStack(spacing: 12) {
                                if let track = presence.canonicalTrack {
                                    TrackArtwork(track: track.harmonyTrack, size: 42, cornerRadius: 10)
                                } else {
                                    Image(systemName: "music.note")
                                        .frame(width: 42, height: 42)
                                        .background(Color.indigo.opacity(0.12))
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(presence.profile.displayName).font(.headline)
                                    Text(presence.canonicalTrack.map { "\($0.title) · \($0.artist)" } ?? "Listening privately")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                    Text(presence.status == "paused" ? "Paused" : "Listening now")
                                        .font(.caption)
                                        .foregroundColor(.indigo)
                                }
                                Spacer()
                                if let deepLink = presence.providerDeepLink {
                                    Link(destination: deepLink) {
                                        Image(systemName: "arrow.up.right.square")
                                    }
                                    .accessibilityLabel("Open in connected provider")
                                }
                            }
                        }
                    }
                }

                Section("Listening history") {
                    Button {
                        Task { await store.recordCurrentTrackInHistory() }
                    } label: {
                        if store.isRecordingListeningHistory {
                            ProgressView()
                        } else {
                            Label(
                                store.historySocialVisibility == .followers ? "Log current track for followers" : "Log current track privately",
                                systemImage: "clock.arrow.circlepath"
                            )
                        }
                    }
                    .disabled(store.nowPlaying == nil || store.isRecordingListeningHistory)

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
                                            Image(systemName: entry.visibility == .followers ? "person.2.fill" : "lock.fill")
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
        default: "bell.fill"
        }
    }

    private func notificationMessage(_ notification: RemoteSocialNotification) -> String {
        let actor = notification.actor.displayName
        let reviewTitle = notification.review?.subjectTitle
            ?? notification.review?.canonicalTrack?.title
            ?? "your review"
        switch notification.kind {
        case "follow_request": return "\(actor) wants to follow you"
        case "follow_accepted": return "\(actor) accepted your follow request"
        case "review_comment": return "\(actor) commented on \(reviewTitle)"
        case "review_reaction": return "\(actor) reacted to \(reviewTitle)"
        default: return "New activity from \(actor)"
        }
    }
}

private enum ReviewsShelf: String, CaseIterable, Identifiable {
    case community = "Community"
    case journal = "My journal"
    var id: String { rawValue }
}

private enum ReviewDraftSubject: Hashable {
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

struct ReviewsView: View {
    @EnvironmentObject private var store: HarmonySessionStore
    @State private var shelf = ReviewsShelf.community
    @State private var rating = 4.0
    @State private var isLoved = false
    @State private var containsSpoilers = false
    @State private var reviewBody = ""
    @State private var reviewSubject: ReviewDraftSubject?
    @State private var isChoosingReviewSubject = false
    @State private var editingReview: RemoteMusicReview?
    @State private var editingRating = 4.0
    @State private var editingBody = ""
    @State private var editingVisibility = SocialVisibilityOption.privateOnly
    @State private var editingIsLoved = false
    @State private var editingContainsSpoilers = false

    private var ownReviews: [RemoteMusicReview] {
        store.musicReviews.filter(store.isOwnReview)
    }

    private var ownHistory: [RemoteListeningHistoryEntry] {
        store.listeningHistory.filter(store.isOwnHistoryEntry)
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
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                if shelf == .community {
                    reviewComposer
                    communityReviews
                } else {
                    listeningJournal
                    personalReviews
                }
            }
            .navigationTitle("Reviews")
            .task {
                await store.refreshAccountSettings()
                await store.refreshListeningHistory()
                await store.refreshMusicReviews()
                await store.activateSocialRealtime()
            }
            .refreshable {
                await store.refreshListeningHistory()
                await store.refreshMusicReviews()
            }
        }
        .sheet(item: $editingReview) { review in
            NavigationStack {
                Form {
                    Section("Rating") {
                        RatingPicker(rating: $editingRating)
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
                    }
                }
            }
        }
        .sheet(isPresented: $isChoosingReviewSubject) {
            ReviewSubjectPicker { subject in
                reviewSubject = subject
                rating = 4
                isLoved = false
                containsSpoilers = false
                reviewBody = ""
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
                Label(reviewSubject == nil ? "Choose a song or album" : "Choose different music", systemImage: "magnifyingglass")
            }

            if let subject = reviewSubject ?? store.nowPlaying.map({ .track($0.track) }) {
                HStack(spacing: 12) {
                    reviewSubjectArtwork(subject)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(subject.title).font(.headline)
                        Text(subject.artist).font(.subheadline).foregroundColor(.secondary)
                        Text(subject.kind).font(.caption).foregroundColor(.secondary)
                    }
                }
                RatingPicker(rating: $rating)
                Toggle(isOn: $isLoved) {
                    Label("Loved", systemImage: isLoved ? "heart.fill" : "heart")
                }
                Toggle("Contains spoilers", isOn: $containsSpoilers)
                TextField("Write your review (optional)", text: $reviewBody, axis: .vertical)
                    .lineLimit(3...8)
                Button(store.reviewsSocialVisibility == .followers ? "Publish to followers" : "Save private review") {
                    let selectedSubject = subject
                    let body = reviewBody
                    let loved = isLoved
                    let spoilers = containsSpoilers
                    Task {
                        let didPublish: Bool
                        switch selectedSubject {
                        case .track(let track):
                            didPublish = await store.publishTrackReview(
                                track,
                                rating: rating,
                                body: body,
                                isLoved: loved,
                                containsSpoilers: spoilers
                            )
                        case .album(let album):
                            didPublish = await store.publishAlbumReview(
                                album,
                                rating: rating,
                                body: body,
                                isLoved: loved,
                                containsSpoilers: spoilers
                            )
                        }
                        if didPublish {
                            reviewBody = ""
                            isLoved = false
                            containsSpoilers = false
                        }
                    }
                }
                .disabled(store.isPublishingMusicReview)
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

    private var communityReviews: some View {
        Section("Recent reviews") {
            if store.isRefreshingMusicReviews && store.musicReviews.isEmpty {
                ProgressView("Loading reviews…")
            } else if store.musicReviews.isEmpty {
                Text("No follower-visible reviews yet.").foregroundColor(.secondary)
            } else {
                ForEach(store.musicReviews) { review in reviewCard(review) }
            }
        }
    }

    private var listeningJournal: some View {
        Section("Listening journal") {
            Button {
                Task { await store.recordCurrentTrackInHistory() }
            } label: {
                if store.isRecordingListeningHistory {
                    ProgressView()
                } else {
                    Label("Log the current track", systemImage: "plus.circle")
                }
            }
            .disabled(store.nowPlaying == nil || store.isRecordingListeningHistory)

            if store.isRefreshingListeningHistory && ownHistory.isEmpty {
                ProgressView("Loading your journal…")
            } else if ownHistory.isEmpty {
                Text("Your dated listens will appear here. Logging and reviewing are separate, so you can revisit music without rewriting your opinion.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                ForEach(ownHistory.prefix(25)) { entry in
                    HStack(spacing: 12) {
                        if let track = entry.canonicalTrack {
                            TrackArtwork(track: track.harmonyTrack, size: 40, cornerRadius: 8)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.canonicalTrack.map { "\($0.title) · \($0.artist)" } ?? "Unavailable track")
                                .font(.subheadline.weight(.semibold))
                            Text(entry.playedAt, format: .dateTime.month().day().year().hour().minute())
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: entry.visibility == .followers ? "person.2.fill" : "lock.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .accessibilityLabel(entry.visibility.title)
                    }
                }
            }
        }
    }

    private var personalReviews: some View {
        Section("My reviews") {
            if ownReviews.isEmpty {
                Text("Your ratings and reviews will appear here independently of your listening journal.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                ForEach(ownReviews) { review in reviewCard(review) }
            }
        }
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

private struct ReviewSubjectPicker: View {
    @EnvironmentObject private var store: HarmonySessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    let onSelect: (ReviewDraftSubject) -> Void

    private var tracks: [HarmonyTrack] {
        guard !query.isEmpty else { return store.catalog }
        return store.catalogSearchResults ?? store.catalog.filter {
            "\($0.title) \($0.artist) \($0.album)".localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if store.isSearchingCatalog {
                    ProgressView("Searching connected catalogs…")
                } else if let message = store.catalogSearchMessage {
                    Text(message).font(.footnote).foregroundColor(.secondary)
                }

                ForEach(tracks) { track in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            TrackArtwork(track: track, size: 42)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title).font(.headline)
                                Text("\(track.artist) · \(track.album)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        HStack {
                            Button("Review song") { onSelect(.track(track)) }
                                .buttonStyle(.borderedProminent)
                            if let album = track.reviewableAlbum {
                                Button("Review album") { onSelect(.album(album)) }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding(.vertical, 4)
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
                    await store.searchCatalog(query: "")
                    return
                }
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                await store.searchCatalog(query: query)
            }
        }
    }
}

private struct RatingPicker: View {
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

private struct ReviewCard: View {
    @EnvironmentObject private var store: HarmonySessionStore
    let review: RemoteMusicReview
    let onEdit: (RemoteMusicReview) -> Void
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
                Label("\(review.reactions.filter { $0.kind == "heart" }.count)", systemImage: "heart")
                Label("\(review.comments.count)", systemImage: "bubble.left")
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
                        Button("Edit review") { onEdit(review) }
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

private struct ReviewSummary: View {
    let review: RemoteMusicReview

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("\(review.profile.displayName) · \(String(format: "%.1f", review.rating)) ★")
                    .font(.headline)
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
            if let artworkURL = review.canonicalTrack?.artworkURL ?? review.subjectArtworkURL {
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
                Text(review.canonicalTrack?.title ?? review.subjectTitle ?? "Unavailable music")
                    .font(.subheadline.weight(.semibold))
                Text(review.canonicalTrack?.artist ?? review.subjectArtist ?? "Unknown artist")
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
    let onEdit: (RemoteMusicReview) -> Void
    @State private var commentDraft = ""
    @State private var isShowingSpoilers = false
    @State private var showingDeleteConfirmation = false

    private var review: RemoteMusicReview {
        store.musicReviews.first(where: { $0.id == reviewID }) ?? fallbackReview
    }

    var body: some View {
        List {
            Section {
                ReviewSubjectSummary(review: review)
                HStack(spacing: 8) {
                    Text(review.profile.displayName).font(.headline)
                    Text("\(String(format: "%.1f", review.rating)) ★")
                        .foregroundColor(.orange)
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
                        store.hasHeart(on: review) ? "Remove heart" : "Heart this review",
                        systemImage: store.hasHeart(on: review) ? "heart.fill" : "heart"
                    )
                }
                Text("\(review.reactions.filter { $0.kind == "heart" }.count) hearts")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Comments") {
                if review.comments.isEmpty {
                    Text("No comments yet. Start the conversation.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(review.comments) { comment in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(comment.profile.displayName).font(.caption.bold())
                                Text(comment.body)
                            }
                            Spacer()
                            if store.isOwnComment(comment) {
                                Button(role: .destructive) {
                                    Task { await store.deleteReviewComment(comment.id, from: review.id) }
                                } label: {
                                    Image(systemName: "trash").font(.caption)
                                }
                                .accessibilityLabel("Delete comment")
                            }
                        }
                    }
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
        .navigationTitle(review.canonicalTrack?.title ?? review.subjectTitle ?? "Review")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(store.mutatingReviewIDs.contains(review.id))
        .toolbar {
            if store.isOwnReview(review) {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Edit review") { onEdit(review) }
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
            title: title,
            artist: artist,
            album: album ?? "",
            duration: TimeInterval(durationMilliseconds ?? 0) / 1000,
            symbol: "music.note",
            artworkURL: artworkURL,
            isExplicit: isExplicit,
            mappings: []
        )
    }
}
