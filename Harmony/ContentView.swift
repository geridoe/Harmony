//
//  ContentView.swift
//  Harmony
//
//  Created by Geri Doe on 7/25/22.
//

import SwiftUI
struct ContentView: View {
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
    @State private var rating = 4.0
    @State private var reviewBody = ""
    @State private var editingReview: RemoteMusicReview?
    @State private var editingRating = 4.0
    @State private var editingBody = ""
    @State private var editingVisibility = SocialVisibilityOption.privateOnly

    var body: some View {
        NavigationView {
            List {
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

                Section("Your diary") {
                    if let track = store.nowPlaying?.track {
                        Text("Reviewing: \(track.title) · \(track.artist)")
                            .font(.subheadline)
                        HStack {
                            Text("Rating")
                            Slider(value: $rating, in: 0.5...5, step: 0.5)
                            Text(String(format: "%.1f", rating))
                                .monospacedDigit()
                        }
                        TextField("Write a short review (optional)", text: $reviewBody, axis: .vertical)
                            .lineLimit(2...5)
                        Button(store.reviewsSocialVisibility == .followers ? "Publish review to followers" : "Save private review") {
                            Task {
                                await store.publishTrackReview(rating: rating, body: reviewBody)
                                reviewBody = ""
                            }
                        }
                        .disabled(store.isPublishingMusicReview)
                    } else {
                        Text("Start a Harmony track to write a review.").foregroundColor(.secondary)
                    }
                }

                Section("Reviews") {
                    if store.isRefreshingMusicReviews && store.musicReviews.isEmpty {
                        ProgressView("Loading reviews…")
                    } else if store.musicReviews.isEmpty {
                        Text("No follower-visible reviews yet.").foregroundColor(.secondary)
                    } else {
                        ForEach(store.musicReviews) { review in
                            ReviewCard(review: review) { selected in
                                editingReview = selected
                                editingRating = selected.rating
                                editingBody = selected.body
                                editingVisibility = selected.visibility
                            }
                        }
                    }
                }
            }
            .navigationTitle("Listen")
            .task {
                await store.refreshAccountSettings()
                await store.refreshSocialProfiles()
                await store.refreshListeningFeed()
                await store.refreshListeningHistory()
                await store.refreshMusicReviews()
            }
            .refreshable {
                await store.refreshSocialProfiles()
                await store.refreshListeningFeed()
                await store.refreshListeningHistory()
                await store.refreshMusicReviews()
            }
        }
        .sheet(item: $editingReview) { review in
            NavigationView {
                Form {
                    Section("Rating") {
                        HStack {
                            Slider(value: $editingRating, in: 0.5...5, step: 0.5)
                            Text(String(format: "%.1f", editingRating)).monospacedDigit()
                        }
                    }
                    Section("Review") {
                        TextField("Review text", text: $editingBody, axis: .vertical).lineLimit(3...10)
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
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editingReview = nil } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            editingReview = nil
                            Task { await store.updateReview(review.id, rating: editingRating, body: editingBody, visibility: editingVisibility) }
                        }
                    }
                }
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
}

private struct ReviewCard: View {
    @EnvironmentObject private var store: HarmonySessionStore
    let review: RemoteMusicReview
    let onEdit: (RemoteMusicReview) -> Void
    @State private var commentDraft = ""
    @State private var showingDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(review.profile.displayName) · \(String(format: "%.1f", review.rating)) ★").font(.headline)
            if let track = review.canonicalTrack {
                Text("\(track.title) · \(track.artist)").font(.subheadline).foregroundColor(.secondary)
            }
            if !review.body.isEmpty { Text(review.body) }
            if !review.comments.isEmpty {
                Divider()
                ForEach(review.comments) { comment in
                    HStack(alignment: .top) {
                        Text("\(comment.profile.displayName):").font(.caption.bold())
                        Text(comment.body).font(.caption)
                        Spacer()
                        if store.isOwnComment(comment) {
                            Button(role: .destructive) {
                                Task { await store.deleteReviewComment(comment.id, from: review.id) }
                            } label: { Image(systemName: "trash").font(.caption) }
                            .accessibilityLabel("Delete comment")
                        }
                    }
                }
            }
            HStack {
                TextField("Add a comment", text: $commentDraft)
                    .textFieldStyle(.roundedBorder)
                Button {
                    let body = commentDraft
                    commentDraft = ""
                    Task { await store.addReviewComment(to: review.id, body: body) }
                } label: { Image(systemName: "paperplane.fill") }
                .disabled(commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Post comment")
            }
            HStack {
                Button { Task { await store.toggleReviewHeart(review.id) } } label: {
                    Label("\(review.reactions.filter { $0.kind == "heart" }.count)", systemImage: store.hasHeart(on: review) ? "heart.fill" : "heart")
                }
                .font(.caption)
                if store.isOwnReview(review) {
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
