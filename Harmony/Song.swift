//
//  Song.swift
//  Harmony
//
//  Created by Geri Doe on 8/5/22.
//

import Foundation
import SwiftUI

enum MusicProvider: String, CaseIterable, Hashable, Identifiable { case appleMusic, spotify; var id: String { rawValue }; var name: String { self == .appleMusic ? "Apple Music" : "Spotify" } }
enum ProviderAccountStatus: Equatable {
    case setupRequired, notConnected, connected

    var label: String {
        switch self {
        case .setupRequired: return "Setup required"
        case .notConnected: return "Not connected"
        case .connected: return "Connected"
        }
    }
}
enum ProviderAvailability: String, Hashable { case playable, openInProvider, unavailable; var label: String { self == .playable ? "Ready" : self == .openInProvider ? "Open" : "Unavailable" } }
struct ProviderTrackMapping: Hashable {
    let provider: MusicProvider
    let providerID: String
    let availability: ProviderAvailability
    let deepLinkURL: URL?

    init(provider: MusicProvider, providerID: String, availability: ProviderAvailability, deepLinkURL: URL? = nil) {
        self.provider = provider
        self.providerID = providerID
        self.availability = availability
        self.deepLinkURL = deepLinkURL
    }
}
struct HarmonyTrack: Identifiable, Hashable {
    let id: UUID
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let symbol: String
    let artworkURL: URL?
    let isExplicit: Bool
    let mappings: [ProviderTrackMapping]

    init(id: UUID = UUID(), title: String, artist: String, album: String, duration: TimeInterval, symbol: String, artworkURL: URL? = nil, isExplicit: Bool = false, mappings: [ProviderTrackMapping]) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.symbol = symbol
        self.artworkURL = artworkURL
        self.isExplicit = isExplicit
        self.mappings = mappings
    }
    func availability(for provider: MusicProvider) -> ProviderAvailability { mappings.first(where: { $0.provider == provider })?.availability ?? .unavailable }
    var durationText: String { String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60) }
}
enum SessionRole: Equatable { case conductor, collaborator; var label: String { self == .conductor ? "Conductor" : "Collaborator" } }
struct SessionMember: Identifiable, Hashable { let id: UUID; let name: String; let initials: String; let role: SessionRole; let providers: Set<MusicProvider>; init(id: UUID = UUID(), name: String, initials: String, role: SessionRole, providers: Set<MusicProvider>) { self.id = id; self.name = name; self.initials = initials; self.role = role; self.providers = providers } }
struct QueueItem: Identifiable, Hashable { let id: UUID; let track: HarmonyTrack; let addedBy: SessionMember; init(id: UUID = UUID(), track: HarmonyTrack, addedBy: SessionMember) { self.id = id; self.track = track; self.addedBy = addedBy } }
enum PlaybackState { case playing, paused }

enum QueueCommandType: String, Codable {
    case add, move, remove, play, pause, skip
}

struct QueueEvent: Identifiable, Hashable {
    let id: UUID
    let revision: Int
    let actorID: UUID
    let type: QueueCommandType
    let createdAt: Date

    init(revision: Int, actorID: UUID, type: QueueCommandType) {
        self.id = UUID()
        self.revision = revision
        self.actorID = actorID
        self.type = type
        self.createdAt = Date()
    }
}

