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
    @State private var reviewAlbum: ReviewableAlbum?
    @State private var trackForList: HarmonyTrack?
    @State private var albumRating = 3.5
    @State private var albumReviewBody = ""
    @State private var albumIsLoved = false
    @State private var albumContainsSpoilers = false
    @State private var albumReviewVisibility = SocialVisibilityOption.privateOnly

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
                            if let album = track.reviewableAlbum {
                                NavigationLink {
                                    ResolvableCanonicalAlbumView(album: album)
                                } label: {
                                    Label("View album", systemImage: "square.stack")
                                        .font(.caption)
                                }
                                Button {
                                    albumRating = 3.5
                                    albumReviewBody = ""
                                    albumIsLoved = false
                                    albumContainsSpoilers = false
                                    albumReviewVisibility = store.reviewsSocialVisibility
                                    reviewAlbum = album
                                } label: {
                                    Label("Review album", systemImage: "star.bubble")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        Spacer()
                        Button {
                            trackForList = track
                        } label: {
                            Image(systemName: "text.badge.plus").font(.title3)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Add \(track.title) to a list")
                        .accessibilityIdentifier("search-add-to-list-\(track.id.uuidString)")
                        Button { store.add(track) } label: {
                            Image(systemName: "plus.circle.fill").font(.title3)
                        }
                        .buttonStyle(.borderless)
                        .disabled(store.contains(track))
                        .accessibilityLabel("Add \(track.title) to the queue")
                        .accessibilityIdentifier("search-add-to-queue-\(track.id.uuidString)")
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
            .sheet(item: $reviewAlbum) { album in
                NavigationStack {
                    Form {
                        Section("Album") {
                            HStack(spacing: 12) {
                                if let artworkURL = album.artworkURL {
                                    AsyncImage(url: artworkURL) { phase in
                                        phase.image?.resizable().scaledToFit()
                                    }
                                    .frame(width: 54, height: 54)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                VStack(alignment: .leading) {
                                    Text(album.title).font(.headline)
                                    Text(album.artist).font(.subheadline).foregroundColor(.secondary)
                                }
                            }
                        }
                        Section("Rating") {
                            RatingPicker(rating: $albumRating)
                            TextField("Write a short review (optional)", text: $albumReviewBody, axis: .vertical)
                                .lineLimit(3...8)
                            Toggle("Loved", isOn: $albumIsLoved)
                            Toggle("Contains spoilers", isOn: $albumContainsSpoilers)
                        }
                        Section("Visibility") {
                            Picker("Audience", selection: $albumReviewVisibility) {
                                ForEach(SocialVisibilityOption.allCases) { visibility in
                                    Text(visibility.title).tag(visibility)
                                }
                            }
                        }
                    }
                    .navigationTitle("Review album")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { reviewAlbum = nil }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(albumReviewVisibility == .followers ? "Publish" : "Save") {
                                Task {
                                    let didSave = await store.publishAlbumReview(
                                        album,
                                        rating: albumRating,
                                        body: albumReviewBody,
                                        isLoved: albumIsLoved,
                                        containsSpoilers: albumContainsSpoilers,
                                        visibility: albumReviewVisibility
                                    )
                                    if didSave { reviewAlbum = nil }
                                }
                            }
                            .disabled(store.isPublishingMusicReview)
                        }
                    }
                }
            }
            .sheet(item: $trackForList) { track in
                AddTrackToMusicListSheet(track: track)
                    .environmentObject(store)
            }
        }
    }
}

struct ConnectionsView: View {
    @EnvironmentObject private var store: HarmonySessionStore
    @State private var showingDeleteAccountConfirmation = false
    @State private var displayName = ""
    @State private var discoverySearch = ""
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

                if store.isRefreshingSocialProfiles && store.socialProfiles.isEmpty {
                    Section("Follower relationships") {
                        ProgressView("Loading relationships…")
                    }
                }

                if !incomingRequests.isEmpty {
                    Section("Follow requests") {
                        ForEach(incomingRequests) { profile in
                            profileRow(profile, context: .incomingRequest)
                        }
                    }
                }

                if !outgoingRequests.isEmpty {
                    Section("Pending requests") {
                        ForEach(outgoingRequests) { profile in
                            profileRow(profile, context: .outgoingRequest)
                        }
                    }
                }

                if !followingProfiles.isEmpty {
                    Section("Following") {
                        ForEach(followingProfiles) { profile in
                            profileRow(profile, context: .following)
                        }
                    }
                }

