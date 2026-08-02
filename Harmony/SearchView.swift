import SwiftUI

struct TrackArtwork: View {
    let track: HarmonyTrack
    let size: CGFloat
    var cornerRadius: CGFloat = 8

    var body: some View {
        Group {
            if let artworkURL = track.artworkURL {
                AsyncImage(url: artworkURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .background(Color.indigo.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private var fallback: some View {
        Image(systemName: track.symbol).foregroundColor(.indigo)
    }
}

struct SearchView: View {
    @EnvironmentObject private var store: HarmonySessionStore
    @State private var query = ""

    private var tracks: [HarmonyTrack] {
        guard !query.isEmpty else { return store.catalog }
        return store.catalogSearchResults ?? store.catalog.filter {
            "\($0.title) \($0.artist) \($0.album)".localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationView {
            List {
                if store.isSearchingCatalog {
                    HStack {
                        ProgressView()
                        Text("Searching Spotify…").foregroundColor(.secondary)
                    }
                } else if let message = store.catalogSearchMessage {
                    Text(message).font(.footnote).foregroundColor(.secondary)
                }
                ForEach(tracks) { track in
                    HStack {
                        TrackArtwork(track: track, size: 36)
                        VStack(alignment: .leading) {
                            Text(track.title).font(.headline)
                            Text("\(track.artist) · \(track.album)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            HStack {
                                ForEach(MusicProvider.allCases) { provider in
                                    Text("\(provider.name): \(track.availability(for: provider).label)")
                                        .font(.caption2)
                                        .foregroundColor(track.availability(for: provider) == .unavailable ? .secondary : .indigo)
                                }
                            }
                        }
                        Spacer()
                        Button { store.add(track) } label: {
                            Image(systemName: "plus.circle.fill").font(.title3)
                        }
                        .disabled(store.queue.contains { $0.track.title == track.title && $0.track.artist == track.artist })
                    }
                }
            }
            .searchable(text: $query, prompt: "Search connected catalogs")
            .navigationTitle("Add music")
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

struct ConnectionsView: View {
    @EnvironmentObject private var store: HarmonySessionStore
    var body: some View {
        NavigationView {
            List {
                Section("Your listening services") {
                    ForEach(MusicProvider.allCases) { provider in
                        let state = store.providerState(for: provider)
                        HStack {
                            Image(systemName: provider == .appleMusic ? "apple.logo" : "waveform")
                                .font(.title2)
                                .frame(width: 36)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(provider.name).font(.headline)
                                Text(detail(for: provider, state: state))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if provider == .spotify {
                                if state != .connected {
                                    Button(store.isConnectingSpotify ? "Connecting…" : "Connect") {
                                        Task { await store.connectSpotify() }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(store.isConnectingSpotify)
                                } else if !store.spotifyPlaybackConnection.isConnected {
                                    Button {
                                        Task { await store.enableSpotifyPlayback() }
                                    } label: {
                                        if store.isConnectingSpotifyPlayback {
                                            ProgressView()
                                                .controlSize(.small)
                                        } else {
                                            Text("Enable playback")
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(store.isConnectingSpotifyPlayback)
                                } else {
                                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                                }
                                if state == .connected {
                                    Menu {
                                        Button("Disconnect Spotify", role: .destructive) {
                                            Task { await store.disconnectSpotify() }
                                        }
                                    } label: {
                                        if store.isDisconnectingSpotify {
                                            ProgressView().controlSize(.small)
                                        } else {
                                            Image(systemName: "ellipsis.circle")
                                        }
                                    }
                                    .disabled(store.isDisconnectingSpotify)
                                }
                            } else {
                                Image(systemName: state == .connected ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(state == .connected ? .green : .secondary)
                            }
                        }
                    }
                }
                Section("How Harmony uses providers") {
                    Text("Harmony shares queue intent. Each person plays music through their own connected service; Harmony never relays audio.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Connections")
            .task { await store.refreshProviderConnections() }
            .refreshable { await store.refreshProviderConnections() }
            .alert(
                "Spotify playback unavailable",
                isPresented: Binding(
                    get: { store.spotifyPlaybackErrorMessage != nil },
                    set: { if !$0 { store.dismissSpotifyPlaybackError() } }
                )
            ) {
                Button("OK", role: .cancel) { store.dismissSpotifyPlaybackError() }
            } message: {
                Text(store.spotifyPlaybackErrorMessage ?? "Unknown Spotify connection error")
            }
        }
    }

    private func detail(for provider: MusicProvider, state: ProviderAccountStatus) -> String {
        switch state {
        case .connected:
            if provider == .spotify {
                switch store.spotifyPlaybackConnection {
                case .connected:
                    return "Account connected · device playback ready"
                case .authorizing:
                    return "Connecting to the Spotify app…"
                case let .unavailable(reason):
                    return reason
                case .requiresSubscription:
                    return "Spotify Premium is required for playback"
                case .requiresProviderApp:
                    return "Install and open Spotify to enable playback"
                case .disconnected:
                    return "Account connected · enable device playback"
                }
            }
            return "Connected to your Harmony account"
        case .notConnected: return "Not connected"
        case .setupRequired:
            return provider == .spotify
                ? "Spotify OAuth configuration is needed"
                : "MusicKit configuration is needed"
        }
    }
}
