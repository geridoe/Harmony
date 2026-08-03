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
struct ReviewableAlbum: Hashable, Identifiable {
    let provider: MusicProvider
    let providerID: String
    let title: String
    let artist: String
    let artworkURL: URL?
    let deepLinkURL: URL?
    var id: String { "\(provider.rawValue):\(providerID)" }
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
    let reviewableAlbum: ReviewableAlbum?

    init(id: UUID = UUID(), title: String, artist: String, album: String, duration: TimeInterval, symbol: String, artworkURL: URL? = nil, isExplicit: Bool = false, mappings: [ProviderTrackMapping], reviewableAlbum: ReviewableAlbum? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.symbol = symbol
        self.artworkURL = artworkURL
        self.isExplicit = isExplicit
        self.mappings = mappings
        self.reviewableAlbum = reviewableAlbum
    }
    func availability(for provider: MusicProvider) -> ProviderAvailability { mappings.first(where: { $0.provider == provider })?.availability ?? .unavailable }
    var durationText: String { String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60) }
}
enum SessionRole: Equatable { case conductor, collaborator; var label: String { self == .conductor ? "Conductor" : "Collaborator" } }
struct SessionMember: Identifiable, Hashable { let id: UUID; let name: String; let initials: String; let role: SessionRole; let providers: Set<MusicProvider>; init(id: UUID = UUID(), name: String, initials: String, role: SessionRole, providers: Set<MusicProvider>) { self.id = id; self.name = name; self.initials = initials; self.role = role; self.providers = providers } }
struct QueueItem: Identifiable, Hashable { let id: UUID; let track: HarmonyTrack; let addedBy: SessionMember; init(id: UUID = UUID(), track: HarmonyTrack, addedBy: SessionMember) { self.id = id; self.track = track; self.addedBy = addedBy } }
enum PlaybackState { case playing, paused }

enum SessionPlaybackMode: String, CaseIterable, Identifiable, Codable {
    case conductorPlayback = "conductor_playback"
    case personalListenAlong = "personal_listen_along"
    case queueOnly = "queue_only"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .conductorPlayback: "Conductor plays"
        case .personalListenAlong: "Listen along"
        case .queueOnly: "Queue only"
        }
    }
    var detail: String {
        switch self {
        case .conductorPlayback: "The Conductor controls playback on their device."
        case .personalListenAlong: "Each member plays the shared queue in their connected service."
        case .queueOnly: "Share and arrange music without controlling playback."
        }
    }
}

enum SessionExpiry: String, CaseIterable, Identifiable {
    case never
    case twoHours
    case oneDay

    var id: String { rawValue }
    var title: String {
        switch self {
        case .never: "No expiry"
        case .twoHours: "2 hours"
        case .oneDay: "24 hours"
        }
    }
    func date(from now: Date = Date()) -> Date? {
        switch self {
        case .never: nil
        case .twoHours: now.addingTimeInterval(2 * 60 * 60)
        case .oneDay: now.addingTimeInterval(24 * 60 * 60)
        }
    }
}

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

enum SocialRelationshipState: Equatable {
    case none
    case outgoingRequested
    case incomingRequested
    case following
    case followsYou
    case mutual
    case blocked
}

enum SocialPrivacyCategory: Equatable {
    case liveListening
    case listeningHistory
    case reviews
}

enum CatalogSearchPurpose: Hashable {
    case addMusic
    case reviews
}

struct CatalogSearchState: Equatable {
    var query = ""
    var results: [HarmonyTrack]?
    var isSearching = false
    var message: String?

    static let idle = CatalogSearchState()
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
    @Published private(set) var isConnectingAppleMusic = false
    @Published private(set) var isConnectingSpotifyPlayback = false
    @Published private(set) var isDisconnectingSpotify = false
    @Published private(set) var isDeletingAccount = false
    @Published private(set) var spotifyPlaybackConnection: ProviderConnectionState = .disconnected
    @Published private(set) var spotifyPlaybackErrorMessage: String?
    @Published private(set) var activeMemberIDs: Set<UUID> = []
    @Published private var catalogSearchStates: [CatalogSearchPurpose: CatalogSearchState] = [:]
    @Published private(set) var isClosingSession = false
    @Published private(set) var isUpdatingInvitePermissions = false
    @Published var allowsCollaboratorInvites = true
    @Published var selectedPlaybackMode: SessionPlaybackMode = .conductorPlayback
    @Published var selectedSessionExpiry: SessionExpiry = .never
    @Published private(set) var sessionExpiresAt: Date?
    @Published private(set) var recentSessions: [RemoteHarmonySession] = []
    @Published private(set) var isLoadingRecentSessions = false
    @Published private(set) var listeningFeed: [RemoteListeningPresence] = []
    @Published private(set) var isRefreshingListeningFeed = false
    @Published private(set) var isPublishingListeningPresence = false
    @Published private(set) var isEavesdropping = false
    @Published private(set) var listeningHistory: [RemoteListeningHistoryEntry] = []
    @Published private(set) var isRefreshingListeningHistory = false
    @Published private(set) var isRecordingListeningHistory = false
    @Published private(set) var isSavingDiaryEntry = false
    @Published private(set) var isImportingSpotifyHistory = false
    @Published private(set) var spotifyHistoryImportMessage: String?
    @Published private(set) var musicReviews: [RemoteMusicReview] = []
    @Published private(set) var isRefreshingMusicReviews = false
    @Published private(set) var isPublishingMusicReview = false
    @Published private(set) var mutatingReviewIDs: Set<UUID> = []
    @Published private(set) var socialProfiles: [RemoteSocialProfile] = []
    @Published private(set) var socialNotifications: [RemoteSocialNotification] = []
    @Published private(set) var isRefreshingSocialProfiles = false
    @Published private(set) var socialProfileActionIDs: Set<UUID> = []
    @Published private(set) var accountProfile: RemoteAccountProfile?
    @Published private(set) var socialSettings: RemoteSocialSettings?
    @Published private(set) var isRefreshingAccountSettings = false
    @Published private(set) var isUpdatingAccountSettings = false
    private var socialFollows: [RemoteSocialFollow] = []
    private var blockedSocialProfileIDs: Set<UUID> = []
    private var authenticatedProfileID: UUID?
    private var remoteSessionID: UUID?
    private var liveQueueSubscription: LiveQueueSubscription?
    private var liveSessionSubscription: LiveSessionSubscription?
    private var livePresenceSubscription: LivePresenceSubscription?
    private var liveSocialSubscription: LiveSocialSubscription?
    private var pendingSocialRefreshTask: Task<Void, Never>?
    private var hasBootstrapped = false
    private var isBootstrapping = false
    private var catalogSearchRequestIDs: [CatalogSearchPurpose: UUID] = [:]
    private let collaborationRepository = HarmonyCollaborationRepository()
    private let spotifyRemote: any SpotifyPlaybackProviding
    private let appleMusicProvider: any AppleMusicProviding
    private var spotifyLoadedProviderID: String?
#if DEBUG
    private var isDiaryEditorUITestFixtureActive = false
#endif
    @Published private(set) var currentMember: SessionMember
    @Published private(set) var members: [SessionMember]
    let catalog: [HarmonyTrack]
    convenience init() {
        self.init(spotifyRemote: SpotifyAppRemoteProvider(), appleMusicProvider: AppleMusicProvider())
    }

