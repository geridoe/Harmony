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
                Section("Eavesdrop") {
                    Text("Share the current Harmony track with approved followers for five minutes. Harmony shares activity and provider links, never audio.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Button {
                        Task { await store.toggleEavesdropping() }
                    } label: {
                        if store.isPublishingListeningPresence {
                            ProgressView()
                        } else {
                            Label(
                                store.isEavesdropping ? "Stop sharing now listening" : "Share now listening",
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
                        Button("Publish review to followers") {
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
            .task { await store.refreshListeningFeed(); await store.refreshMusicReviews() }
            .refreshable { await store.refreshListeningFeed(); await store.refreshMusicReviews() }
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