@MainActor
final class HarmonySessionStore: ObservableObject {
    @Published var queue: [QueueItem]
    @Published var queueRevision = 12
    @Published var playbackState: PlaybackState = .playing
    @Published private(set) var providerStates: [MusicProvider: ProviderAccountStatus] = [.appleMusic: .setupRequired, .spotify: .setupRequired]
    @Published private(set) var events: [QueueEvent] = []
    @Published var sessionName = "Friday Night Finds"
    @Published var inviteCode = "HARMONY-8Q4"
    @Published var collaborationMessage = "Local prototype"
    @Published private(set) var isConnectingSpotify = false
    @Published private(set) var isConnectingSpotifyPlayback = false
    @Published private(set) var isDisconnectingSpotify = false
    @Published private(set) var isDeletingAccount = false
    @Published private(set) var spotifyPlaybackConnection: ProviderConnectionState = .disconnected
    @Published private(set) var spotifyPlaybackErrorMessage: String?
    @Published private(set) var activeMemberIDs: Set<UUID> = []
    @Published private(set) var catalogSearchResults: [HarmonyTrack]?
    @Published private(set) var isSearchingCatalog = false
    @Published private(set) var catalogSearchMessage: String?
    @Published private(set) var isClosingSession = false
    private var remoteSessionID: UUID?
    private var liveQueueSubscription: LiveQueueSubscription?
    private var liveSessionSubscription: LiveSessionSubscription?
    private var livePresenceSubscription: LivePresenceSubscription?
    private let collaborationRepository = HarmonyCollaborationRepository()
    private let spotifyRemote: any SpotifyPlaybackProviding
    private var spotifyLoadedProviderID: String?
    @Published private(set) var currentMember: SessionMember
    @Published private(set) var members: [SessionMember]
    let catalog: [HarmonyTrack]
    convenience init() {
        self.init(spotifyRemote: SpotifyAppRemoteProvider())
    }

    init(spotifyRemote: any SpotifyPlaybackProviding) {
        self.spotifyRemote = spotifyRemote
        spotifyPlaybackConnection = spotifyRemote.connectionState
        let alex = SessionMember(name: "Alex Morgan", initials: "AM", role: .conductor, providers: [.appleMusic, .spotify])
        let sam = SessionMember(name: "Sam Lee", initials: "SL", role: .collaborator, providers: [.spotify])
        let priya = SessionMember(name: "Priya Shah", initials: "PS", role: .collaborator, providers: [.appleMusic])
        currentMember = alex; members = [alex, sam, priya]; catalog = SampleCatalog.tracks
        queue = [QueueItem(track: catalog[0], addedBy: sam), QueueItem(track: catalog[2], addedBy: priya), QueueItem(track: catalog[1], addedBy: alex)]
    }
    var nowPlaying: QueueItem? { queue.first }
    var isLiveSession: Bool { remoteSessionID != nil }
    func providerState(for provider: MusicProvider) -> ProviderAccountStatus { providerStates[provider] ?? .notConnected }
    func canRemove(_ item: QueueItem) -> Bool { currentMember.role == .conductor || item.addedBy.id == currentMember.id }

    func refreshProviderConnections() async {
        do {
            let connections = try await collaborationRepository.providerConnections()
            let connected = Set(connections.compactMap { connection -> MusicProvider? in
                switch connection.provider {
                case "apple_music": return .appleMusic
                case "spotify": return .spotify
                default: return nil
                }
            })
            providerStates[.spotify] = connected.contains(.spotify) ? .connected : .notConnected
            // MusicKit is device-authorized rather than backed by a Harmony token row.
            // Keep this gated until the explicit App ID has the MusicKit service enabled.
            providerStates[.appleMusic] = .setupRequired
        } catch {
            collaborationMessage = "Could not load connection status: \(error.localizedDescription)"
        }
    }

    func connectSpotify() async {
        guard !isConnectingSpotify else { return }
        isConnectingSpotify = true
        defer { isConnectingSpotify = false }
        do {
            let response = try await SpotifyAuthorizationCoordinator().authorize()
            try await collaborationRepository.exchangeSpotifyAuthorization(response)
            await refreshProviderConnections()
            collaborationMessage = "Spotify connected"
        } catch {
            collaborationMessage = "Spotify connection failed: \(error.localizedDescription)"
        }
    }

