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
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(review.profile.displayName) · \(String(format: "%.1f", review.rating)) ★").font(.headline)
                                if let track = review.canonicalTrack {
                                    Text("\(track.title) · \(track.artist)").font(.subheadline).foregroundColor(.secondary)
                                }
                                if !review.body.isEmpty { Text(review.body) }
                                Button {
                                    Task { await store.toggleReviewHeart(review.id) }
                                } label: {
                                    Label("React", systemImage: "heart")
                                        .font(.caption)
                                }
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
                await store.refreshMusicReviews()
            }
            .refreshable {
                await store.refreshSocialProfiles()
                await store.refreshListeningFeed()
                await store.refreshMusicReviews()
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
