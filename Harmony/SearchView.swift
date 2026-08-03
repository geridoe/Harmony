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
                        image.resizable().scaledToFit()
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
        .clipShape(RoundedRectangle(cornerRadius: min(cornerRadius, 4)))
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
                        Text("Searching connected catalogs…").foregroundColor(.secondary)
                    }
                } else if let message = store.catalogSearchMessage {
                    Text(message).font(.footnote).foregroundColor(.secondary)
                }
                ForEach(tracks) { track in
                    HStack {
                        TrackArtwork(track: track, size: 36)
                        VStack(alignment: .leading) {
                            HStack(spacing: 5) {
                                Text(track.title).font(.headline)
                                if track.isExplicit {
                                    Text("E")
                                        .font(.caption2.bold())
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 4)
                                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.secondary))
                                        .accessibilityLabel("Explicit")
                                }
                            }
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
                            if let spotifyURL = track.mappings.first(where: { $0.provider == .spotify })?.deepLinkURL {
                                Link(destination: spotifyURL) {
                                    HStack(spacing: 6) {
                                        Image("SpotifyFullLogo")
                                            .resizable()
                                            .scaledToFit()
                                            .frame(width: 70, height: 20)
                                        Text("OPEN SPOTIFY")
                                            .font(.caption2.weight(.semibold))
                                    }
                                }
                                .accessibilityLabel("Open \(track.title) in Spotify")
                            }
                        }
                        Spacer()
                        Button { store.add(track) } label: {
                            Image(systemName: "plus.circle.fill").font(.title3)
                        }
                        .disabled(store.contains(track))
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
    @State private var showingDeleteAccountConfirmation = false
    @State private var displayName = ""
    var body: some View {
        NavigationView {
            List {
                Section("Harmony profile") {
                    TextField("Display name", text: $displayName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                    Button("Save display name") {
                        Task { await store.updateDisplayName(displayName) }
                    }
                    .disabled(store.isUpdatingAccountSettings || displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("This name is visible to session members and other signed-in Harmony listeners.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("Social privacy") {
                    privacyPicker("Live listening", selection: store.liveSocialVisibility, category: .liveListening)
                    privacyPicker("Listening history", selection: store.historySocialVisibility, category: .listeningHistory)
                    privacyPicker("Reviews", selection: store.reviewsSocialVisibility, category: .reviews)
                    Text("Only approved followers can see follower-visible activity. New accounts begin with every social category set to Only me.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

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
                            } else if provider == .appleMusic {
                                if state != .connected {
                                    Button(store.isConnectingAppleMusic ? "Connecting…" : "Connect") {
                                        Task { await store.connectAppleMusic() }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(store.isConnectingAppleMusic)
                                } else {
                                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
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
                Section("Privacy") {
                    Button("Delete Harmony account", role: .destructive) {
                        showingDeleteAccountConfirmation = true
                    }
                    .disabled(store.isDeletingAccount)
                    Text("Deletes your provider connection, session memberships, queue contributions, and Harmony profile.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Connections")
            .task {
                await store.refreshAccountSettings()
                displayName = store.accountProfile?.displayName ?? ""
                await store.refreshProviderConnections()
            }
            .refreshable {
                await store.refreshAccountSettings()
                displayName = store.accountProfile?.displayName ?? displayName
                await store.refreshProviderConnections()
            }
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
            .confirmationDialog(
                "Permanently delete your Harmony account?",
                isPresented: $showingDeleteAccountConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete account", role: .destructive) {
                    Task { await store.deleteAccount() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This cannot be undone. Sessions you conduct will end and all Harmony account data will be removed.")
            }
        }
    }

    private func privacyPicker(
        _ title: String,
        selection: SocialVisibilityOption,
        category: SocialPrivacyCategory
    ) -> some View {
        Picker(title, selection: Binding(
            get: { selection },
            set: { visibility in Task { await store.updateSocialVisibility(visibility, for: category) } }
        )) {
            ForEach(SocialVisibilityOption.allCases) { visibility in
                Text(visibility.title).tag(visibility)
            }
        }
        .disabled(store.socialSettings == nil || store.isUpdatingAccountSettings)
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