    func enableSpotifyPlayback() async {
        guard providerState(for: .spotify) == .connected, !isConnectingSpotifyPlayback else { return }
        spotifyPlaybackErrorMessage = nil
        isConnectingSpotifyPlayback = true
        spotifyPlaybackConnection = .authorizing
        defer { isConnectingSpotifyPlayback = false }
        do {
            let credential = try await collaborationRepository.spotifyAccessCredential()
            guard credential.scopes.contains("app-remote-control") else {
                throw SpotifyAppRemoteError.missingAppRemoteScope
            }
            try await spotifyRemote.authorizeAndConnect()
            spotifyPlaybackConnection = spotifyRemote.connectionState
            if try await playCurrentSpotifyTrackIfAvailable() {
                collaborationMessage = "Playing the Harmony queue on Spotify"
            } else {
                collaborationMessage = "Spotify playback ready"
            }
        } catch {
            let nsError = error as NSError
            let details = nsError.userInfo.isEmpty ? "" : " \(nsError.userInfo)"
            let message = error.localizedDescription
            spotifyPlaybackConnection = .unavailable(reason: message)
            spotifyPlaybackErrorMessage = message
            collaborationMessage = "Spotify playback connection failed: \(message)"
            print("Harmony Spotify playback connection failed: \(message) [\(nsError.domain) \(nsError.code)]\(details)")
        }
    }

    func dismissSpotifyPlaybackError() {
        spotifyPlaybackErrorMessage = nil
    }

    func disconnectSpotify() async {
        guard providerState(for: .spotify) == .connected, !isDisconnectingSpotify else { return }
        isDisconnectingSpotify = true
        defer { isDisconnectingSpotify = false }
        do {
            try await collaborationRepository.disconnectSpotify()
            spotifyRemote.disconnect()
            spotifyPlaybackConnection = .disconnected
            providerStates[.spotify] = .notConnected
            collaborationMessage = "Spotify disconnected"
        } catch {
            collaborationMessage = "Could not disconnect Spotify: \(error.localizedDescription)"
            spotifyPlaybackErrorMessage = error.localizedDescription
        }
    }

    func deleteAccount() async {
        guard !isDeletingAccount else { return }
        isDeletingAccount = true
        defer { isDeletingAccount = false }
        do {
            await detachLiveSubscriptions()
            spotifyRemote.disconnect()
            try await collaborationRepository.deleteAccount()
            remoteSessionID = nil
            activeMemberIDs = []
            queue = []
            queueRevision = 0
            members = [currentMember]
            providerStates = [.appleMusic: .setupRequired, .spotify: .notConnected]
            spotifyPlaybackConnection = .disconnected
            spotifyLoadedProviderID = nil
            catalogSearchResults = nil
            inviteCode = ""
            sessionName = "No active session"
            collaborationMessage = "Harmony account deleted"
        } catch {
            collaborationMessage = "Could not delete account: \(error.localizedDescription)"
        }
    }