                if !followerProfiles.isEmpty {
                    Section("Followers") {
                        ForEach(followerProfiles) { profile in
                            profileRow(profile, context: .follower)
                        }
                    }
                }

                if !store.blockedSocialProfiles.isEmpty {
                    Section("Manage blocked") {
                        ForEach(store.blockedSocialProfiles) { profile in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.displayName)
                                    Text("Blocked listener")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Unblock") {
                                    Task { await store.unblockSocialProfile(profile.id) }
                                }
                                .buttonStyle(.bordered)
                            }
                            .accessibilityIdentifier("blocked-profile-\(profile.id.uuidString)")
                        }
                    }
                }

                Section("Find people") {
                    TextField("Search listeners", text: $discoverySearch)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("connections-people-search")

                    if store.isRefreshingSocialDiscovery {
                        ProgressView("Searching…")
                    } else if store.discoveredSocialProfiles.isEmpty {
                        Text(discoverySearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "No discoverable listeners yet."
                            : "No listeners match this search.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.discoveredSocialProfiles) { profile in
                            profileRow(profile, context: .discovery)
                        }
                        if store.hasMoreSocialDiscovery {
                            Button {
                                Task { await store.loadMoreSocialDiscovery() }
                            } label: {
                                if store.isLoadingMoreSocialDiscovery {
                                    ProgressView("Loading more listeners…")
                                } else {
                                    Label("Load more listeners", systemImage: "arrow.down.circle")
                                }
                            }
                            .disabled(store.isLoadingMoreSocialDiscovery)
                            .accessibilityIdentifier("connections-people-load-more")
                        }
                    }
                }

                Section("Social privacy") {
                    Toggle("Log Harmony plays", isOn: Binding(
                        get: { store.recordsHarmonyPlays },
                        set: { enabled in Task { await store.updateHistoryRecording(enabled) } }
                    ))
                    .disabled(store.socialSettings == nil || store.isUpdatingAccountSettings)
                    privacyPicker("Live listening", selection: store.liveSocialVisibility, category: .liveListening)
                    privacyPicker("Listening history", selection: store.historySocialVisibility, category: .listeningHistory)
                    privacyPicker("Reviews", selection: store.reviewsSocialVisibility, category: .reviews)
                    privacyPicker("Music shelf", selection: store.shelfSocialVisibility, category: .musicShelf)
                        .accessibilityIdentifier("music-shelf-privacy")
                    if store.providerState(for: .spotify) == .connected {
                        Button {
                            Task { await store.importRecentSpotifyHistory() }
                        } label: {
                            if store.isImportingSpotifyHistory {
                                ProgressView()
                            } else {
                                Label("Import recent Spotify plays", systemImage: "arrow.down.circle")
                            }
                        }
                        .disabled(store.isImportingSpotifyHistory)
                        if let message = store.spotifyHistoryImportMessage {
                            Text(message).font(.footnote).foregroundColor(.secondary)
                            if message.contains("Reconnect Spotify") {
                                Button("Reconnect Spotify for history access") {
                                    Task { await store.connectSpotify() }
                                }
                                .disabled(store.isConnectingSpotify)
                            }
                        }
                    }
                    Text("When enabled, skipping to the next track logs the completed Harmony track. Only approved followers can see follower-visible activity or your Loved shelf. New accounts begin with logging off and every category set to Only me.")
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
                await store.refreshSocialProfiles()
            }
            .task(id: discoverySearch) {
                do {
                    try await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    await store.refreshSocialDiscovery(search: discoverySearch)
                } catch {
                    // A newer keystroke cancelled this debounce window.
                }
            }
            .refreshable {
                await store.refreshAccountSettings()
                displayName = store.accountProfile?.displayName ?? displayName
                await store.refreshProviderConnections()
                await store.refreshSocialProfiles()
                await store.refreshSocialDiscovery(search: discoverySearch)
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

    private enum ProfileRowContext {
        case incomingRequest
        case outgoingRequest
        case following
        case follower
        case discovery
    }

    private var incomingRequests: [RemoteSocialProfile] {
        store.socialProfiles.filter { store.incomingSocialFollowState(with: $0.id) == "requested" }
    }

    private var outgoingRequests: [RemoteSocialProfile] {
        store.socialProfiles.filter { store.outgoingSocialFollowState(with: $0.id) == "requested" }
    }

    private var followingProfiles: [RemoteSocialProfile] {
        store.socialProfiles.filter { store.outgoingSocialFollowState(with: $0.id) == "accepted" }
    }

    private var followerProfiles: [RemoteSocialProfile] {
        store.socialProfiles.filter { store.incomingSocialFollowState(with: $0.id) == "accepted" }
    }

    @ViewBuilder
    private func profileRow(_ profile: RemoteSocialProfile, context: ProfileRowContext) -> some View {
        HStack(spacing: 12) {
            NavigationLink {
                MemberProfileView(profileID: profile.id, displayName: profile.displayName)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName).font(.headline)
                    Text(relationshipLabel(profile.id))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("connections-profile-\(profile.id.uuidString)")
            Spacer()
            profileControl(profile, context: context)
        }
    }

    @ViewBuilder
    private func profileControl(_ profile: RemoteSocialProfile, context: ProfileRowContext) -> some View {
        if store.socialProfileActionIDs.contains(profile.id) {
            ProgressView().controlSize(.small)
        } else {
            switch context {
            case .incomingRequest:
                Menu("Respond") {
                    Button("Accept") {
                        Task { await store.respondToSocialFollow(from: profile.id, accept: true) }
                    }
                    Button("Decline", role: .destructive) {
                        Task { await store.respondToSocialFollow(from: profile.id, accept: false) }
                    }
                    blockButton(profile.id)
                }
                .buttonStyle(.borderedProminent)
            case .outgoingRequest:
                Menu("Requested") {
                    Button("Cancel request", role: .destructive) {
                        Task { await store.removeSocialFollow(profile.id) }
                    }
                    blockButton(profile.id)
                }
            case .following:
                Menu("Following") {
                    Button("Unfollow", role: .destructive) {
                        Task { await store.removeSocialFollow(profile.id) }
                    }
                    blockButton(profile.id)
                }
            case .follower:
                Menu("Follows you") {
                    if store.outgoingSocialFollowState(with: profile.id) == nil {
                        Button("Follow back") { Task { await store.requestSocialFollow(profile.id) } }
                    }
                    Button("Remove follower", role: .destructive) {
                        Task { await store.removeSocialFollower(profile.id) }
                    }
                    blockButton(profile.id)
                }
            case .discovery:
                discoveryControl(profile)
            }
        }
    }

    @ViewBuilder
    private func discoveryControl(_ profile: RemoteSocialProfile) -> some View {
        let incoming = store.incomingSocialFollowState(with: profile.id)
        let outgoing = store.outgoingSocialFollowState(with: profile.id)
        if incoming == "requested" {
            Menu("Respond") {
                Button("Accept") { Task { await store.respondToSocialFollow(from: profile.id, accept: true) } }
                Button("Decline", role: .destructive) {
                    Task { await store.respondToSocialFollow(from: profile.id, accept: false) }
                }
                if outgoing == "requested" {
                    Button("Cancel your request", role: .destructive) {
                        Task { await store.removeSocialFollow(profile.id) }
                    }
                }
                blockButton(profile.id)
            }
            .buttonStyle(.borderedProminent)
        } else if outgoing == "requested" {
            Menu("Requested") {
                Button("Cancel request", role: .destructive) {
                    Task { await store.removeSocialFollow(profile.id) }
                }
                blockButton(profile.id)
            }
        } else if outgoing == "accepted" {
            Menu("Following") {
                Button("Unfollow", role: .destructive) {
                    Task { await store.removeSocialFollow(profile.id) }
                }
                blockButton(profile.id)
            }
        } else {
            Button(incoming == "accepted" ? "Follow back" : "Follow") {
                Task { await store.requestSocialFollow(profile.id) }
            }
            .buttonStyle(.bordered)
        }
    }

    private func blockButton(_ profileID: UUID) -> some View {
        Button("Block", role: .destructive) {
            Task { await store.blockSocialProfile(profileID) }
        }
    }

    private func relationshipLabel(_ profileID: UUID) -> String {
        let incoming = store.incomingSocialFollowState(with: profileID)
        let outgoing = store.outgoingSocialFollowState(with: profileID)
        if incoming == "requested" && outgoing == "accepted" { return "You follow them · wants to follow you" }
        if incoming == "requested" && outgoing == "requested" { return "Requests pending both ways" }
        if incoming == "requested" { return "Wants to follow you" }
        if outgoing == "requested" && incoming == "accepted" { return "Follows you · your request is pending" }
        if outgoing == "requested" { return "Your request is pending" }
        if incoming == "accepted" && outgoing == "accepted" { return "You follow each other" }
        if outgoing == "accepted" { return "You follow this listener" }
        if incoming == "accepted" { return "Follows you" }
        return "Discoverable profile"
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