    convenience init(seedSampleData: Bool) {
        self.init(
            spotifyRemote: SpotifyAppRemoteProvider(),
            appleMusicProvider: AppleMusicProvider(),
            seedSampleData: seedSampleData
        )
    }

    convenience init(spotifyRemote: any SpotifyPlaybackProviding) {
        self.init(spotifyRemote: spotifyRemote, appleMusicProvider: AppleMusicProvider())
    }

    init(spotifyRemote: any SpotifyPlaybackProviding, appleMusicProvider: any AppleMusicProviding, seedSampleData: Bool = true) {
        self.spotifyRemote = spotifyRemote
        self.appleMusicProvider = appleMusicProvider
        spotifyPlaybackConnection = spotifyRemote.connectionState
        catalog = SampleCatalog.tracks
        if seedSampleData {
            let alex = SessionMember(name: "Alex Morgan", initials: "AM", role: .conductor, providers: [.appleMusic, .spotify])
            let sam = SessionMember(name: "Sam Lee", initials: "SL", role: .collaborator, providers: [.spotify])
            let priya = SessionMember(name: "Priya Shah", initials: "PS", role: .collaborator, providers: [.appleMusic])
            currentMember = alex
            members = [alex, sam, priya]
            queue = [QueueItem(track: catalog[0], addedBy: sam), QueueItem(track: catalog[2], addedBy: priya), QueueItem(track: catalog[1], addedBy: alex)]
        } else {
            let listener = SessionMember(name: "You", initials: "YOU", role: .conductor, providers: [])
            currentMember = listener
            members = [listener]
            queue = []
            queueRevision = 0
            playbackState = .paused
            sessionName = "My Harmony Session"
            inviteCode = ""
            collaborationMessage = "Ready to start a session"
            providerStates = [.appleMusic: .notConnected, .spotify: .notConnected]
        }
    }
    var nowPlaying: QueueItem? { queue.first }
    var catalogSearchResults: [HarmonyTrack]? { catalogSearchState(for: .addMusic).results }
    var isSearchingCatalog: Bool { catalogSearchState(for: .addMusic).isSearching }
    var catalogSearchMessage: String? { catalogSearchState(for: .addMusic).message }
    var isLiveSession: Bool { remoteSessionID != nil }
    var canShareInvite: Bool { isLiveSession && (currentMember.role == .conductor || allowsCollaboratorInvites) }
    var canControlPlayback: Bool { selectedPlaybackMode != .queueOnly && currentMember.role == .conductor }
    var canStartLiveSession: Bool {
        let title = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...120).contains(title.count)
    }
    var liveSocialVisibility: SocialVisibilityOption { socialSettings?.liveVisibility ?? .privateOnly }
    var historySocialVisibility: SocialVisibilityOption { socialSettings?.historyVisibility ?? .privateOnly }
    var reviewsSocialVisibility: SocialVisibilityOption { socialSettings?.reviewsVisibility ?? .privateOnly }
    var recordsHarmonyPlays: Bool { socialSettings?.recordHarmonyPlays ?? false }
    var unreadSocialNotificationCount: Int { socialNotifications.lazy.filter { $0.readAt == nil }.count }
    func providerState(for provider: MusicProvider) -> ProviderAccountStatus { providerStates[provider] ?? .notConnected }
    func canRemove(_ item: QueueItem) -> Bool { currentMember.role == .conductor || item.addedBy.id == currentMember.id }
    func contains(_ track: HarmonyTrack) -> Bool { queue.contains { Self.representsSameRecording($0.track, track) } }

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
            providerStates[.appleMusic] = appleMusicProvider.connectionState.isConnected ? .connected : .notConnected
        } catch {
            collaborationMessage = "Could not load connection status: \(error.localizedDescription)"
        }
    }

    func bootstrap() async {
        guard !hasBootstrapped, !isBootstrapping else { return }
        isBootstrapping = true
        defer { isBootstrapping = false }
        await refreshAccountSettings()
        guard let profile = accountProfile else { return }
        hasBootstrapped = true
        if !isLiveSession {
            let name = profile.displayName
            let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
            let previousID = currentMember.id
            let hydratedMember = SessionMember(
                id: profile.id,
                name: name,
                initials: initials.isEmpty ? "YOU" : initials,
                role: .conductor,
                providers: currentMember.providers
            )
            currentMember = hydratedMember
            members = [hydratedMember]
            queue = queue.map { item in
                QueueItem(id: item.id, track: item.track, addedBy: item.addedBy.id == previousID ? hydratedMember : item.addedBy)
            }
        }
        async let providers: Void = refreshProviderConnections()
        async let sessions: Void = refreshRecentSessions()
        async let notifications: Void = refreshSocialNotifications()
        _ = await (providers, sessions, notifications)
    }

    func refreshAccountSettings() async {
        guard !isRefreshingAccountSettings else { return }
        isRefreshingAccountSettings = true
        defer { isRefreshingAccountSettings = false }
        do {
            async let profile = collaborationRepository.accountProfile()
            async let settings = collaborationRepository.socialSettings()
            let result = try await (profile, settings)
            accountProfile = result.0
            socialSettings = result.1
        } catch {
            collaborationMessage = "Could not load account settings: \(error.localizedDescription)"
        }
    }

    func updateDisplayName(_ proposedName: String) async {
        let displayName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(displayName.count), !isUpdatingAccountSettings else {
            collaborationMessage = "Display names must contain 1 to 80 characters."
            return
        }
        isUpdatingAccountSettings = true
        defer { isUpdatingAccountSettings = false }
        do {
            accountProfile = try await collaborationRepository.updateDisplayName(displayName)
            collaborationMessage = "Profile updated"
            await refreshSocialProfiles()
        } catch {
            collaborationMessage = "Could not update profile: \(error.localizedDescription)"
        }
    }

    func updateSocialVisibility(_ visibility: SocialVisibilityOption, for category: SocialPrivacyCategory) async {
        guard let current = socialSettings, !isUpdatingAccountSettings else { return }
        let updated = RemoteSocialSettings(
            profileID: current.profileID,
            liveVisibility: category == .liveListening ? visibility : current.liveVisibility,
            historyVisibility: category == .listeningHistory ? visibility : current.historyVisibility,
            reviewsVisibility: category == .reviews ? visibility : current.reviewsVisibility,
            recordHarmonyPlays: current.recordHarmonyPlays
        )
        isUpdatingAccountSettings = true
        defer { isUpdatingAccountSettings = false }
        do {
            socialSettings = try await collaborationRepository.updateSocialSettings(updated)
            if category == .liveListening, visibility == .privateOnly, isEavesdropping {
                try await collaborationRepository.stopListeningPresence()
                isEavesdropping = false
                await refreshListeningFeed()
            }
            collaborationMessage = visibility == .followers ? "Sharing enabled for approved followers" : "Visibility changed to Only me"
        } catch {
            collaborationMessage = "Could not update privacy settings: \(error.localizedDescription)"
        }
    }

    func updateHistoryRecording(_ enabled: Bool) async {
        guard let current = socialSettings, !isUpdatingAccountSettings else { return }
        let updated = RemoteSocialSettings(
            profileID: current.profileID,
            liveVisibility: current.liveVisibility,
            historyVisibility: current.historyVisibility,
            reviewsVisibility: current.reviewsVisibility,
            recordHarmonyPlays: enabled
        )
        isUpdatingAccountSettings = true
        defer { isUpdatingAccountSettings = false }
        do {
            socialSettings = try await collaborationRepository.updateSocialSettings(updated)
            collaborationMessage = enabled ? "Harmony will log tracks when you skip to the next song" : "Automatic Harmony history logging disabled"
        } catch {
            collaborationMessage = "Could not update history consent: \(error.localizedDescription)"
        }
    }

    func connectAppleMusic() async {
        guard !isConnectingAppleMusic else { return }
        isConnectingAppleMusic = true
        defer { isConnectingAppleMusic = false }
        do {
            try await appleMusicProvider.authorize()
            providerStates[.appleMusic] = .connected
            collaborationMessage = "Apple Music connected"
        } catch {
            providerStates[.appleMusic] = .notConnected
            collaborationMessage = "Apple Music connection failed: \(error.localizedDescription)"
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
            if selectedPlaybackMode == .personalListenAlong && playbackState == .paused {
                _ = try await spotifyRemote.perform(.pause)
                collaborationMessage = "Spotify is ready to listen along"
            } else if try await playCurrentSpotifyTrackIfAvailable() {
                collaborationMessage = selectedPlaybackMode == .personalListenAlong
                    ? "Listening along with the Harmony queue on Spotify"
                    : "Playing the Harmony queue on Spotify"
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
            await detachSocialSubscription()
            spotifyRemote.disconnect()
            try await collaborationRepository.deleteAccount()
            clearSessionState(message: "Harmony account deleted")
            providerStates = [.appleMusic: .setupRequired, .spotify: .notConnected]
            spotifyPlaybackConnection = .disconnected
            spotifyLoadedProviderID = nil
            resetCatalogSearch()
        } catch {
            collaborationMessage = "Could not delete account: \(error.localizedDescription)"
        }
    }

    func catalogSearchState(for purpose: CatalogSearchPurpose) -> CatalogSearchState {
        catalogSearchStates[purpose] ?? .idle
    }

    func resetCatalogSearch(_ purpose: CatalogSearchPurpose? = nil) {
        if let purpose {
            catalogSearchRequestIDs[purpose] = UUID()
            catalogSearchStates[purpose] = .idle
        } else {
            for purpose in [CatalogSearchPurpose.addMusic, .reviews] {
                catalogSearchRequestIDs[purpose] = UUID()
            }
            catalogSearchStates.removeAll()
        }
    }

    func searchCatalog(query: String, purpose: CatalogSearchPurpose = .addMusic) async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else {
            resetCatalogSearch(purpose)
            return
        }

        let requestID = UUID()
        catalogSearchRequestIDs[purpose] = requestID
        let canSearchSpotify = providerState(for: .spotify) == .connected
        let canSearchAppleMusic = providerState(for: .appleMusic) == .connected
        guard canSearchSpotify || canSearchAppleMusic else {
            let results = catalog.filter {
                "\($0.title) \($0.artist) \($0.album)".localizedCaseInsensitiveContains(term)
            }
            guard isCurrentCatalogSearch(requestID, for: purpose) else { return }
            catalogSearchStates[purpose] = CatalogSearchState(
                query: term,
                results: results,
                message: "Connect Spotify or Apple Music to search its full catalog."
            )
            return
        }
        catalogSearchStates[purpose] = CatalogSearchState(query: term, isSearching: true)
        var results: [HarmonyTrack] = []
        var failures: [String] = []
        if canSearchAppleMusic {
            do { results += try await appleMusicProvider.search(query: term) }
            catch { failures.append("Apple Music: \(error.localizedDescription)") }
        }
        guard !Task.isCancelled else {
            finishCancelledCatalogSearch(requestID, term: term, purpose: purpose)
            return
        }
        if canSearchSpotify {
            do {
                results += try await collaborationRepository.searchSpotify(query: term).map(Self.harmonyTrack)
            } catch {
                failures.append("Spotify: \(error.localizedDescription)")
            }
        }
        guard !Task.isCancelled else {
            finishCancelledCatalogSearch(requestID, term: term, purpose: purpose)
            return
        }
        guard isCurrentCatalogSearch(requestID, for: purpose) else { return }
        let mergedResults = Self.mergeCatalogResults(results)
        catalogSearchStates[purpose] = CatalogSearchState(
            query: term,
            results: mergedResults,
            message: Self.catalogSearchMessage(results: mergedResults, failures: failures)
        )
    }

    private func isCurrentCatalogSearch(_ requestID: UUID, for purpose: CatalogSearchPurpose) -> Bool {
        catalogSearchRequestIDs[purpose] == requestID
    }

    private func finishCancelledCatalogSearch(_ requestID: UUID, term: String, purpose: CatalogSearchPurpose) {
        guard isCurrentCatalogSearch(requestID, for: purpose) else { return }
        catalogSearchStates[purpose] = CatalogSearchState(query: term)
    }

    static func catalogSearchMessage(results: [HarmonyTrack], failures: [String]) -> String? {
        if results.isEmpty {
            return failures.isEmpty ? "No tracks found." : failures.joined(separator: "\n")
        }
        return failures.isEmpty ? nil : failures.joined(separator: "\n")
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
        guard !contains(track) else { return }
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
        guard canControlPlayback else { return }
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
        guard canControlPlayback, queue.count > 1 else { return }
        let completedTrack = queue.first?.track
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
        if recordsHarmonyPlays, let completedTrack {
            await recordListeningHistory(completedTrack)
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
        let title = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...120).contains(title.count) else {
            collaborationMessage = "Give this session a name of up to 120 characters."
            return
        }
        let draftTracks = queue.map(\.track)
        sessionName = title
        collaborationMessage = "Connecting…"
        do {
            let remoteSession = try await collaborationRepository.createSession(
                title: title,
                allowCollaboratorInvites: allowsCollaboratorInvites,
                playbackMode: selectedPlaybackMode,
                expiresAt: selectedSessionExpiry.date()
            )
            sessionName = remoteSession.title
            inviteCode = remoteSession.inviteCode
            queueRevision = remoteSession.queueRevision
            allowsCollaboratorInvites = remoteSession.allowCollaboratorInvites
            selectedPlaybackMode = remoteSession.playbackMode
            sessionExpiresAt = remoteSession.expiresAt
            remoteSessionID = remoteSession.id
            collaborationMessage = "Live Supabase session"
            var draftRevision = remoteSession.queueRevision
            var draftUploadFailed = false
            for track in draftTracks {
                do {
                    draftRevision = try await collaborationRepository.add(
                        track: track,
                        to: remoteSession.id,
                        expectedRevision: draftRevision
                    )
                } catch {
                    draftUploadFailed = true
                    break
                }
            }
            queueRevision = draftRevision
            await refreshRemoteQueue()
            await subscribeToRemoteQueue(remoteSession.id)
            await subscribeToSessionLifecycle(remoteSession.id)
            await subscribeToPresence(remoteSession.id)
            await refreshRecentSessions()
            if draftUploadFailed {
                collaborationMessage = "Session started, but some draft tracks could not be added."
            }
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
            allowsCollaboratorInvites = remoteSession.allowCollaboratorInvites
            selectedPlaybackMode = remoteSession.playbackMode
            sessionExpiresAt = remoteSession.expiresAt
            remoteSessionID = remoteSession.id
            collaborationMessage = "Joined live Supabase session"
            await refreshRemoteQueue()
            await subscribeToRemoteQueue(remoteSession.id)
            await subscribeToSessionLifecycle(remoteSession.id)
            await subscribeToPresence(remoteSession.id)
            await refreshRecentSessions()
        } catch {
            collaborationMessage = "Join failed: \(error.localizedDescription)"
        }
    }

    func refreshRecentSessions() async {
        guard !isLoadingRecentSessions else { return }
        isLoadingRecentSessions = true
        defer { isLoadingRecentSessions = false }
        do {
            recentSessions = try await collaborationRepository.recentSessions()
        } catch {
            // Recents are supplementary; session creation/joining remains usable offline.
        }
    }

    func refreshListeningFeed() async {
        guard !isRefreshingListeningFeed else { return }
        isRefreshingListeningFeed = true
        defer { isRefreshingListeningFeed = false }
        do {
            async let feed = collaborationRepository.listeningFeed()
            async let currentUserID = collaborationRepository.currentUserID()
            let (activity, userID) = try await (feed, currentUserID)
            listeningFeed = activity
            isEavesdropping = activity.contains(where: { $0.profileID == userID })
        } catch {
            collaborationMessage = "Could not refresh listening activity."
        }
    }

    func activateSocialRealtime() async {
        guard liveSocialSubscription == nil else { return }
        do {
            liveSocialSubscription = try await collaborationRepository.observeSocialActivity { [weak self] in
                Task { @MainActor in self?.scheduleSocialRefresh() }
            }
        } catch {
            // Pull to refresh remains available when Realtime cannot connect.
        }
    }

    private func scheduleSocialRefresh() {
        pendingSocialRefreshTask?.cancel()
        pendingSocialRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            async let profiles: Void = self.refreshSocialProfiles()
            async let feed: Void = self.refreshListeningFeed()
            async let history: Void = self.refreshListeningHistory()
            async let reviews: Void = self.refreshMusicReviews()
            async let notifications: Void = self.refreshSocialNotifications()
            _ = await (profiles, feed, history, reviews, notifications)
        }
    }

    func refreshListeningHistory() async {
#if DEBUG
        guard !isDiaryEditorUITestFixtureActive else { return }
#endif
        guard !isRefreshingListeningHistory else { return }
        isRefreshingListeningHistory = true
        defer { isRefreshingListeningHistory = false }
        do { listeningHistory = try await collaborationRepository.listeningHistory() }
        catch { collaborationMessage = "Could not refresh listening history." }
    }

    func recordCurrentTrackInHistory() async {
        guard let track = nowPlaying?.track else {
            collaborationMessage = "Start a Harmony queue track before logging it."
            return
        }
        await recordListeningHistory(track)
    }

    @discardableResult
    func createDiaryEntry(
        track: HarmonyTrack,
        listenedOn: Date,
        isRelisten: Bool,
        tags: [String],
        visibility: SocialVisibilityOption
    ) async -> Bool {
        guard !isSavingDiaryEntry else { return false }
        isSavingDiaryEntry = true
        defer { isSavingDiaryEntry = false }
        do {
            _ = try await collaborationRepository.createListeningDiaryEntry(
                track: track,
                listenedOn: listenedOn,
                isRelisten: isRelisten,
                tags: tags,
                visibility: visibility
            )
            collaborationMessage = visibility == .followers
                ? "Listen added to your follower-visible journal"
                : "Private journal entry saved"
            await refreshListeningHistory()
            return true
        } catch {
            collaborationMessage = "Could not save journal entry: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func updateDiaryEntry(
        _ entry: RemoteListeningHistoryEntry,
        listenedOn: Date,
        isRelisten: Bool,
        tags: [String],
        visibility: SocialVisibilityOption,
        reviewID: UUID?
    ) async -> Bool {
        guard entry.source == "manual", isOwnHistoryEntry(entry) else {
            collaborationMessage = "Only your manually logged listens can be edited."
            return false
        }
        if let reviewID {
            guard compatibleOwnTrackReviews(for: entry).contains(where: { $0.id == reviewID }) else {
                collaborationMessage = "That opinion does not match this journal entry."
                return false
            }
        }
        guard !isSavingDiaryEntry else { return false }
        isSavingDiaryEntry = true
        defer { isSavingDiaryEntry = false }
        do {
            try await collaborationRepository.updateListeningDiaryEntry(
                entry.id,
                playedAt: listenedOn,
                isRelisten: isRelisten,
                tags: tags,
                visibility: visibility,
                reviewID: reviewID
            )
            collaborationMessage = "Journal entry updated"
            await refreshListeningHistory()
            return true
        } catch {
            collaborationMessage = "Could not update journal entry: \(error.localizedDescription)"
            return false
        }
    }

    func compatibleOwnTrackReviews(for entry: RemoteListeningHistoryEntry) -> [RemoteMusicReview] {
        guard let entryTrackID = entry.canonicalTrack?.id else { return [] }
        return musicReviews.filter { review in
            isOwnReview(review)
                && review.subjectKind == "track"
                && review.canonicalTrack?.id == entryTrackID
        }
    }

#if DEBUG
    /// Keeps editor UI tests deterministic and independent of a developer's
    /// signed-in account or hosted journal contents.
    func seedDiaryEditorUITestFixture() {
        let profileID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let trackID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let reviewID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        let entryID = UUID(uuidString: "40000000-0000-0000-0000-000000000004")!
        let profile = RemoteProfile(displayName: "UI Test Listener")
        let track = RemoteCatalogTrack(
            id: trackID,
            title: "Afterglow",
            artist: "Wolves at Noon",
            album: "Northern Lights",
            durationMilliseconds: 206_000,
            artworkURL: nil,
            isExplicit: false,
            providerTracks: nil
        )
        let review = RemoteMusicReview(
            id: reviewID,
            profileID: profileID,
            rating: 4.5,
            body: "A fixture opinion.",
            createdAt: Date(),
            visibility: .privateOnly,
            containsSpoilers: false,
            isLoved: true,
            subjectKind: "track",
            subjectTitle: track.title,
            subjectArtist: track.artist,
            subjectArtworkURL: nil,
            subjectDeepLink: nil,
            canonicalTrack: track,
            profile: profile,
            comments: [],
            reactions: []
        )
        authenticatedProfileID = profileID
        isDiaryEditorUITestFixtureActive = true
        musicReviews = [review]
        listeningHistory = [RemoteListeningHistoryEntry(
            id: entryID,
            profileID: profileID,
            playedAt: Calendar.current.date(byAdding: .day, value: -2, to: Date())!,
            source: "manual",
            visibility: .privateOnly,
            isRelisten: true,
            tags: ["party", "vinyl"],
            reviewID: reviewID,
            canonicalTrack: track,
            profile: profile
        )]
    }
#endif

    func deleteListeningHistoryEntry(_ entryID: UUID) async {
        do {
            try await collaborationRepository.deleteListeningHistoryEntry(entryID)
            collaborationMessage = "History entry deleted"
            await refreshListeningHistory()
        } catch { collaborationMessage = "Could not delete history entry: \(error.localizedDescription)" }
    }

    func importRecentSpotifyHistory() async {
        guard providerState(for: .spotify) == .connected, !isImportingSpotifyHistory else { return }
        isImportingSpotifyHistory = true
        spotifyHistoryImportMessage = nil
        defer { isImportingSpotifyHistory = false }
        do {
            let result = try await collaborationRepository.importSpotifyHistory()
            spotifyHistoryImportMessage = result.imported == 0
                ? "Spotify history is already up to date."
                : "Imported \(result.imported) recent Spotify \(result.imported == 1 ? "play" : "plays")."
            await refreshListeningHistory()
        } catch {
            spotifyHistoryImportMessage = error.localizedDescription
        }
    }

    func isOwnHistoryEntry(_ entry: RemoteListeningHistoryEntry) -> Bool { entry.profileID == authenticatedProfileID }

    private func recordListeningHistory(_ track: HarmonyTrack) async {
        guard !isRecordingListeningHistory else { return }
        isRecordingListeningHistory = true
        defer { isRecordingListeningHistory = false }
        do {
            try await collaborationRepository.recordListeningHistory(track: track, visibility: historySocialVisibility)
            collaborationMessage = historySocialVisibility == .followers ? "Track added to follower-visible history" : "Track added to private history"
            await refreshListeningHistory()
        } catch { collaborationMessage = "Could not log listening history: \(error.localizedDescription)" }
    }

    func refreshSocialProfiles() async {
        guard !isRefreshingSocialProfiles else { return }
        isRefreshingSocialProfiles = true
        defer { isRefreshingSocialProfiles = false }
        do {
            async let profiles = collaborationRepository.socialProfiles()
            async let follows = collaborationRepository.socialFollows()
            async let blocks = collaborationRepository.socialBlocks()
            async let userID = collaborationRepository.currentUserID()
            let result = try await (profiles, follows, blocks, userID)
            socialProfiles = result.0
            socialFollows = result.1
            blockedSocialProfileIDs = Set(result.2.map(\.blockedID))
            authenticatedProfileID = result.3
        } catch {
            collaborationMessage = "Could not refresh people: \(error.localizedDescription)"
        }
    }

    func refreshSocialNotifications() async {
        do { socialNotifications = try await collaborationRepository.socialNotifications() }
        catch { collaborationMessage = "Could not refresh social notifications." }
    }

    func markSocialNotificationsRead(_ notificationID: UUID? = nil) async {
        do {
            try await collaborationRepository.markSocialNotificationsRead(notificationID)
            await refreshSocialNotifications()
        } catch { collaborationMessage = "Could not update social notifications." }
    }

    func socialRelationship(with profileID: UUID) -> SocialRelationshipState {
        guard let authenticatedProfileID else { return .none }
        if blockedSocialProfileIDs.contains(profileID) { return .blocked }
        let outgoing = socialFollows.first { $0.followerID == authenticatedProfileID && $0.followedID == profileID }
        let incoming = socialFollows.first { $0.followerID == profileID && $0.followedID == authenticatedProfileID }
        if outgoing?.state == "accepted" && incoming?.state == "accepted" { return .mutual }
        if outgoing?.state == "accepted" { return .following }
        if incoming?.state == "accepted" { return .followsYou }
        if incoming?.state == "requested" { return .incomingRequested }
        if outgoing?.state == "requested" { return .outgoingRequested }
        return .none
    }

    func requestSocialFollow(_ profileID: UUID) async {
        await performSocialAction(profileID, successMessage: "Follow request sent") {
            try await self.collaborationRepository.requestSocialFollow(profileID)
        }
    }

    func respondToSocialFollow(from profileID: UUID, accept: Bool) async {
        await performSocialAction(profileID, successMessage: accept ? "Follow request accepted" : "Follow request declined") {
            try await self.collaborationRepository.respondToSocialFollow(from: profileID, accept: accept)
        }
    }

    func removeSocialFollow(_ profileID: UUID) async {
        await performSocialAction(profileID, successMessage: "Unfollowed") {
            try await self.collaborationRepository.removeSocialFollow(profileID)
        }
    }

    func removeSocialFollower(_ profileID: UUID) async {
        await performSocialAction(profileID, successMessage: "Follower removed") {
            try await self.collaborationRepository.removeSocialFollower(profileID)
        }
    }

    func blockSocialProfile(_ profileID: UUID) async {
        await performSocialAction(profileID, successMessage: "Profile blocked") {
            try await self.collaborationRepository.blockSocialProfile(profileID)
        }
    }

    func unblockSocialProfile(_ profileID: UUID) async {
        await performSocialAction(profileID, successMessage: "Profile unblocked") {
            try await self.collaborationRepository.unblockSocialProfile(profileID)
        }
    }

    private func performSocialAction(
        _ profileID: UUID,
        successMessage: String,
        operation: @escaping () async throws -> Void
    ) async {
        guard !socialProfileActionIDs.contains(profileID) else { return }
        socialProfileActionIDs.insert(profileID)
        defer { socialProfileActionIDs.remove(profileID) }
        do {
            try await operation()
            collaborationMessage = successMessage
            await refreshSocialProfiles()
        } catch {
            collaborationMessage = "Follower action failed: \(error.localizedDescription)"
        }
    }

    func toggleEavesdropping() async {
        guard !isPublishingListeningPresence else { return }
        isPublishingListeningPresence = true
        defer { isPublishingListeningPresence = false }
        do {
            if isEavesdropping {
                try await collaborationRepository.stopListeningPresence()
                isEavesdropping = false
                listeningFeed.removeAll { $0.profileID == currentMember.id }
                collaborationMessage = "Stopped sharing listening activity"
            } else {
                guard let track = nowPlaying?.track else {
                    collaborationMessage = "Start a Harmony queue track before sharing listening activity."
                    return
                }
                try await collaborationRepository.publishListeningPresence(track: track, visibility: liveSocialVisibility)
                collaborationMessage = liveSocialVisibility == .followers
                    ? "Sharing this track with approved followers for five minutes"
                    : "Saved a private now-listening entry for five minutes"
                await refreshListeningFeed()
            }
        } catch {
            collaborationMessage = "Could not update listening activity: \(error.localizedDescription)"
        }
    }

    func shareSpotifyNowListening() async {
        guard providerState(for: .spotify) == .connected, !isPublishingListeningPresence else { return }
        isPublishingListeningPresence = true
        defer { isPublishingListeningPresence = false }
        do {
            let response = try await collaborationRepository.publishSpotifyNowListening()
            guard response.published else {
                collaborationMessage = response.reason == "unsupported_content"
                    ? "Spotify is playing content Harmony cannot share yet."
                    : "Start playing a song in Spotify, then try again."
                return
            }
            let trackDescription = [response.title, response.artist].compactMap { $0 }.joined(separator: " — ")
            collaborationMessage = liveSocialVisibility == .followers
                ? "Sharing \(trackDescription) with approved followers for five minutes"
                : "Saved \(trackDescription) as a private now-listening entry"
            await refreshListeningFeed()
        } catch {
            collaborationMessage = "Could not share Spotify activity: \(error.localizedDescription)"
        }
    }

    func refreshMusicReviews() async {
#if DEBUG
        guard !isDiaryEditorUITestFixtureActive else { return }
#endif
        guard !isRefreshingMusicReviews else { return }
        isRefreshingMusicReviews = true
        defer { isRefreshingMusicReviews = false }
        do { musicReviews = try await collaborationRepository.musicReviews() }
        catch { collaborationMessage = "Could not refresh reviews." }
    }

    @discardableResult
    func publishTrackReview(rating: Double, body: String, isLoved: Bool = false, containsSpoilers: Bool = false, visibility: SocialVisibilityOption? = nil) async -> Bool {
        guard let track = nowPlaying?.track else { return false }
        return await publishTrackReview(track, rating: rating, body: body, isLoved: isLoved, containsSpoilers: containsSpoilers, visibility: visibility)
    }

    @discardableResult
    func publishTrackReview(_ track: HarmonyTrack, rating: Double, body: String, isLoved: Bool = false, containsSpoilers: Bool = false, visibility: SocialVisibilityOption? = nil) async -> Bool {
        guard !isPublishingMusicReview else { return false }
        let resolvedVisibility = visibility ?? reviewsSocialVisibility
        isPublishingMusicReview = true
        defer { isPublishingMusicReview = false }
        do {
            try await collaborationRepository.createTrackReview(
                track: track,
                rating: rating,
                body: body,
                visibility: resolvedVisibility,
                isLoved: isLoved,
                containsSpoilers: containsSpoilers
            )
            collaborationMessage = resolvedVisibility == .followers
                ? "Review published to approved followers"
                : "Private review saved"
            await refreshMusicReviews()
            return true
        } catch {
            collaborationMessage = "Could not publish review: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func publishAlbumReview(_ album: ReviewableAlbum, rating: Double, body: String, isLoved: Bool = false, containsSpoilers: Bool = false, visibility: SocialVisibilityOption? = nil) async -> Bool {
        guard !isPublishingMusicReview else { return false }
        let resolvedVisibility = visibility ?? reviewsSocialVisibility
        isPublishingMusicReview = true
        defer { isPublishingMusicReview = false }
        do {
            try await collaborationRepository.createAlbumReview(
                album: album,
                rating: rating,
                body: body,
                visibility: resolvedVisibility,
                isLoved: isLoved,
                containsSpoilers: containsSpoilers
            )
            collaborationMessage = resolvedVisibility == .followers
                ? "Album review published to approved followers"
                : "Private album review saved"
            await refreshMusicReviews()
            return true
        } catch {
            collaborationMessage = "Could not publish album review: \(error.localizedDescription)"
            return false
        }
    }

    func toggleReviewHeart(_ reviewID: UUID) async {
        do {
            let added = try await collaborationRepository.toggleHeart(on: reviewID)
            collaborationMessage = added ? "Reaction added" : "Reaction removed"
            await refreshMusicReviews()
        } catch { collaborationMessage = "Could not update reaction: \(error.localizedDescription)" }
    }

    func isOwnReview(_ review: RemoteMusicReview) -> Bool { review.profileID == authenticatedProfileID }
    func isOwnComment(_ comment: RemoteReviewComment) -> Bool { comment.authorID == authenticatedProfileID }
    func hasHeart(on review: RemoteMusicReview) -> Bool {
        guard let authenticatedProfileID else { return false }
        return review.reactions.contains { $0.profileID == authenticatedProfileID && $0.kind == "heart" }
    }

    @discardableResult
    func addReviewComment(to reviewID: UUID, body: String) async -> Bool {
        let comment = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...2000).contains(comment.count) else {
            collaborationMessage = "Comments must contain 1 to 2,000 characters."
            return false
        }
        return await performReviewMutation(reviewID, successMessage: "Comment added") {
            try await self.collaborationRepository.addComment(to: reviewID, body: comment)
        }
    }

    @discardableResult
    func deleteReviewComment(_ commentID: UUID, from reviewID: UUID) async -> Bool {
        await performReviewMutation(reviewID, successMessage: "Comment deleted") {
            try await self.collaborationRepository.deleteComment(commentID)
        }
    }

    @discardableResult
    func updateReview(_ reviewID: UUID, rating: Double, body: String, visibility: SocialVisibilityOption, isLoved: Bool, containsSpoilers: Bool = false) async -> Bool {
        await performReviewMutation(reviewID, successMessage: "Review updated") {
            try await self.collaborationRepository.updateReview(
                reviewID,
                rating: rating,
                body: body,
                visibility: visibility,
                isLoved: isLoved,
                containsSpoilers: containsSpoilers
            )
        }
    }

    @discardableResult
    func deleteReview(_ reviewID: UUID) async -> Bool {
        await performReviewMutation(reviewID, successMessage: "Review deleted") {
            try await self.collaborationRepository.deleteReview(reviewID)
        }
    }

    private func performReviewMutation(
        _ reviewID: UUID,
        successMessage: String,
        operation: @escaping () async throws -> Void
    ) async -> Bool {
        guard !mutatingReviewIDs.contains(reviewID) else { return false }
        mutatingReviewIDs.insert(reviewID)
        defer { mutatingReviewIDs.remove(reviewID) }
        do {
            try await operation()
            collaborationMessage = successMessage
            await refreshMusicReviews()
            return true
        } catch {
            collaborationMessage = "Could not update review: \(error.localizedDescription)"
            return false
        }
    }

    func resumeLiveSession(id: UUID) async {
        collaborationMessage = "Opening session…"
        do {
            let remoteSession = try await collaborationRepository.session(id: id)
            guard remoteSession.endedAt == nil,
                  remoteSession.expiresAt.map({ $0 > Date() }) ?? true else {
                collaborationMessage = "This Harmony session is no longer active."
                await refreshRecentSessions()
                return
            }
            await detachLiveSubscriptions()
            sessionName = remoteSession.title
            inviteCode = remoteSession.inviteCode
            queueRevision = remoteSession.queueRevision
            allowsCollaboratorInvites = remoteSession.allowCollaboratorInvites
            selectedPlaybackMode = remoteSession.playbackMode
            sessionExpiresAt = remoteSession.expiresAt
            remoteSessionID = remoteSession.id
            collaborationMessage = "Resumed live Supabase session"
            await refreshRemoteQueue()
            await subscribeToRemoteQueue(remoteSession.id)
            await subscribeToSessionLifecycle(remoteSession.id)
            await subscribeToPresence(remoteSession.id)
        } catch {
            collaborationMessage = "Could not open this session: \(error.localizedDescription)"
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
            let message = currentMember.role == .conductor ? "Session ended" : "You left the session"
            clearSessionState(message: message)
        } catch {
            collaborationMessage = "Could not close session: \(error.localizedDescription)"
        }
    }

    func setCollaboratorInvitesAllowed(_ allowed: Bool) async {
        guard let remoteSessionID, currentMember.role == .conductor, !isUpdatingInvitePermissions else { return }
        isUpdatingInvitePermissions = true
        defer { isUpdatingInvitePermissions = false }
        do {
            let session = try await collaborationRepository.setCollaboratorInvitesAllowed(in: remoteSessionID, allowed: allowed)
            allowsCollaboratorInvites = session.allowCollaboratorInvites
            selectedPlaybackMode = session.playbackMode
            sessionExpiresAt = session.expiresAt
            collaborationMessage = allowed ? "Collaborators can share invites" : "Only the Conductor can share invites"
        } catch {
            collaborationMessage = "Could not update invite permissions: \(error.localizedDescription)"
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
            if let expiresAt = session.expiresAt, expiresAt <= Date() {
                await detachLiveSubscriptions()
                clearSessionState(message: "This Harmony session has expired")
                return
            }
            sessionName = session.title
            inviteCode = session.inviteCode
            queueRevision = session.queueRevision
            allowsCollaboratorInvites = session.allowCollaboratorInvites
            selectedPlaybackMode = session.playbackMode
            sessionExpiresAt = session.expiresAt
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
            await synchronizePersonalSpotifyPlaybackIfNeeded()
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

    private func synchronizePersonalSpotifyPlaybackIfNeeded() async {
        guard selectedPlaybackMode == .personalListenAlong, spotifyPlaybackConnection.isConnected else { return }
        do {
            if playbackState == .playing {
                _ = try await playCurrentSpotifyTrackIfAvailable()
            } else {
                _ = try await spotifyRemote.perform(.pause)
            }
        } catch {
            collaborationMessage = "Personal Spotify playback could not sync: \(error.localizedDescription)"
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
            if let expiresAt = session.expiresAt, expiresAt <= Date() {
                await detachLiveSubscriptions()
                clearSessionState(message: "This Harmony session has expired")
                return
            }
            guard session.endedAt != nil else { return }
            await detachLiveSubscriptions()
            clearSessionState(message: "The Conductor ended this session")
        } catch {
            collaborationMessage = "Could not refresh session status."
        }
    }

    private func record(_ type: QueueCommandType) {
        queueRevision += 1
        events.append(QueueEvent(revision: queueRevision, actorID: currentMember.id, type: type))
    }

    func clearSessionState(message: String) {
        let localOwner = SessionMember(
            id: currentMember.id,
            name: currentMember.name,
            initials: currentMember.initials,
            role: .conductor,
            providers: currentMember.providers
        )
        remoteSessionID = nil
        activeMemberIDs = []
        queue = []
        queueRevision = 0
        events = []
        playbackState = .paused
        spotifyLoadedProviderID = nil
        currentMember = localOwner
        members = [localOwner]
        inviteCode = ""
        allowsCollaboratorInvites = true
        selectedPlaybackMode = .conductorPlayback
        selectedSessionExpiry = .never
        sessionExpiresAt = nil
        sessionName = "No active session"
        collaborationMessage = message
    }

    private func detachLiveSubscriptions() async {
        await liveQueueSubscription?.channel.unsubscribe()
        await liveSessionSubscription?.channel.unsubscribe()
        await livePresenceSubscription?.channel.unsubscribe()
        liveQueueSubscription = nil
        liveSessionSubscription = nil
        livePresenceSubscription = nil
    }

    private func detachSocialSubscription() async {
        pendingSocialRefreshTask?.cancel()
        pendingSocialRefreshTask = nil
        await liveSocialSubscription?.channel.unsubscribe()
        liveSocialSubscription = nil
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

    private static func harmonyTrack(_ result: SpotifySearchTrack) -> HarmonyTrack {
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
            )],
            reviewableAlbum: ReviewableAlbum(
                provider: .spotify,
                providerID: result.albumProviderID,
                title: result.album,
                artist: result.albumArtist,
                artworkURL: result.artworkURL,
                deepLinkURL: result.albumDeepLinkURL
            )
        )
    }

    private static func mergeCatalogResults(_ tracks: [HarmonyTrack]) -> [HarmonyTrack] {
        tracks.reduce(into: [HarmonyTrack]()) { results, track in
            guard let existingIndex = results.firstIndex(where: { representsSameRecording($0, track) }) else {
                results.append(track)
                return
            }
            let existing = results[existingIndex]
            let mappings = Array(Set(existing.mappings + track.mappings))
            results[existingIndex] = HarmonyTrack(
                id: existing.id,
                title: existing.title,
                artist: existing.artist,
                album: existing.album,
                duration: existing.duration,
                symbol: existing.symbol,
                artworkURL: existing.artworkURL ?? track.artworkURL,
                isExplicit: existing.isExplicit || track.isExplicit,
                mappings: mappings,
                reviewableAlbum: existing.reviewableAlbum ?? track.reviewableAlbum
            )
        }
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

    private static func representsSameRecording(_ lhs: HarmonyTrack, _ rhs: HarmonyTrack) -> Bool {
        if lhs.id == rhs.id { return true }
        let lhsProviderIDs = Set(lhs.mappings.filter { !$0.providerID.isEmpty }.map { "\($0.provider.rawValue):\($0.providerID)" })
        let rhsProviderIDs = Set(rhs.mappings.filter { !$0.providerID.isEmpty }.map { "\($0.provider.rawValue):\($0.providerID)" })
        if !lhsProviderIDs.isDisjoint(with: rhsProviderIDs) { return true }
        return lhs.title.compare(rhs.title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            && lhs.artist.compare(rhs.artist, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
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