    func searchCatalog(query: String) async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            catalogSearchResults = nil
            catalogSearchMessage = nil
            isSearchingCatalog = false
            return
        }
        guard providerState(for: .spotify) == .connected else {
            catalogSearchResults = catalog.filter {
                "\($0.title) \($0.artist) \($0.album)".localizedCaseInsensitiveContains(term)
            }
            catalogSearchMessage = "Connect Spotify to search its full catalog."
            return
        }
        isSearchingCatalog = true
        catalogSearchMessage = nil
        do {
            let results = try await collaborationRepository.searchSpotify(query: term)
            guard !Task.isCancelled else { return }
            catalogSearchResults = results.map { result in
                HarmonyTrack(
                    title: result.title,
                    artist: result.artist,
                    album: result.album,
                    duration: TimeInterval(result.durationSeconds),
                    symbol: "music.note",
                    artworkURL: result.artworkURL,
                    isExplicit: result.isExplicit,
                    mappings: [ProviderTrackMapping(
                        provider: .spotify,
                        providerID: result.providerID,
                        availability: .playable,
                        deepLinkURL: result.deepLinkURL
                    )]
                )
            }
            catalogSearchMessage = results.isEmpty ? "No Spotify tracks found." : nil
        } catch {
            guard !Task.isCancelled else { return }
            catalogSearchResults = []
            catalogSearchMessage = "Spotify search failed: \(error.localizedDescription)"
        }
        isSearchingCatalog = false
    }

    func handleSpotifyOpenURL(_ url: URL) {
        _ = spotifyRemote.handleAuthorizationCallback(url)
    }

    func handleOpenURL(_ url: URL) {
        guard url.scheme?.lowercased() == "harmony" else { return }
        if url.host?.lowercased() == "spotify-auth" {
            handleSpotifyOpenURL(url)
        } else if let code = Self.inviteCode(from: url) {
            Task { await joinLiveSession(inviteCode: code) }
        }
    }

    static func inviteCode(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "harmony", url.host?.lowercased() == "join",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              code.range(of: "^[A-Z0-9]{6,8}$", options: .regularExpression) != nil else { return nil }
        return code
    }

    var inviteURL: URL? {
        guard isLiveSession else { return nil }
        var components = URLComponents()
        components.scheme = "harmony"
        components.host = "join"
        components.queryItems = [URLQueryItem(name: "code", value: inviteCode)]
        return components.url
    }

    func applyPresence(joins: Set<UUID>, leaves: Set<UUID>) {
        activeMemberIDs.formUnion(joins)
        activeMemberIDs.subtract(leaves)
    }
    func add(_ track: HarmonyTrack) {
        guard !queue.contains(where: { $0.track.title == track.title }) else { return }
        queue.append(QueueItem(track: track, addedBy: currentMember))
        record(.add)
        guard let remoteSessionID else { return }
        let expectedRevision = queueRevision - 1
        Task { await applyRemoteAdd(track, sessionID: remoteSessionID, expectedRevision: expectedRevision) }
    }

    func remove(_ item: QueueItem) {
        guard canRemove(item) else { return }
        queue.removeAll { $0.id == item.id }
        record(.remove)
        guard let remoteSessionID else { return }
        let expectedRevision = queueRevision - 1
        Task { await applyRemoteRemove(item.id, sessionID: remoteSessionID, expectedRevision: expectedRevision) }
    }

    func move(from: IndexSet, to: Int) {
        guard currentMember.role == .conductor else { return }
        guard let movedItemID = from.first.map({ queue[$0].id }) else { return }
        queue.move(fromOffsets: from, toOffset: to)
        record(.move)
        guard let remoteSessionID else { return }
        guard let destination = queue.firstIndex(where: { $0.id == movedItemID }) else { return }
        let expectedRevision = queueRevision - 1
        Task { await applyRemoteMove(movedItemID, position: Double(destination + 1) * 1024, sessionID: remoteSessionID, expectedRevision: expectedRevision) }
    }

    func togglePlayback() async {
        guard currentMember.role == .conductor else { return }
        playbackState = playbackState == .playing ? .paused : .playing
        record(playbackState == .playing ? .play : .pause)
        if spotifyPlaybackConnection.isConnected {
            do {
                if playbackState == .playing {
                    let didPlayCurrentTrack = try await playCurrentSpotifyTrackIfAvailable()
                    if !didPlayCurrentTrack {
                        _ = try await spotifyRemote.perform(.resume)
                    }
                } else {
                    _ = try await spotifyRemote.perform(.pause)
                }
                collaborationMessage = playbackState == .playing ? "Playing on Spotify" : "Spotify paused"
            } catch {
                collaborationMessage = "Spotify playback command failed: \(error.localizedDescription)"
            }
        }
        guard let remoteSessionID else { return }
        await applyRemotePlayback(sessionID: remoteSessionID, expectedRevision: queueRevision - 1)
    }

    func skipToNext() async {
        guard currentMember.role == .conductor, queue.count > 1 else { return }
        let expectedRevision = queueRevision
        queue.removeFirst()
        playbackState = .playing
        spotifyLoadedProviderID = nil
        record(.skip)

        if spotifyPlaybackConnection.isConnected {
            do {
                if try await playCurrentSpotifyTrackIfAvailable() {
                    collaborationMessage = "Skipped to the next Harmony track"
                } else {
                    collaborationMessage = "Next track is unavailable on Spotify"
                }
            } catch {
                collaborationMessage = "Spotify skip failed: \(error.localizedDescription)"
            }
        }
        guard let remoteSessionID else { return }
        do {
            queueRevision = try await collaborationRepository.skip(in: remoteSessionID, expectedRevision: expectedRevision)
            await refreshRemoteQueue()
        } catch {
            collaborationMessage = "Queue skip conflicted with another update."
            await refreshRemoteQueue()
        }
    }

    func createLiveSession() async {
        collaborationMessage = "Connecting…"
        do {
            let remoteSession = try await collaborationRepository.createSession(title: sessionName)
            sessionName = remoteSession.title
            inviteCode = remoteSession.inviteCode
            queueRevision = remoteSession.queueRevision
            remoteSessionID = remoteSession.id
            collaborationMessage = "Live Supabase session"
            await refreshRemoteQueue()
            await subscribeToRemoteQueue(remoteSession.id)
            await subscribeToSessionLifecycle(remoteSession.id)
            await subscribeToPresence(remoteSession.id)
        } catch {
            collaborationMessage = "Connection failed: \(error.localizedDescription)"
        }
    }

    func joinLiveSession(inviteCode: String) async {
        collaborationMessage = "Joining…"
        do {
            let remoteSession = try await collaborationRepository.joinSession(inviteCode: inviteCode)
            await detachLiveSubscriptions()
            sessionName = remoteSession.title
            self.inviteCode = remoteSession.inviteCode
            queueRevision = remoteSession.queueRevision
            remoteSessionID = remoteSession.id
            collaborationMessage = "Joined live Supabase session"
            await refreshRemoteQueue()
            await subscribeToRemoteQueue(remoteSession.id)
            await subscribeToSessionLifecycle(remoteSession.id)
            await subscribeToPresence(remoteSession.id)
        } catch {
            collaborationMessage = "Join failed: \(error.localizedDescription)"
        }
    }

    func closeLiveSession() async {
        guard let remoteSessionID, !isClosingSession else { return }
        isClosingSession = true
        defer { isClosingSession = false }
        do {
            if currentMember.role == .conductor {
                try await collaborationRepository.endSession(id: remoteSessionID)
            } else {
                try await collaborationRepository.leaveSession(id: remoteSessionID)
            }
            await detachLiveSubscriptions()
            self.remoteSessionID = nil
            activeMemberIDs = []
            queue = []
            queueRevision = 0
            members = [currentMember]
            inviteCode = ""
            sessionName = "No active session"
            collaborationMessage = currentMember.role == .conductor ? "Session ended" : "You left the session"
        } catch {
            collaborationMessage = "Could not close session: \(error.localizedDescription)"
        }
    }

    private func applyRemoteAdd(_ track: HarmonyTrack, sessionID: UUID, expectedRevision: Int) async {
        do {
            queueRevision = try await collaborationRepository.add(track: track, to: sessionID, expectedRevision: expectedRevision)
            collaborationMessage = "Live Supabase session"
            await refreshRemoteQueue()
        } catch {
            collaborationMessage = "Queue sync failed: \(error.localizedDescription)"
            await refreshRemoteQueue()
        }
    }

    private func refreshRemoteQueue() async {
        guard let remoteSessionID else { return }
        do {
            async let remoteSession = collaborationRepository.session(id: remoteSessionID)
            async let remoteQueue = collaborationRepository.queue(for: remoteSessionID)
            async let remoteMembers = collaborationRepository.members(for: remoteSessionID)
            async let currentUserID = collaborationRepository.currentUserID()
            let (session, snapshot, remoteMemberRecords, userID) = try await (remoteSession, remoteQueue, remoteMembers, currentUserID)
            sessionName = session.title
            inviteCode = session.inviteCode
            queueRevision = session.queueRevision
            if session.playbackState?.status == "playing" { playbackState = .playing }
            if session.playbackState?.status == "paused" { playbackState = .paused }
            members = remoteMemberRecords.map { member in
                let name = member.profile.displayName
                return SessionMember(id: member.profileID, name: name, initials: String(name.prefix(2)).uppercased(), role: member.role == "conductor" ? .conductor : .collaborator, providers: [])
            }
            if let me = members.first(where: { $0.id == userID }) { currentMember = me }
            queue = snapshot.map { remote in
                let track = catalog.first(where: { $0.title == remote.canonicalTrack.title && $0.artist == remote.canonicalTrack.artist })
                    ?? HarmonyTrack(
                        title: remote.canonicalTrack.title,
                        artist: remote.canonicalTrack.artist,
                        album: remote.canonicalTrack.album ?? "",
                        duration: TimeInterval(remote.canonicalTrack.durationMilliseconds ?? 0) / 1000,
                        symbol: "music.note",
                artworkURL: remote.canonicalTrack.artworkURL,
                isExplicit: remote.canonicalTrack.isExplicit,
                        mappings: (remote.canonicalTrack.providerTracks ?? []).compactMap(Self.providerMapping)
                    )
                return QueueItem(id: remote.id, track: track, addedBy: members.first(where: { $0.id == remote.addedBy }) ?? currentMember)
            }
        } catch {
            collaborationMessage = "Could not refresh queue: \(error.localizedDescription)"
        }
    }

    private func applyRemoteRemove(_ queueItemID: UUID, sessionID: UUID, expectedRevision: Int) async {
        do {
            queueRevision = try await collaborationRepository.remove(queueItemID: queueItemID, from: sessionID, expectedRevision: expectedRevision)
            await refreshRemoteQueue()
        } catch {
            collaborationMessage = "Queue sync failed: \(error.localizedDescription)"
            await refreshRemoteQueue()
        }
    }

    private func applyRemoteMove(_ queueItemID: UUID, position: Double, sessionID: UUID, expectedRevision: Int) async {
        do {
            queueRevision = try await collaborationRepository.move(queueItemID: queueItemID, to: position, in: sessionID, expectedRevision: expectedRevision)
            await refreshRemoteQueue()
        } catch {
            collaborationMessage = "Queue sync failed: \(error.localizedDescription)"
            await refreshRemoteQueue()
        }
    }

    private func applyRemotePlayback(sessionID: UUID, expectedRevision: Int) async {
        do {
            queueRevision = try await collaborationRepository.setPlayback(state: playbackState, in: sessionID, expectedRevision: expectedRevision)
        } catch {
            collaborationMessage = "Playback sync failed: \(error.localizedDescription)"
            await refreshRemoteQueue()
        }
    }

    private func subscribeToRemoteQueue(_ sessionID: UUID) async {
        do {
            liveQueueSubscription = try await collaborationRepository.observeQueue(sessionID: sessionID) { [weak self] in
                Task { @MainActor in await self?.refreshRemoteQueue() }
            }
        } catch {
            collaborationMessage = "Live session connected, but updates are delayed."
        }
    }

    private func subscribeToPresence(_ sessionID: UUID) async {
        do {
            let profileID = try await collaborationRepository.currentUserID()
            activeMemberIDs.insert(profileID)
            livePresenceSubscription = try await collaborationRepository.observePresence(sessionID: sessionID, profileID: profileID) { [weak self] joins, leaves in
                Task { @MainActor in
                    self?.applyPresence(joins: joins, leaves: leaves)
                }
            }
        } catch {
            // Presence is an enhancement; room membership and queue sync remain usable.
            collaborationMessage = "Live session connected, but member activity is delayed."
        }
    }

    private func subscribeToSessionLifecycle(_ sessionID: UUID) async {
        do {
            liveSessionSubscription = try await collaborationRepository.observeSession(sessionID: sessionID) { [weak self] in
                Task { @MainActor in await self?.refreshSessionLifecycle(sessionID) }
            }
        } catch {
            collaborationMessage = "Live session connected, but lifecycle updates are delayed."
        }
    }

    private func refreshSessionLifecycle(_ sessionID: UUID) async {
        guard remoteSessionID == sessionID else { return }
        do {
            let session = try await collaborationRepository.session(id: sessionID)
            guard session.endedAt != nil else { return }
            await detachLiveSubscriptions()
            remoteSessionID = nil
            activeMemberIDs = []
            collaborationMessage = "The Conductor ended this session"
        } catch {
            collaborationMessage = "Could not refresh session status."
        }
    }

    private func record(_ type: QueueCommandType) {
        queueRevision += 1
        events.append(QueueEvent(revision: queueRevision, actorID: currentMember.id, type: type))
    }

    private func detachLiveSubscriptions() async {
        await liveQueueSubscription?.channel.unsubscribe()
        await liveSessionSubscription?.channel.unsubscribe()
        await livePresenceSubscription?.channel.unsubscribe()
        liveQueueSubscription = nil
        liveSessionSubscription = nil
        livePresenceSubscription = nil
    }

    private static func providerMapping(_ remote: RemoteProviderTrack) -> ProviderTrackMapping? {
        let provider: MusicProvider
        switch remote.provider {
        case "apple_music": provider = .appleMusic
        case "spotify": provider = .spotify
        default: return nil
        }
        let availability: ProviderAvailability
        switch remote.availability {
        case "playable": availability = .playable
        case "open_in_provider": availability = .openInProvider
        default: availability = .unavailable
        }
        return ProviderTrackMapping(
            provider: provider,
            providerID: remote.providerID,
            availability: availability,
            deepLinkURL: remote.deepLink
        )
    }

    private func playCurrentSpotifyTrackIfAvailable() async throws -> Bool {
        guard let track = nowPlaying?.track,
              let mapping = track.mappings.first(where: { $0.provider == .spotify && $0.availability == .playable }),
              Self.isSpotifyTrackURI(mapping.providerID) else { return false }
        if spotifyLoadedProviderID == mapping.providerID {
            _ = try await spotifyRemote.perform(.resume)
        } else {
            let resolved = try await spotifyRemote.resolve(track: track)
            _ = try await spotifyRemote.perform(.play(resolved))
            spotifyLoadedProviderID = mapping.providerID
        }
        return true
    }

    private static func isSpotifyTrackURI(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "spotify", parts[1] == "track", parts[2].count == 22 else { return false }
        return parts[2].allSatisfy { $0.isASCII && $0.isLetter || $0.isNumber }
    }
}

enum SampleCatalog {
    static func mappings(_ apple: String, _ spotify: String) -> [ProviderTrackMapping] { [ProviderTrackMapping(provider: .appleMusic, providerID: apple, availability: .playable), ProviderTrackMapping(provider: .spotify, providerID: spotify, availability: .playable)] }
    static let tracks = [
        HarmonyTrack(title: "Afterglow", artist: "Wolves at Noon", album: "Motion Blur", duration: 221, symbol: "sun.max.fill", mappings: mappings("am.afterglow", "spotify:track:afterglow")),
        HarmonyTrack(title: "Neon Coast", artist: "Daya Rose", album: "Neon Coast", duration: 194, symbol: "sparkles", mappings: mappings("am.neon", "spotify:track:neon")),
        HarmonyTrack(title: "Seventeen", artist: "The Ferns", album: "Paper Rooms", duration: 248, symbol: "leaf.fill", mappings: mappings("am.seventeen", "spotify:track:seventeen")),
        HarmonyTrack(title: "Switchback", artist: "KITE CLUB", album: "Switchback", duration: 203, symbol: "bolt.fill", mappings: [ProviderTrackMapping(provider: .appleMusic, providerID: "am.switch", availability: .playable), ProviderTrackMapping(provider: .spotify, providerID: "spotify:track:switch", availability: .openInProvider)]),
        HarmonyTrack(title: "Blue Hour", artist: "Eloise Harbor", album: "Slow Light", duration: 216, symbol: "moon.stars.fill", mappings: [ProviderTrackMapping(provider: .appleMusic, providerID: "am.blue", availability: .playable), ProviderTrackMapping(provider: .spotify, providerID: "", availability: .unavailable)])
    ]
}
