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
    let storefront: String
    let availability: ProviderAvailability
    let deepLinkURL: URL?

    init(provider: MusicProvider, providerID: String, storefront: String? = nil, availability: ProviderAvailability, deepLinkURL: URL? = nil) {
        self.provider = provider
        self.providerID = providerID
        self.storefront = storefront ?? (provider == .spotify ? "global" : "us")
        self.availability = availability
        self.deepLinkURL = deepLinkURL
    }
}
struct ReviewableAlbum: Hashable, Identifiable {
    let canonicalAlbumID: UUID?
    let provider: MusicProvider
    let providerID: String
    let storefront: String
    let title: String
    let artist: String
    let artworkURL: URL?
    let deepLinkURL: URL?
    var id: String { "\(provider.rawValue):\(providerID)" }

    init(
        canonicalAlbumID: UUID? = nil,
        provider: MusicProvider,
        providerID: String,
        storefront: String? = nil,
        title: String,
        artist: String,
        artworkURL: URL?,
        deepLinkURL: URL?
    ) {
        self.canonicalAlbumID = canonicalAlbumID
        self.provider = provider
        self.providerID = providerID
        self.storefront = storefront ?? (provider == .spotify ? "global" : "us")
        self.title = title
        self.artist = artist
        self.artworkURL = artworkURL
        self.deepLinkURL = deepLinkURL
    }
}
struct HarmonyTrack: Identifiable, Hashable {
    let id: UUID
    let canonicalTrackID: UUID?
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let symbol: String
    let artworkURL: URL?
    let isExplicit: Bool
    let isrc: String?
    let mappings: [ProviderTrackMapping]
    let reviewableAlbum: ReviewableAlbum?

    init(id: UUID = UUID(), canonicalTrackID: UUID? = nil, title: String, artist: String, album: String, duration: TimeInterval, symbol: String, artworkURL: URL? = nil, isExplicit: Bool = false, isrc: String? = nil, mappings: [ProviderTrackMapping], reviewableAlbum: ReviewableAlbum? = nil) {
        self.id = id
        self.canonicalTrackID = canonicalTrackID
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.symbol = symbol
        self.artworkURL = artworkURL
        self.isExplicit = isExplicit
        self.isrc = isrc
        self.mappings = mappings
        self.reviewableAlbum = reviewableAlbum
    }
    func availability(for provider: MusicProvider) -> ProviderAvailability { mappings.first(where: { $0.provider == provider })?.availability ?? .unavailable }
    var durationText: String { String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60) }
}

/// Editable, value-typed owner state for one canonical track. Keeping this as
/// a draft prevents controls on a detail page from mutating the persisted
/// cache before the backend accepts the complete replacement.
struct TrackSubjectStateDraft: Equatable {
    var hasListened: Bool
    var defaultRating: Double?
    var isLoved: Bool
    var wantToListen: Bool

    static let empty = TrackSubjectStateDraft()

    init(
        hasListened: Bool = false,
        defaultRating: Double? = nil,
        isLoved: Bool = false,
        wantToListen: Bool = false
    ) {
        self.hasListened = hasListened
        self.defaultRating = defaultRating
        self.isLoved = isLoved
        self.wantToListen = wantToListen
    }

    init(state: RemoteTrackSubjectState?) {
        self.init(
            hasListened: state?.hasListened ?? false,
            defaultRating: state?.defaultRating,
            isLoved: state?.isLoved ?? false,
            wantToListen: state?.wantToListen ?? false
        )
    }

    /// Mirrors `set_my_track_subject_state`: a rating establishes Listened,
    /// and Listened supersedes Want to listen. Loved remains independent.
    var normalizedForSubmission: TrackSubjectStateDraft {
        var result = self
        if result.defaultRating != nil { result.hasListened = true }
        if result.hasListened { result.wantToListen = false }
        return result
    }

    var hasValidRating: Bool {
        guard let defaultRating else { return true }
        guard (0.5...5).contains(defaultRating) else { return false }
        return (defaultRating * 2).rounded() == defaultRating * 2
    }

    var isEmpty: Bool {
        let normalized = normalizedForSubmission
        return !normalized.hasListened
            && normalized.defaultRating == nil
            && !normalized.isLoved
            && !normalized.wantToListen
    }
}

/// Editable owner state for one canonical album release. Album state mirrors
/// track state, but remains a separate opinion: changing an album rating never
/// rewrites a song rating, a historical Diary entry, or an authored review.
struct AlbumSubjectStateDraft: Equatable {
    var hasListened: Bool
    var defaultRating: Double?
    var isLoved: Bool
    var wantToListen: Bool

    static let empty = AlbumSubjectStateDraft()

    init(
        hasListened: Bool = false,
        defaultRating: Double? = nil,
        isLoved: Bool = false,
        wantToListen: Bool = false
    ) {
        self.hasListened = hasListened
        self.defaultRating = defaultRating
        self.isLoved = isLoved
        self.wantToListen = wantToListen
    }

    init(state: RemoteAlbumSubjectState?) {
        self.init(
            hasListened: state?.hasListened ?? false,
            defaultRating: state?.defaultRating,
            isLoved: state?.isLoved ?? false,
            wantToListen: state?.wantToListen ?? false
        )
    }

    var normalizedForSubmission: AlbumSubjectStateDraft {
        var result = self
        if result.defaultRating != nil { result.hasListened = true }
        if result.hasListened { result.wantToListen = false }
        return result
    }

    var hasValidRating: Bool {
        guard let defaultRating else { return true }
        guard (0.5...5).contains(defaultRating) else { return false }
        return (defaultRating * 2).rounded() == defaultRating * 2
    }

    var isEmpty: Bool {
        let normalized = normalizedForSubmission
        return !normalized.hasListened
            && normalized.defaultRating == nil
            && !normalized.isLoved
            && !normalized.wantToListen
    }
}

struct MusicListDraftEntry: Identifiable, Equatable {
    let id: UUID
    var track: HarmonyTrack
    var note: String

    init(id: UUID = UUID(), track: HarmonyTrack, note: String = "") {
        self.id = id
        self.track = track
        self.note = note
    }
}

/// A failure-safe snapshot for the complete list editor. The store never
/// mutates its persisted list cache from this value until the backend accepts
/// the corresponding operation.
struct MusicListDraft: Equatable {
    var title = ""
    var description = ""
    var tagsText = ""
    var isRanked = false
    var visibility: SocialVisibilityOption = .privateOnly
    var entries: [MusicListDraftEntry] = []

    var normalizedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedDescription: String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedTags: [String] {
        var seen = Set<String>()
        return tagsText.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    var validationMessage: String? {
        if !(1...120).contains(normalizedTitle.count) {
            return "List titles must contain 1 to 120 characters."
        }
        if normalizedDescription.count > 5_000 {
            return "List descriptions must be 5,000 characters or fewer."
        }
        if normalizedTags.count > 10 {
            return "Use no more than 10 list tags."
        }
        if normalizedTags.contains(where: { $0.count > 30 }) {
            return "Each list tag must be 30 characters or fewer."
        }
        if entries.count > 1_000 {
            return "Lists can contain no more than 1,000 songs."
        }
        if entries.contains(where: { $0.note.trimmingCharacters(in: .whitespacesAndNewlines).count > 1_000 }) {
            return "List notes must be 1,000 characters or fewer."
        }
        return nil
    }

    mutating func addTrack(_ track: HarmonyTrack) -> Bool {
        guard entries.count < 1_000,
              !entries.contains(where: { Self.sameRecording($0.track, track) }) else { return false }
        entries.append(MusicListDraftEntry(track: track))
        return true
    }

    mutating func moveEntries(fromOffsets: IndexSet, toOffset: Int) {
        entries.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    private static func sameRecording(_ lhs: HarmonyTrack, _ rhs: HarmonyTrack) -> Bool {
        if let leftID = lhs.canonicalTrackID, let rightID = rhs.canonicalTrackID {
            return leftID == rightID
        }
        let leftMappings = Set(lhs.mappings.map { "\($0.provider.rawValue):\($0.storefront):\($0.providerID)" })
        let rightMappings = Set(rhs.mappings.map { "\($0.provider.rawValue):\($0.storefront):\($0.providerID)" })
        return !leftMappings.isDisjoint(with: rightMappings)
    }
}

enum TrackSubjectStateStatus: String, Equatable {
    case listened = "Listened"
    case loved = "Loved"
    case wantToListen = "Want to listen"
    case rated = "Rated"
}

extension TrackSubjectStateDraft {
    /// Stable display order shared by the detail page and accessibility copy.
    var activeStatuses: [TrackSubjectStateStatus] {
        let normalized = normalizedForSubmission
        var statuses: [TrackSubjectStateStatus] = []
        if normalized.hasListened { statuses.append(.listened) }
        if normalized.isLoved { statuses.append(.loved) }
        if normalized.wantToListen { statuses.append(.wantToListen) }
        if normalized.defaultRating != nil { statuses.append(.rated) }
        return statuses
    }
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
    case musicShelf
}

func reviewCommentCanBeDeleted(
    commentAuthorID: UUID,
    reviewOwnerID: UUID,
    viewerID: UUID?
) -> Bool {
    guard let viewerID else { return false }
    return viewerID == commentAuthorID || viewerID == reviewOwnerID
}

func reviewContentIsValid(rating: Double?, body: String) -> Bool {
    rating != nil || !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

struct PaginatedShelfState<Item> {
    var items: [Item] = []
    var isRefreshing = false
    var isLoadingMore = false
    var hasMore = false
}

struct PublicProfileShelfState {
    var reviews = PaginatedShelfState<RemoteMusicReview>()
    var diary = PaginatedShelfState<RemoteListeningHistoryEntry>()
    var loved = PaginatedShelfState<RemotePublicLovedTrack>()
    var lists = PaginatedShelfState<RemoteMusicList>()
}

struct MusicListDetailState {
    var list: RemoteMusicList?
    var entries = PaginatedShelfState<RemoteMusicListEntry>()
    var comments = PaginatedShelfState<RemoteMusicListComment>()
    var engagement: RemoteMusicListEngagement?
    var isRefreshing = false
}

struct ReviewDetailEngagementState {
    var comments = PaginatedShelfState<RemoteReviewComment>()
    var engagement: RemoteReviewEngagement?
    var isRefreshing = false
}

func mergedRefreshedSocialNotifications(
    newestWindow: [RemoteSocialNotification],
    previouslyLoaded: [RemoteSocialNotification]
) -> [RemoteSocialNotification] {
    let refreshedIDs = Set(newestWindow.map(\.id))
    return (newestWindow + previouslyLoaded.filter { !refreshedIDs.contains($0.id) })
        .sorted { left, right in
            if left.createdAt == right.createdAt {
                return left.id.uuidString > right.id.uuidString
            }
            return left.createdAt > right.createdAt
        }
}

struct CanonicalAlbumDetailState {
    var album: RemoteCanonicalAlbum?
    var ownerState: RemoteAlbumSubjectState?
    var reviews = PaginatedShelfState<RemoteMusicReview>()
    var aggregate: RemoteCanonicalAlbumStateAggregate?
    var ratingDistribution: [RemoteCanonicalAlbumRatingBucket] = []
    var isRefreshing = false
    var errorMessage: String?
}

struct EavesdropProviderDestination: Equatable {
    let provider: MusicProvider
    let providerTrackID: String
    let deepLink: URL?
    let availability: ProviderAvailability
}

struct EavesdropBroadcast: Identifiable {
    let id: UUID
    let hostProfileID: UUID
    let hostDisplayName: String
    let status: String
    let visibility: SocialVisibilityOption
    let canonicalTrackID: UUID?
    let title: String?
    let artist: String?
    let album: String?
    let durationMilliseconds: Int?
    let artworkURL: URL?
    let isExplicit: Bool
    let startedAt: Date
    let expiresAt: Date
    let endedAt: Date?
    let endedReason: String?
    let sourceProvider: String?
    let sourceDeepLink: URL?
    var destinations: [MusicProvider: EavesdropProviderDestination]

    var isActive: Bool {
        endedAt == nil && expiresAt > Date()
    }

    var harmonyTrack: HarmonyTrack? {
        guard let title, let artist else { return nil }
        return HarmonyTrack(
            canonicalTrackID: canonicalTrackID,
            title: title,
            artist: artist,
            album: album ?? "Unknown album",
            duration: TimeInterval(durationMilliseconds ?? 0) / 1000,
            symbol: "music.note",
            artworkURL: artworkURL,
            isExplicit: isExplicit,
            mappings: destinations.values.map {
                ProviderTrackMapping(
                    provider: $0.provider,
                    providerID: $0.providerTrackID,
                    availability: $0.availability,
                    deepLinkURL: $0.deepLink
                )
            }
        )
    }
}

struct EavesdropBroadcastDetailState {
    var broadcast: EavesdropBroadcast?
    var comments: [RemoteEavesdropComment] = []
    var reactions: [RemoteEavesdropReaction] = []
    var isRefreshing = false
    var errorMessage: String?
}

func mergedSocialProfileDiscovery(
    existing: [RemoteSocialProfile],
    incoming: [RemoteSocialProfile]
) -> [RemoteSocialProfile] {
    var seen = Set(existing.map(\.id))
    return existing + incoming.filter { seen.insert($0.id).inserted }
}

struct TrackReviewDiaryRequest: Equatable {
    let listenedAt: Date
    let isRelisten: Bool
    let tags: [String]
    let rating: Double?
    let visibility: SocialVisibilityOption
}

func mergedEavesdropBroadcasts(_ rows: [RemoteEavesdropBroadcastRow]) -> [EavesdropBroadcast] {
    var broadcasts: [UUID: EavesdropBroadcast] = [:]
    for row in rows {
        var broadcast = broadcasts[row.broadcastID] ?? EavesdropBroadcast(
            id: row.broadcastID,
            hostProfileID: row.hostProfileID,
            hostDisplayName: row.hostDisplayName,
            status: row.status,
            visibility: row.visibility,
            canonicalTrackID: row.canonicalTrackID,
            title: row.trackTitle,
            artist: row.trackArtist,
            album: row.trackAlbum,
            durationMilliseconds: row.trackDurationMilliseconds,
            artworkURL: row.trackArtworkURL,
            isExplicit: row.trackIsExplicit ?? false,
            startedAt: row.startedAt,
            expiresAt: row.expiresAt,
            endedAt: row.effectiveEndedAt ?? row.endedAt,
            endedReason: row.endedReason,
            sourceProvider: row.sourceProvider,
            sourceDeepLink: row.sourceDeepLink,
            destinations: [:]
        )
        if let providerName = row.viewerProvider,
           let providerID = row.viewerProviderTrackID,
           let provider = providerName == "spotify"
            ? MusicProvider.spotify
            : (providerName == "apple_music" ? MusicProvider.appleMusic : nil) {
            let availability: ProviderAvailability = row.viewerAvailability == "playable"
                ? .playable
                : (row.viewerAvailability == "open_in_provider" ? .openInProvider : .unavailable)
            broadcast.destinations[provider] = EavesdropProviderDestination(
                provider: provider,
                providerTrackID: providerID,
                deepLink: row.viewerProviderDeepLink,
                availability: availability
            )
        }
        broadcasts[row.broadcastID] = broadcast
    }
    return broadcasts.values.sorted {
        if $0.startedAt == $1.startedAt { return $0.id.uuidString > $1.id.uuidString }
        return $0.startedAt > $1.startedAt
    }
}

enum CatalogSearchPurpose: Hashable {
    case addMusic
    case reviews
    case lists
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
    @Published private(set) var eavesdropFeed: [EavesdropBroadcast] = []
    @Published private(set) var eavesdropDetails: [UUID: EavesdropBroadcastDetailState] = [:]
    @Published private(set) var mutatingEavesdropBroadcastIDs: Set<UUID> = []
    @Published private(set) var isRefreshingListeningFeed = false
    @Published private(set) var isPublishingListeningPresence = false
    @Published private(set) var isEavesdropping = false
    @Published private(set) var listeningHistory: [RemoteListeningHistoryEntry] = []
    @Published private(set) var isRefreshingListeningHistory = false
    @Published private(set) var journalEntries: [RemoteListeningHistoryEntry] = []
    @Published private(set) var isRefreshingJournalEntries = false
    @Published private(set) var isLoadingMoreJournalEntries = false
    @Published private(set) var hasMoreJournalEntries = false
    @Published private(set) var isRecordingListeningHistory = false
    @Published private(set) var isSavingDiaryEntry = false
    @Published private(set) var trackSubjectStates: [UUID: RemoteTrackSubjectState] = [:]
    @Published private(set) var trackSubjectShelf: [RemoteTrackSubjectState] = []
    @Published private(set) var isRefreshingTrackSubjectShelf = false
    @Published private(set) var isLoadingMoreTrackSubjectShelf = false
    @Published private(set) var hasMoreTrackSubjectShelf = false
    @Published private(set) var mutatingTrackSubjectStateIDs: Set<UUID> = []
    @Published private(set) var albumSubjectStates: [UUID: RemoteAlbumSubjectState] = [:]
    @Published private(set) var albumSubjectShelf: [RemoteAlbumSubjectState] = []
    @Published private(set) var isRefreshingAlbumSubjectShelf = false
    @Published private(set) var isLoadingMoreAlbumSubjectShelf = false
    @Published private(set) var hasMoreAlbumSubjectShelf = false
    @Published private(set) var mutatingAlbumSubjectStateIDs: Set<UUID> = []
    @Published private(set) var canonicalAlbumDetails: [UUID: CanonicalAlbumDetailState] = [:]
    @Published private(set) var isImportingSpotifyHistory = false
    @Published private(set) var spotifyHistoryImportMessage: String?
    @Published private(set) var musicReviews: [RemoteMusicReview] = []
    @Published private(set) var ownerReviews: [RemoteMusicReview] = []
    @Published private(set) var reviewDetailsByID: [UUID: RemoteMusicReview] = [:]
    @Published private(set) var reviewEngagementDetails: [UUID: ReviewDetailEngagementState] = [:]
    @Published private(set) var ownerReviewStats: RemoteOwnerReviewStats = .empty
    @Published private(set) var isRefreshingMusicReviews = false
    @Published private(set) var isRefreshingOwnerReviews = false
    @Published private(set) var isLoadingMoreOwnerReviews = false
    @Published private(set) var hasMoreOwnerReviews = false
    @Published private(set) var isPublishingMusicReview = false
    @Published private(set) var mutatingReviewIDs: Set<UUID> = []
    @Published private(set) var followingActivity: [RemoteFollowingActivityItem] = []
    @Published private(set) var isRefreshingFollowingActivity = false
    @Published private(set) var isLoadingMoreFollowingActivity = false
    @Published private(set) var hasMoreFollowingActivity = false
    @Published private(set) var publicProfileShelves: [UUID: PublicProfileShelfState] = [:]
    @Published private(set) var ownerMusicLists: [RemoteMusicList] = []
    @Published private(set) var isRefreshingOwnerMusicLists = false
    @Published private(set) var isLoadingMoreOwnerMusicLists = false
    @Published private(set) var hasMoreOwnerMusicLists = false
    @Published private(set) var musicListDetails: [UUID: MusicListDetailState] = [:]
    /// Missing keys are deliberately unknown until detail engagement loads.
    @Published private(set) var musicListLikeStates: [UUID: Bool] = [:]
    @Published private(set) var isCreatingMusicList = false
    @Published private(set) var mutatingMusicListIDs: Set<UUID> = []
    @Published private(set) var mutatingMusicListEntryIDs: Set<UUID> = []
    @Published private(set) var likingMusicListIDs: Set<UUID> = []
    @Published private(set) var commentingMusicListIDs: Set<UUID> = []
    @Published private(set) var deletingMusicListCommentIDs: Set<UUID> = []
    @Published private(set) var socialProfiles: [RemoteSocialProfile] = []
    @Published private(set) var blockedSocialProfiles: [RemoteSocialProfile] = []
    @Published private(set) var discoveredSocialProfiles: [RemoteSocialProfile] = []
    @Published private(set) var socialDiscoveryQuery = ""
    @Published private(set) var isRefreshingSocialDiscovery = false
    @Published private(set) var isLoadingMoreSocialDiscovery = false
    @Published private(set) var hasMoreSocialDiscovery = false
    @Published private(set) var socialNotifications: [RemoteSocialNotification] = []
    @Published private(set) var unreadSocialNotificationCount = 0
    @Published private(set) var isRefreshingSocialNotifications = false
    @Published private(set) var isLoadingMoreSocialNotifications = false
    @Published private(set) var hasMoreSocialNotifications = false
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
    private let journalPageSize = 50
    private let trackSubjectShelfPageSize = 50
    private let albumSubjectShelfPageSize = 50
    private let socialShelfPageSize = 50
    private let socialNotificationPageSize = 50
    private let socialDiscoveryPageSize = 50
    private let musicListPageSize = 50
    private let musicListEntryPageSize = 100
    private var followingActivityCursor: RemoteFollowingActivityCursor?
    private var socialNotificationCursor: RemoteSocialNotificationCursor?
    private var socialDiscoveryCursor: RemoteSocialProfileCursor?
    private var socialDiscoveryRequestID: UUID?
#if DEBUG
    private var isDiaryEditorUITestFixtureActive = false
    private var socialDiscoveryFixtureProfiles: [RemoteSocialProfile] = []
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
    var shelfSocialVisibility: SocialVisibilityOption { socialSettings?.shelfVisibility ?? .privateOnly }
    var recordsHarmonyPlays: Bool { socialSettings?.recordHarmonyPlays ?? false }
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
            shelfVisibility: category == .musicShelf ? visibility : current.shelfVisibility,
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
            shelfVisibility: current.shelfVisibility,
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
            for purpose in [CatalogSearchPurpose.addMusic, .reviews, .lists] {
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
            var rows = try await collaborationRepository.eavesdropBroadcastRows()
            if providerState(for: .spotify) == .connected {
                rows += (try? await collaborationRepository.eavesdropBroadcastRows(
                    viewerProvider: .spotify,
                    storefront: "global"
                )) ?? []
            }
            if providerState(for: .appleMusic) == .connected {
                rows += (try? await collaborationRepository.eavesdropBroadcastRows(
                    viewerProvider: .appleMusic,
                    storefront: "us"
                )) ?? []
            }
            let userID = try await collaborationRepository.currentUserID()
            eavesdropFeed = mergedEavesdropBroadcasts(rows)
            isEavesdropping = eavesdropFeed.contains { $0.hostProfileID == userID }
        } catch {
            collaborationMessage = "Could not refresh listening activity."
        }
    }

    func refreshEavesdropDetail(_ broadcast: EavesdropBroadcast) async {
#if DEBUG
        if isDiaryEditorUITestFixtureActive { return }
#endif
        guard eavesdropDetails[broadcast.id]?.isRefreshing != true else { return }
        eavesdropDetails[broadcast.id, default: EavesdropBroadcastDetailState()].broadcast = broadcast
        eavesdropDetails[broadcast.id]?.isRefreshing = true
        defer { eavesdropDetails[broadcast.id]?.isRefreshing = false }
        do {
            async let comments = collaborationRepository.eavesdropComments(broadcastID: broadcast.id)
            async let reactions = collaborationRepository.eavesdropReactions(broadcastID: broadcast.id)
            let values = try await (comments, reactions)
            eavesdropDetails[broadcast.id]?.comments = values.0
            eavesdropDetails[broadcast.id]?.reactions = values.1
            eavesdropDetails[broadcast.id]?.errorMessage = nil
        } catch {
            eavesdropDetails[broadcast.id]?.errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func addEavesdropComment(to broadcast: EavesdropBroadcast, body: String) async -> Bool {
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...2000).contains(body.count) else {
            collaborationMessage = "Comments must contain 1 to 2,000 characters."
            return false
        }
        return await performEavesdropMutation(broadcast, success: "Comment added") {
            try await self.collaborationRepository.addEavesdropComment(
                broadcastID: broadcast.id,
                body: body
            )
        }
    }

    func toggleEavesdropReaction(_ broadcast: EavesdropBroadcast, kind: String) async {
        _ = await performEavesdropMutation(broadcast, success: "Reaction updated") {
            _ = try await self.collaborationRepository.toggleEavesdropReaction(
                broadcastID: broadcast.id,
                kind: kind
            )
        }
    }

    func deleteEavesdropComment(_ comment: RemoteEavesdropComment, from broadcast: EavesdropBroadcast) async {
        _ = await performEavesdropMutation(broadcast, success: "Comment deleted") {
            _ = try await self.collaborationRepository.deleteEavesdropComment(comment.id)
        }
    }

    func canDeleteEavesdropComment(_ comment: RemoteEavesdropComment, broadcast: EavesdropBroadcast) -> Bool {
        broadcast.isActive && (
            comment.authorID == authenticatedProfileID || broadcast.hostProfileID == authenticatedProfileID
        )
    }

    func hasEavesdropReaction(_ broadcastID: UUID, kind: String) -> Bool {
        guard let authenticatedProfileID else { return false }
        return eavesdropDetails[broadcastID]?.reactions.contains {
            $0.profileID == authenticatedProfileID && $0.kind == kind
        } ?? false
    }

    func startEavesdropPlayback(_ broadcast: EavesdropBroadcast, provider: MusicProvider) async -> Bool {
        guard broadcast.isActive,
              !mutatingEavesdropBroadcastIDs.contains(broadcast.id),
              let track = broadcast.harmonyTrack,
              broadcast.destinations[provider] != nil else { return false }
        mutatingEavesdropBroadcastIDs.insert(broadcast.id)
        defer { mutatingEavesdropBroadcastIDs.remove(broadcast.id) }
        do {
            let adapter: any HarmonyMusicProvider = provider == .spotify ? spotifyRemote : appleMusicProvider
            let resolved = try await adapter.resolve(track: track)
            let result = try await adapter.perform(.play(resolved))
            switch result {
            case .applied:
                collaborationMessage = "Started in \(provider.name)"
                return true
            case .requiresOpenInProvider:
                collaborationMessage = "Open \(provider.name) to listen to this track."
                return false
            case .unavailable(let reason):
                collaborationMessage = reason
                return false
            }
        } catch {
            collaborationMessage = "Could not start \(provider.name): \(error.localizedDescription)"
            return false
        }
    }

    private func performEavesdropMutation(
        _ broadcast: EavesdropBroadcast,
        success: String,
        operation: @escaping () async throws -> Void
    ) async -> Bool {
        guard broadcast.isActive,
              !mutatingEavesdropBroadcastIDs.contains(broadcast.id) else { return false }
        mutatingEavesdropBroadcastIDs.insert(broadcast.id)
        defer { mutatingEavesdropBroadcastIDs.remove(broadcast.id) }
        do {
            try await operation()
            collaborationMessage = success
            await refreshEavesdropDetail(broadcast)
            return true
        } catch {
            collaborationMessage = "Could not update eavesdrop: \(error.localizedDescription)"
            return false
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
            async let journal: Void = self.refreshJournalEntries()
            async let reviews: Void = self.refreshMusicReviews()
            async let reviewDetails: Void = self.refreshCachedReviewDetails()
            async let eavesdropDetails: Void = self.refreshCachedEavesdropDetails()
            async let notifications: Void = self.refreshSocialNotifications(preservingLoadedPages: true)
            async let followingActivity: Void = self.refreshFollowingActivity()
            _ = await (
                profiles,
                feed,
                history,
                journal,
                reviews,
                reviewDetails,
                eavesdropDetails,
                notifications,
                followingActivity
            )
        }
    }

    /// Realtime observes live-listening child rows and profile blocks. Refresh
    /// already-open details through their RLS-filtered queries so remote
    /// comments/reactions appear and newly blocked child authors disappear
    /// without requiring the listener to leave and reopen the screen.
    private func refreshCachedEavesdropDetails() async {
        let broadcasts = eavesdropDetails.values.compactMap(\.broadcast)
        for broadcast in broadcasts {
            await refreshEavesdropDetail(broadcast)
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

    func refreshJournalEntries() async {
#if DEBUG
        guard !isDiaryEditorUITestFixtureActive else { return }
#endif
        guard !isRefreshingJournalEntries, !isLoadingMoreJournalEntries else { return }
        isRefreshingJournalEntries = true
        defer { isRefreshingJournalEntries = false }
        do {
            let page = try await collaborationRepository.listeningDiaryPage(limit: journalPageSize + 1)
            journalEntries = Array(page.prefix(journalPageSize))
            hasMoreJournalEntries = page.count > journalPageSize
        } catch {
            collaborationMessage = "Could not refresh your journal."
        }
    }

    func loadMoreJournalEntries() async {
        guard hasMoreJournalEntries,
              !isRefreshingJournalEntries,
              !isLoadingMoreJournalEntries,
              let cursor = journalEntries.last else { return }
        isLoadingMoreJournalEntries = true
        defer { isLoadingMoreJournalEntries = false }
        do {
            let page = try await collaborationRepository.listeningDiaryPage(
                beforePlayedAt: cursor.playedAt,
                beforeID: cursor.id,
                limit: journalPageSize + 1
            )
            let visiblePage = page.prefix(journalPageSize)
            let existingIDs = Set(journalEntries.map(\.id))
            journalEntries.append(contentsOf: visiblePage.filter { !existingIDs.contains($0.id) })
            hasMoreJournalEntries = page.count > journalPageSize
        } catch {
            collaborationMessage = "Could not load older journal entries."
        }
    }

    func recordCurrentTrackInHistory() async {
        guard let track = nowPlaying?.track else {
            collaborationMessage = "Start a Harmony queue track before logging it."
            return
        }
        await recordListeningHistory(track)
    }

    func quickLogCurrentTrackToJournal() async {
        guard let track = nowPlaying?.track else {
            collaborationMessage = "Start a Harmony queue track before logging it."
            return
        }
        _ = await createDiaryEntry(
            track: track,
            listenedOn: Date(),
            isRelisten: false,
            tags: [],
            visibility: historySocialVisibility
        )
    }

    @discardableResult
    func createDiaryEntry(
        track: HarmonyTrack,
        listenedOn: Date,
        isRelisten: Bool,
        tags: [String],
        rating: Double? = nil,
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
                visibility: visibility,
                rating: rating
            )
            collaborationMessage = visibility == .followers
                ? "Listen added to your follower-visible journal"
                : "Private journal entry saved"
            await refreshListeningHistory()
            await refreshJournalEntries()
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
        rating: Double? = nil,
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
                reviewID: reviewID,
                rating: rating
            )
            collaborationMessage = "Journal entry updated"
            await refreshListeningHistory()
            await refreshJournalEntries()
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

    func trackSubjectState(for track: RemoteCatalogTrack) -> RemoteTrackSubjectState? {
        guard let id = track.id else { return nil }
        return trackSubjectStates[id]
            ?? trackSubjectShelf.first { $0.canonicalTrackID == id }
    }

    func trackSubjectStateDraft(for track: RemoteCatalogTrack) -> TrackSubjectStateDraft {
        TrackSubjectStateDraft(state: trackSubjectState(for: track))
    }

    func isSavingTrackSubjectState(for track: RemoteCatalogTrack) -> Bool {
        track.id.map(mutatingTrackSubjectStateIDs.contains) ?? false
    }

    @discardableResult
    func refreshTrackSubjectState(for track: RemoteCatalogTrack) async -> RemoteTrackSubjectState? {
        guard let canonicalTrackID = track.id else {
            collaborationMessage = "Could not identify this track."
            return nil
        }
#if DEBUG
        if isDiaryEditorUITestFixtureActive {
            return trackSubjectState(for: track)
        }
#endif
        do {
            let state = try await collaborationRepository.trackSubjectState(
                canonicalTrackID: canonicalTrackID
            )
            if let state {
                cacheTrackSubjectState(state, fallbackTrack: track)
            } else {
                removeTrackSubjectState(canonicalTrackID: canonicalTrackID)
            }
            return state
        } catch {
            collaborationMessage = "Could not load your track status: \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func refreshTrackSubjectState(for track: HarmonyTrack) async -> RemoteTrackSubjectState? {
        do {
            let state = try await collaborationRepository.trackSubjectState(for: track)
            if let state {
                trackSubjectStates[state.canonicalTrackID] = state
                replaceTrackSubjectShelfState(state)
            }
            return state
        } catch {
            collaborationMessage = "Could not load your track status: \(error.localizedDescription)"
            return nil
        }
    }

    func refreshTrackSubjectShelf() async {
#if DEBUG
        guard !isDiaryEditorUITestFixtureActive else { return }
#endif
        guard !isRefreshingTrackSubjectShelf, !isLoadingMoreTrackSubjectShelf else { return }
        isRefreshingTrackSubjectShelf = true
        defer { isRefreshingTrackSubjectShelf = false }
        do {
            let page = try await collaborationRepository.trackSubjectStatePage(
                limit: trackSubjectShelfPageSize + 1
            )
            trackSubjectShelf = Array(page.prefix(trackSubjectShelfPageSize))
            hasMoreTrackSubjectShelf = page.count > trackSubjectShelfPageSize
            cacheTrackSubjectStates(trackSubjectShelf)
        } catch {
            collaborationMessage = "Could not refresh your music shelf."
        }
    }

    func loadMoreTrackSubjectShelf() async {
#if DEBUG
        guard !isDiaryEditorUITestFixtureActive else { return }
#endif
        guard hasMoreTrackSubjectShelf,
              !isRefreshingTrackSubjectShelf,
              !isLoadingMoreTrackSubjectShelf,
              let cursor = trackSubjectShelf.last else { return }
        isLoadingMoreTrackSubjectShelf = true
        defer { isLoadingMoreTrackSubjectShelf = false }
        do {
            let page = try await collaborationRepository.trackSubjectStatePage(
                beforeUpdatedAt: cursor.updatedAt,
                beforeCanonicalTrackID: cursor.canonicalTrackID,
                limit: trackSubjectShelfPageSize + 1
            )
            let existingIDs = Set(trackSubjectShelf.map(\.canonicalTrackID))
            let visiblePage = page.prefix(trackSubjectShelfPageSize)
                .filter { !existingIDs.contains($0.canonicalTrackID) }
            trackSubjectShelf.append(contentsOf: visiblePage)
            hasMoreTrackSubjectShelf = page.count > trackSubjectShelfPageSize
            cacheTrackSubjectStates(visiblePage)
        } catch {
            collaborationMessage = "Could not load more of your music shelf."
        }
    }

    @discardableResult
    func updateTrackSubjectState(
        for track: HarmonyTrack,
        hasListened: Bool,
        defaultRating: Double?,
        isLoved: Bool,
        wantToListen: Bool
    ) async -> Bool {
        let draft = TrackSubjectStateDraft(
            hasListened: hasListened,
            defaultRating: defaultRating,
            isLoved: isLoved,
            wantToListen: wantToListen
        ).normalizedForSubmission
        guard draft.hasValidRating else {
            collaborationMessage = "Ratings must use half-star steps from 0.5 to 5.0."
            return false
        }
        guard !mutatingTrackSubjectStateIDs.contains(track.id) else { return false }
        mutatingTrackSubjectStateIDs.insert(track.id)
        defer { mutatingTrackSubjectStateIDs.remove(track.id) }
        do {
            let state = try await collaborationRepository.updateTrackSubjectState(
                for: track,
                hasListened: draft.hasListened,
                defaultRating: draft.defaultRating,
                isLoved: draft.isLoved,
                wantToListen: draft.wantToListen
            )
            let shelfTrack = trackSubjectShelf.first {
                $0.canonicalTrackID == state.canonicalTrackID
            }?.canonicalTrack
            let mergedState = state.preservingCanonicalTrack(shelfTrack)
            applySavedTrackSubjectState(mergedState, submittedDraft: draft)
            collaborationMessage = "Track status updated"
            return true
        } catch {
            collaborationMessage = "Could not update track status: \(error.localizedDescription)"
            return false
        }
    }

    /// Saves the complete draft atomically. The cache changes only after a
    /// successful response, so a failed save leaves both the persisted state
    /// and the caller's value-typed draft available for retry.
    @discardableResult
    func saveTrackSubjectStateDraft(
        _ proposedDraft: TrackSubjectStateDraft,
        for track: RemoteCatalogTrack
    ) async -> Bool {
        guard let canonicalTrackID = track.id else {
            collaborationMessage = "Could not identify this track."
            return false
        }
        let draft = proposedDraft.normalizedForSubmission
        guard draft.hasValidRating else {
            collaborationMessage = "Ratings must use half-star steps from 0.5 to 5.0."
            return false
        }
        guard !mutatingTrackSubjectStateIDs.contains(canonicalTrackID) else { return false }
        mutatingTrackSubjectStateIDs.insert(canonicalTrackID)
        defer { mutatingTrackSubjectStateIDs.remove(canonicalTrackID) }

#if DEBUG
        if isDiaryEditorUITestFixtureActive {
            await Task.yield()
            let now = Date()
            let current = trackSubjectState(for: track)
            let state = RemoteTrackSubjectState(
                profileID: authenticatedProfileID ?? UUID(),
                canonicalTrackID: canonicalTrackID,
                hasListened: draft.hasListened,
                defaultRating: draft.defaultRating,
                isLoved: draft.isLoved,
                wantToListen: draft.wantToListen,
                createdAt: current?.createdAt ?? now,
                updatedAt: now,
                canonicalTrack: track
            )
            applySavedTrackSubjectState(state, submittedDraft: draft)
            collaborationMessage = "Track status updated"
            return true
        }
#endif

        do {
            let state = try await collaborationRepository.updateTrackSubjectState(
                canonicalTrackID: canonicalTrackID,
                draft: draft
            )
            cacheTrackSubjectState(state, fallbackTrack: track, submittedDraft: draft)
            collaborationMessage = "Track status updated"
            return true
        } catch {
            collaborationMessage = "Could not update track status: \(error.localizedDescription)"
            return false
        }
    }

    private func cacheTrackSubjectStates<S: Sequence>(_ states: S)
    where S.Element == RemoteTrackSubjectState {
        for state in states { trackSubjectStates[state.canonicalTrackID] = state }
    }

    private func replaceTrackSubjectShelfState(_ state: RemoteTrackSubjectState) {
        guard let index = trackSubjectShelf.firstIndex(where: {
            $0.canonicalTrackID == state.canonicalTrackID
        }) else { return }
        trackSubjectShelf[index] = state.preservingCanonicalTrack(
            trackSubjectShelf[index].canonicalTrack
        )
    }

    private func cacheTrackSubjectState(
        _ state: RemoteTrackSubjectState,
        fallbackTrack: RemoteCatalogTrack,
        submittedDraft: TrackSubjectStateDraft? = nil
    ) {
        applySavedTrackSubjectState(
            state.preservingCanonicalTrack(fallbackTrack),
            submittedDraft: submittedDraft ?? TrackSubjectStateDraft(state: state)
        )
    }

    private func applySavedTrackSubjectState(
        _ state: RemoteTrackSubjectState,
        submittedDraft: TrackSubjectStateDraft
    ) {
        if submittedDraft.isEmpty {
            removeTrackSubjectState(canonicalTrackID: state.canonicalTrackID)
            return
        }
        trackSubjectStates[state.canonicalTrackID] = state
        trackSubjectShelf.removeAll { $0.canonicalTrackID == state.canonicalTrackID }
        trackSubjectShelf.insert(state, at: 0)
    }

    private func removeTrackSubjectState(canonicalTrackID: UUID) {
        trackSubjectStates.removeValue(forKey: canonicalTrackID)
        trackSubjectShelf.removeAll { $0.canonicalTrackID == canonicalTrackID }
    }

    func albumSubjectState(for album: RemoteCanonicalAlbum) -> RemoteAlbumSubjectState? {
        albumSubjectStates[album.id]
            ?? albumSubjectShelf.first { $0.canonicalAlbumID == album.id }
            ?? canonicalAlbumDetails[album.id]?.ownerState
    }

    func resolveCanonicalAlbum(_ album: ReviewableAlbum) async -> RemoteCanonicalAlbum? {
        do {
            return try await collaborationRepository.resolveCanonicalAlbum(album)
        } catch {
            collaborationMessage = "Could not open this album: \(error.localizedDescription)"
            return nil
        }
    }

    func albumSubjectStateDraft(for album: RemoteCanonicalAlbum) -> AlbumSubjectStateDraft {
        AlbumSubjectStateDraft(state: albumSubjectState(for: album))
    }

    func isSavingAlbumSubjectState(for albumID: UUID) -> Bool {
        mutatingAlbumSubjectStateIDs.contains(albumID)
    }

    @discardableResult
    func refreshAlbumSubjectState(for album: RemoteCanonicalAlbum) async -> RemoteAlbumSubjectState? {
        do {
            let state = try await collaborationRepository.albumSubjectState(canonicalAlbumID: album.id)
            if let state {
                let merged = state.preservingCanonicalAlbum(album)
                albumSubjectStates[album.id] = merged
                canonicalAlbumDetails[album.id, default: CanonicalAlbumDetailState()].ownerState = merged
                replaceAlbumSubjectShelfState(merged)
            } else {
                removeAlbumSubjectState(canonicalAlbumID: album.id)
            }
            return state
        } catch {
            collaborationMessage = "Could not load your album status: \(error.localizedDescription)"
            return nil
        }
    }

    func refreshAlbumSubjectShelf() async {
#if DEBUG
        if isDiaryEditorUITestFixtureActive { return }
#endif
        guard !isRefreshingAlbumSubjectShelf, !isLoadingMoreAlbumSubjectShelf else { return }
        isRefreshingAlbumSubjectShelf = true
        defer { isRefreshingAlbumSubjectShelf = false }
        do {
            let page = try await collaborationRepository.albumSubjectStatePage(
                limit: albumSubjectShelfPageSize + 1
            )
            albumSubjectShelf = Array(page.prefix(albumSubjectShelfPageSize))
            hasMoreAlbumSubjectShelf = page.count > albumSubjectShelfPageSize
            for state in albumSubjectShelf { albumSubjectStates[state.canonicalAlbumID] = state }
        } catch {
            collaborationMessage = "Could not refresh your album shelf: \(error.localizedDescription)"
        }
    }

    func loadMoreAlbumSubjectShelf() async {
        guard hasMoreAlbumSubjectShelf,
              !isRefreshingAlbumSubjectShelf,
              !isLoadingMoreAlbumSubjectShelf,
              let cursor = albumSubjectShelf.last else { return }
        isLoadingMoreAlbumSubjectShelf = true
        defer { isLoadingMoreAlbumSubjectShelf = false }
        do {
            let page = try await collaborationRepository.albumSubjectStatePage(
                beforeUpdatedAt: cursor.updatedAt,
                beforeCanonicalAlbumID: cursor.canonicalAlbumID,
                limit: albumSubjectShelfPageSize + 1
            )
            let existingIDs = Set(albumSubjectShelf.map(\.canonicalAlbumID))
            let newStates = page.prefix(albumSubjectShelfPageSize)
                .filter { !existingIDs.contains($0.canonicalAlbumID) }
            albumSubjectShelf.append(contentsOf: newStates)
            hasMoreAlbumSubjectShelf = page.count > albumSubjectShelfPageSize
            for state in newStates { albumSubjectStates[state.canonicalAlbumID] = state }
        } catch {
            collaborationMessage = "Could not load more album statuses: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func saveAlbumSubjectStateDraft(
        _ proposedDraft: AlbumSubjectStateDraft,
        for album: RemoteCanonicalAlbum
    ) async -> Bool {
        let draft = proposedDraft.normalizedForSubmission
        guard draft.hasValidRating else {
            collaborationMessage = "Ratings must use half-star steps from 0.5 to 5.0."
            return false
        }
        guard !mutatingAlbumSubjectStateIDs.contains(album.id) else { return false }
        mutatingAlbumSubjectStateIDs.insert(album.id)
        defer { mutatingAlbumSubjectStateIDs.remove(album.id) }
        do {
            let saved = try await collaborationRepository.updateAlbumSubjectState(
                canonicalAlbumID: album.id,
                draft: draft
            ).preservingCanonicalAlbum(album)
            if draft.isEmpty {
                removeAlbumSubjectState(canonicalAlbumID: album.id)
            } else {
                albumSubjectStates[album.id] = saved
                albumSubjectShelf.removeAll { $0.canonicalAlbumID == album.id }
                albumSubjectShelf.insert(saved, at: 0)
                canonicalAlbumDetails[album.id, default: CanonicalAlbumDetailState()].ownerState = saved
            }
            collaborationMessage = "Album status updated"
            return true
        } catch {
            collaborationMessage = "Could not update album status: \(error.localizedDescription)"
            return false
        }
    }

    func refreshCanonicalAlbumDetail(_ album: RemoteCanonicalAlbum) async {
#if DEBUG
        if isDiaryEditorUITestFixtureActive { return }
#endif
        guard canonicalAlbumDetails[album.id]?.isRefreshing != true else { return }
        canonicalAlbumDetails[album.id, default: CanonicalAlbumDetailState()].album = album
        canonicalAlbumDetails[album.id]?.isRefreshing = true
        canonicalAlbumDetails[album.id]?.errorMessage = nil
        defer { canonicalAlbumDetails[album.id]?.isRefreshing = false }
        do {
            async let ownerState = collaborationRepository.albumSubjectState(canonicalAlbumID: album.id)
            async let reviews = collaborationRepository.canonicalAlbumReviews(
                canonicalAlbumID: album.id,
                limit: socialShelfPageSize + 1
            )
            async let aggregate = collaborationRepository.canonicalAlbumStateAggregate(
                canonicalAlbumID: album.id
            )
            async let distribution = collaborationRepository.canonicalAlbumRatingDistribution(
                canonicalAlbumID: album.id
            )
            let values = try await (ownerState, reviews, aggregate, distribution)
            let mergedOwnerState = values.0?.preservingCanonicalAlbum(album)
            canonicalAlbumDetails[album.id]?.ownerState = mergedOwnerState
            canonicalAlbumDetails[album.id]?.reviews.items = Array(values.1.prefix(socialShelfPageSize))
            canonicalAlbumDetails[album.id]?.reviews.hasMore = values.1.count > socialShelfPageSize
            canonicalAlbumDetails[album.id]?.aggregate = values.2
            canonicalAlbumDetails[album.id]?.ratingDistribution = values.3
            if let mergedOwnerState { albumSubjectStates[album.id] = mergedOwnerState }
        } catch {
            canonicalAlbumDetails[album.id]?.errorMessage = error.localizedDescription
        }
    }

    func loadMoreCanonicalAlbumReviews(_ albumID: UUID) async {
        guard var detail = canonicalAlbumDetails[albumID],
              detail.reviews.hasMore,
              !detail.reviews.isLoadingMore,
              let cursor = detail.reviews.items.last else { return }
        canonicalAlbumDetails[albumID]?.reviews.isLoadingMore = true
        defer { canonicalAlbumDetails[albumID]?.reviews.isLoadingMore = false }
        do {
            let page = try await collaborationRepository.canonicalAlbumReviews(
                canonicalAlbumID: albumID,
                beforeCreatedAt: cursor.createdAt,
                beforeID: cursor.id,
                limit: socialShelfPageSize + 1
            )
            let existingIDs = Set(detail.reviews.items.map(\.id))
            detail.reviews.items.append(contentsOf: page.prefix(socialShelfPageSize).filter {
                !existingIDs.contains($0.id)
            })
            detail.reviews.hasMore = page.count > socialShelfPageSize
            detail.reviews.isLoadingMore = false
            canonicalAlbumDetails[albumID] = detail
        } catch {
            canonicalAlbumDetails[albumID]?.errorMessage = error.localizedDescription
        }
    }

    private func replaceAlbumSubjectShelfState(_ state: RemoteAlbumSubjectState) {
        guard let index = albumSubjectShelf.firstIndex(where: {
            $0.canonicalAlbumID == state.canonicalAlbumID
        }) else { return }
        albumSubjectShelf[index] = state.preservingCanonicalAlbum(
            albumSubjectShelf[index].canonicalAlbum
        )
    }

    private func removeAlbumSubjectState(canonicalAlbumID: UUID) {
        albumSubjectStates.removeValue(forKey: canonicalAlbumID)
        albumSubjectShelf.removeAll { $0.canonicalAlbumID == canonicalAlbumID }
        canonicalAlbumDetails[canonicalAlbumID]?.ownerState = nil
    }

    func refreshFollowingActivity() async {
#if DEBUG
        guard !isDiaryEditorUITestFixtureActive else { return }
#endif
        guard !isRefreshingFollowingActivity, !isLoadingMoreFollowingActivity else { return }
        isRefreshingFollowingActivity = true
        defer { isRefreshingFollowingActivity = false }
        do {
            let page = try await collaborationRepository.followingActivityPage(limit: socialShelfPageSize)
            followingActivity = page.items
            followingActivityCursor = page.cursor
            hasMoreFollowingActivity = page.hasMore
        } catch {
            collaborationMessage = "Could not refresh following activity."
        }
    }

    func loadMoreFollowingActivity() async {
        guard hasMoreFollowingActivity,
              !isRefreshingFollowingActivity,
              !isLoadingMoreFollowingActivity,
              let cursor = followingActivityCursor else { return }
        isLoadingMoreFollowingActivity = true
        defer { isLoadingMoreFollowingActivity = false }
        do {
            let page = try await collaborationRepository.followingActivityPage(
                beforePublishedAt: cursor.publishedAt,
                beforeID: cursor.id,
                limit: socialShelfPageSize
            )
            let existingIDs = Set(followingActivity.map(\.id))
            followingActivity.append(contentsOf: page.items.filter { !existingIDs.contains($0.id) })
            followingActivityCursor = page.cursor
            hasMoreFollowingActivity = page.hasMore
        } catch {
            collaborationMessage = "Could not load more following activity."
        }
    }

    func refreshPublicProfileReviews(for profileID: UUID) async {
#if DEBUG
        guard !isDiaryEditorUITestFixtureActive else { return }
#endif
        var shelves = publicProfileShelves[profileID] ?? PublicProfileShelfState()
        guard !shelves.reviews.isRefreshing, !shelves.reviews.isLoadingMore else { return }
        shelves.reviews.isRefreshing = true
        publicProfileShelves[profileID] = shelves
        defer { publicProfileShelves[profileID]?.reviews.isRefreshing = false }
        do {
            let page = try await collaborationRepository.publicProfileReviewsPage(
                profileID: profileID,
                limit: socialShelfPageSize + 1
            )
            publicProfileShelves[profileID]?.reviews.items = Array(page.prefix(socialShelfPageSize))
            publicProfileShelves[profileID]?.reviews.hasMore = page.count > socialShelfPageSize
        } catch {
            collaborationMessage = "Could not load this member's reviews."
        }
    }

    func loadMorePublicProfileReviews(for profileID: UUID) async {
        guard var shelves = publicProfileShelves[profileID],
              shelves.reviews.hasMore,
              !shelves.reviews.isRefreshing,
              !shelves.reviews.isLoadingMore,
              let cursor = shelves.reviews.items.last else { return }
        shelves.reviews.isLoadingMore = true
        publicProfileShelves[profileID] = shelves
        defer { publicProfileShelves[profileID]?.reviews.isLoadingMore = false }
        do {
            let page = try await collaborationRepository.publicProfileReviewsPage(
                profileID: profileID,
                beforeCreatedAt: cursor.createdAt,
                beforeID: cursor.id,
                limit: socialShelfPageSize + 1
            )
            let existingIDs = Set(shelves.reviews.items.map(\.id))
            publicProfileShelves[profileID]?.reviews.items.append(
                contentsOf: page.prefix(socialShelfPageSize).filter { !existingIDs.contains($0.id) }
            )
            publicProfileShelves[profileID]?.reviews.hasMore = page.count > socialShelfPageSize
        } catch {
            collaborationMessage = "Could not load more reviews."
        }
    }

    func refreshPublicProfileDiary(for profileID: UUID) async {
#if DEBUG
        guard !isDiaryEditorUITestFixtureActive else { return }
#endif
        var shelves = publicProfileShelves[profileID] ?? PublicProfileShelfState()
        guard !shelves.diary.isRefreshing, !shelves.diary.isLoadingMore else { return }
        shelves.diary.isRefreshing = true
        publicProfileShelves[profileID] = shelves
        defer { publicProfileShelves[profileID]?.diary.isRefreshing = false }
        do {
            let page = try await collaborationRepository.publicProfileDiaryPage(
                profileID: profileID,
                limit: socialShelfPageSize + 1
            )
            publicProfileShelves[profileID]?.diary.items = Array(page.prefix(socialShelfPageSize))
            publicProfileShelves[profileID]?.diary.hasMore = page.count > socialShelfPageSize
        } catch {
            collaborationMessage = "Could not load this member's diary."
        }
    }

    func loadMorePublicProfileDiary(for profileID: UUID) async {
        guard var shelves = publicProfileShelves[profileID],
              shelves.diary.hasMore,
              !shelves.diary.isRefreshing,
              !shelves.diary.isLoadingMore,
              let cursor = shelves.diary.items.last else { return }
        shelves.diary.isLoadingMore = true
        publicProfileShelves[profileID] = shelves
        defer { publicProfileShelves[profileID]?.diary.isLoadingMore = false }
        do {
            let page = try await collaborationRepository.publicProfileDiaryPage(
                profileID: profileID,
                beforePlayedAt: cursor.playedAt,
                beforeID: cursor.id,
                limit: socialShelfPageSize + 1
            )
            let existingIDs = Set(shelves.diary.items.map(\.id))
            publicProfileShelves[profileID]?.diary.items.append(
                contentsOf: page.prefix(socialShelfPageSize).filter { !existingIDs.contains($0.id) }
            )
            publicProfileShelves[profileID]?.diary.hasMore = page.count > socialShelfPageSize
        } catch {
            collaborationMessage = "Could not load more diary entries."
        }
    }

    func refreshPublicProfileLoved(for profileID: UUID) async {
#if DEBUG
        guard !isDiaryEditorUITestFixtureActive else { return }
#endif
        var shelves = publicProfileShelves[profileID] ?? PublicProfileShelfState()
        guard !shelves.loved.isRefreshing, !shelves.loved.isLoadingMore else { return }
        shelves.loved.isRefreshing = true
        publicProfileShelves[profileID] = shelves
        defer { publicProfileShelves[profileID]?.loved.isRefreshing = false }
        do {
            let page = try await collaborationRepository.publicProfileLovedPage(
                profileID: profileID,
                limit: socialShelfPageSize + 1
            )
            publicProfileShelves[profileID]?.loved.items = Array(page.prefix(socialShelfPageSize))
            publicProfileShelves[profileID]?.loved.hasMore = page.count > socialShelfPageSize
        } catch {
            collaborationMessage = "Could not load this member's Loved shelf."
        }
    }

    func loadMorePublicProfileLoved(for profileID: UUID) async {
        guard var shelves = publicProfileShelves[profileID],
              shelves.loved.hasMore,
              !shelves.loved.isRefreshing,
              !shelves.loved.isLoadingMore,
              let cursor = shelves.loved.items.last else { return }
        shelves.loved.isLoadingMore = true
        publicProfileShelves[profileID] = shelves
        defer { publicProfileShelves[profileID]?.loved.isLoadingMore = false }
        do {
            let page = try await collaborationRepository.publicProfileLovedPage(
                profileID: profileID,
                beforeUpdatedAt: cursor.updatedAt,
                beforeCanonicalTrackID: cursor.canonicalTrackID,
                limit: socialShelfPageSize + 1
            )
            let existingIDs = Set(shelves.loved.items.map(\.id))
            publicProfileShelves[profileID]?.loved.items.append(
                contentsOf: page.prefix(socialShelfPageSize).filter { !existingIDs.contains($0.id) }
            )
            publicProfileShelves[profileID]?.loved.hasMore = page.count > socialShelfPageSize
        } catch {
            collaborationMessage = "Could not load more Loved tracks."
        }
    }

    func refreshPublicProfileLists(for profileID: UUID) async {
#if DEBUG
        guard !isDiaryEditorUITestFixtureActive else { return }
#endif
        var shelves = publicProfileShelves[profileID] ?? PublicProfileShelfState()
        guard !shelves.lists.isRefreshing, !shelves.lists.isLoadingMore else { return }
        shelves.lists.isRefreshing = true
        publicProfileShelves[profileID] = shelves
        defer { publicProfileShelves[profileID]?.lists.isRefreshing = false }
        do {
            let page = try await collaborationRepository.publicProfileMusicListsPage(
                profileID: profileID,
                limit: musicListPageSize + 1
            )
            let visible = Array(page.prefix(musicListPageSize))
            publicProfileShelves[profileID]?.lists.items = visible
            publicProfileShelves[profileID]?.lists.hasMore = page.count > musicListPageSize
            visible.forEach { cacheMusicList($0) }
        } catch {
            collaborationMessage = "Could not load this member's lists."
        }
    }

    func loadMorePublicProfileLists(for profileID: UUID) async {
        guard var shelves = publicProfileShelves[profileID],
              shelves.lists.hasMore,
              !shelves.lists.isRefreshing,
              !shelves.lists.isLoadingMore,
              let cursor = shelves.lists.items.last else { return }
        shelves.lists.isLoadingMore = true
        publicProfileShelves[profileID] = shelves
        defer { publicProfileShelves[profileID]?.lists.isLoadingMore = false }
        do {
            let page = try await collaborationRepository.publicProfileMusicListsPage(
                profileID: profileID,
                beforeUpdatedAt: cursor.updatedAt,
                beforeID: cursor.id,
                limit: musicListPageSize + 1
            )
            let existingIDs = Set(shelves.lists.items.map(\.id))
            let visible = page.prefix(musicListPageSize)
                .filter { !existingIDs.contains($0.id) }
            publicProfileShelves[profileID]?.lists.items.append(contentsOf: visible)
            publicProfileShelves[profileID]?.lists.hasMore = page.count > musicListPageSize
            visible.forEach { cacheMusicList($0) }
        } catch {
            collaborationMessage = "Could not load more lists."
        }
    }

    func clearPublicProfileShelves(for profileID: UUID) {
        publicProfileShelves.removeValue(forKey: profileID)
    }

    // MARK: - Music lists and collections

    func musicListDetail(for listID: UUID) -> MusicListDetailState {
        musicListDetails[listID] ?? MusicListDetailState()
    }

    func isOwnMusicList(_ list: RemoteMusicList) -> Bool {
        list.ownerID == authenticatedProfileID
    }

    func musicListLikeState(for listID: UUID) -> Bool? {
        musicListLikeStates[listID]
    }

    func canDeleteMusicListComment(_ comment: RemoteMusicListComment) -> Bool {
        if comment.authorID == authenticatedProfileID { return true }
        return musicListDetails[comment.listID]?.list.map(isOwnMusicList) ?? false
    }

    func refreshOwnerMusicLists() async {
        guard !isRefreshingOwnerMusicLists, !isLoadingMoreOwnerMusicLists else { return }
        isRefreshingOwnerMusicLists = true
        defer { isRefreshingOwnerMusicLists = false }
        do {
            let page = try await collaborationRepository.ownerMusicListsPage(
                limit: musicListPageSize + 1
            )
            ownerMusicLists = Array(page.prefix(musicListPageSize))
            hasMoreOwnerMusicLists = page.count > musicListPageSize
            ownerMusicLists.forEach { cacheMusicList($0) }
        } catch {
            collaborationMessage = "Could not refresh your lists."
        }
    }

    func loadMoreOwnerMusicLists() async {
        guard hasMoreOwnerMusicLists,
              !isRefreshingOwnerMusicLists,
              !isLoadingMoreOwnerMusicLists,
              let cursor = ownerMusicLists.last else { return }
        isLoadingMoreOwnerMusicLists = true
        defer { isLoadingMoreOwnerMusicLists = false }
        do {
            let page = try await collaborationRepository.ownerMusicListsPage(
                beforeUpdatedAt: cursor.updatedAt,
                beforeID: cursor.id,
                limit: musicListPageSize + 1
            )
            let existingIDs = Set(ownerMusicLists.map(\.id))
            let visible = page.prefix(musicListPageSize)
                .filter { !existingIDs.contains($0.id) }
            ownerMusicLists.append(contentsOf: visible)
            hasMoreOwnerMusicLists = page.count > musicListPageSize
            visible.forEach { cacheMusicList($0) }
        } catch {
            collaborationMessage = "Could not load more of your lists."
        }
    }

    /// Loads parent metadata and the first entry/comment pages as one cache
    /// snapshot. A failed child read leaves the previous detail intact.
    @discardableResult
    func refreshMusicListDetail(_ listID: UUID) async -> Bool {
        var detail = musicListDetails[listID] ?? MusicListDetailState()
        guard !detail.isRefreshing else { return false }
        detail.isRefreshing = true
        musicListDetails[listID] = detail
        defer { musicListDetails[listID]?.isRefreshing = false }
        do {
            async let list = collaborationRepository.musicList(id: listID)
            async let entries = collaborationRepository.musicListEntriesPage(
                listID: listID,
                limit: musicListEntryPageSize
            )
            async let comments = collaborationRepository.musicListCommentsPage(
                listID: listID,
                limit: musicListPageSize + 1
            )
            async let engagement = collaborationRepository.musicListEngagement(listID)
            guard let loadedList = try await list else {
                musicListDetails.removeValue(forKey: listID)
                collaborationMessage = "This list is unavailable."
                return false
            }
            let loadedEntries = try await entries
            let loadedComments = try await comments
            let loadedEngagement = try await engagement
            var loaded = MusicListDetailState(list: loadedList)
            loaded.entries.items = loadedEntries
            loaded.entries.hasMore = loadedEntries.count == musicListEntryPageSize
            loaded.comments.items = Array(loadedComments.prefix(musicListPageSize))
            loaded.comments.hasMore = loadedComments.count > musicListPageSize
            loaded.engagement = loadedEngagement
            musicListDetails[listID] = loaded
            musicListLikeStates[listID] = loadedEngagement.viewerHasLiked
            cacheMusicList(loadedList)
            return true
        } catch {
            collaborationMessage = "Could not load this list: \(error.localizedDescription)"
            return false
        }
    }

    func refreshMusicListEntries(_ listID: UUID) async {
        var detail = musicListDetails[listID] ?? MusicListDetailState()
        guard !detail.entries.isRefreshing, !detail.entries.isLoadingMore else { return }
        detail.entries.isRefreshing = true
        musicListDetails[listID] = detail
        defer { musicListDetails[listID]?.entries.isRefreshing = false }
        do {
            let page = try await collaborationRepository.musicListEntriesPage(
                listID: listID,
                limit: musicListEntryPageSize
            )
            musicListDetails[listID]?.entries.items = page
            musicListDetails[listID]?.entries.hasMore = page.count == musicListEntryPageSize
            await refreshMusicListEngagement(listID)
        } catch {
            collaborationMessage = "Could not refresh list songs."
        }
    }

    func loadMoreMusicListEntries(_ listID: UUID) async {
        guard var detail = musicListDetails[listID],
              detail.entries.hasMore,
              !detail.entries.isRefreshing,
              !detail.entries.isLoadingMore,
              let cursor = detail.entries.items.last else { return }
        detail.entries.isLoadingMore = true
        musicListDetails[listID] = detail
        defer { musicListDetails[listID]?.entries.isLoadingMore = false }
        do {
            let page = try await collaborationRepository.musicListEntriesPage(
                listID: listID,
                afterPosition: cursor.position,
                limit: musicListEntryPageSize
            )
            let existingIDs = Set(detail.entries.items.map(\.id))
            musicListDetails[listID]?.entries.items.append(
                contentsOf: page.prefix(musicListEntryPageSize)
                    .filter { !existingIDs.contains($0.id) }
            )
            musicListDetails[listID]?.entries.hasMore = page.count == musicListEntryPageSize
        } catch {
            collaborationMessage = "Could not load more list songs."
        }
    }

    func refreshMusicListComments(_ listID: UUID) async {
        var detail = musicListDetails[listID] ?? MusicListDetailState()
        guard !detail.comments.isRefreshing, !detail.comments.isLoadingMore else { return }
        detail.comments.isRefreshing = true
        musicListDetails[listID] = detail
        defer { musicListDetails[listID]?.comments.isRefreshing = false }
        do {
            let page = try await collaborationRepository.musicListCommentsPage(
                listID: listID,
                limit: musicListPageSize + 1
            )
            musicListDetails[listID]?.comments.items = Array(page.prefix(musicListPageSize))
            musicListDetails[listID]?.comments.hasMore = page.count > musicListPageSize
            await refreshMusicListEngagement(listID)
        } catch {
            collaborationMessage = "Could not refresh list comments."
        }
    }

    func loadMoreMusicListComments(_ listID: UUID) async {
        guard var detail = musicListDetails[listID],
              detail.comments.hasMore,
              !detail.comments.isRefreshing,
              !detail.comments.isLoadingMore,
              let cursor = detail.comments.items.last else { return }
        detail.comments.isLoadingMore = true
        musicListDetails[listID] = detail
        defer { musicListDetails[listID]?.comments.isLoadingMore = false }
        do {
            let page = try await collaborationRepository.musicListCommentsPage(
                listID: listID,
                beforeCreatedAt: cursor.createdAt,
                beforeID: cursor.id,
                limit: musicListPageSize + 1
            )
            let existingIDs = Set(detail.comments.items.map(\.id))
            musicListDetails[listID]?.comments.items.append(
                contentsOf: page.prefix(musicListPageSize)
                    .filter { !existingIDs.contains($0.id) }
            )
            musicListDetails[listID]?.comments.hasMore = page.count > musicListPageSize
        } catch {
            collaborationMessage = "Could not load more list comments."
        }
    }

    func clearMusicListDetail(_ listID: UUID) {
        musicListDetails.removeValue(forKey: listID)
    }

    private func refreshMusicListEngagement(_ listID: UUID) async {
        do {
            let engagement = try await collaborationRepository.musicListEngagement(listID)
            musicListDetails[listID]?.engagement = engagement
            musicListLikeStates[listID] = engagement.viewerHasLiked
        } catch {
            // Parent/entry/comment content remains usable if a summary refresh
            // races a visibility change or transient network failure.
        }
    }

    @discardableResult
    func createMusicList(from draft: MusicListDraft) async -> RemoteMusicList? {
        guard !isCreatingMusicList else { return nil }
        guard let validated = validatedMusicListDraft(draft) else { return nil }
        isCreatingMusicList = true
        defer { isCreatingMusicList = false }
        do {
            let list = try await collaborationRepository.saveMusicList(
                listID: nil,
                title: validated.normalizedTitle,
                description: validated.normalizedDescription,
                tags: validated.normalizedTags,
                isRanked: validated.isRanked,
                visibility: validated.visibility,
                entries: validated.entries,
                expectedRevision: nil
            )
            cacheMusicList(list, promoteInOwnerShelf: true)
            ownerMusicLists.removeAll { $0.id == list.id }
            ownerMusicLists.insert(list, at: 0)
            musicListDetails[list.id] = MusicListDetailState(list: list)
            await refreshMusicListEntries(list.id)
            collaborationMessage = "List created"
            return list
        } catch {
            collaborationMessage = "Could not create list: \(error.localizedDescription)"
            return nil
        }
    }

    @discardableResult
    func updateMusicList(_ list: RemoteMusicList, from draft: MusicListDraft) async -> Bool {
        guard isOwnMusicList(list), !mutatingMusicListIDs.contains(list.id) else { return false }
        if musicListDetails[list.id]?.entries.hasMore == true {
            collaborationMessage = "Load every song before editing the complete list."
            return false
        }
        guard let validated = validatedMusicListDraft(draft) else { return false }
        let expectedRevision = cachedMusicList(id: list.id)?.entriesRevision ?? list.entriesRevision
        mutatingMusicListIDs.insert(list.id)
        defer { mutatingMusicListIDs.remove(list.id) }
        do {
            let updated = try await collaborationRepository.saveMusicList(
                listID: list.id,
                title: validated.normalizedTitle,
                description: validated.normalizedDescription,
                tags: validated.normalizedTags,
                isRanked: validated.isRanked,
                visibility: validated.visibility,
                entries: validated.entries,
                expectedRevision: expectedRevision
            )
            cacheMusicList(updated, promoteInOwnerShelf: true)
            await refreshMusicListEntries(list.id)
            collaborationMessage = "List updated"
            return true
        } catch {
            await handleMusicListMutationFailure(error, listID: list.id)
            return false
        }
    }

    @discardableResult
    func deleteMusicList(_ list: RemoteMusicList) async -> Bool {
        guard isOwnMusicList(list), !mutatingMusicListIDs.contains(list.id) else { return false }
        mutatingMusicListIDs.insert(list.id)
        defer { mutatingMusicListIDs.remove(list.id) }
        do {
            try await collaborationRepository.deleteMusicList(list.id)
            removeCachedMusicList(list.id)
            collaborationMessage = "List deleted"
            return true
        } catch {
            collaborationMessage = "Could not delete list: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func addTrackToMusicList(
        _ track: HarmonyTrack,
        note: String = "",
        listID: UUID
    ) async -> Bool {
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard note.count <= 1_000 else {
            collaborationMessage = "List notes must be 1,000 characters or fewer."
            return false
        }
        guard let list = cachedMusicList(id: listID), isOwnMusicList(list),
              !mutatingMusicListIDs.contains(listID) else { return false }
        mutatingMusicListIDs.insert(listID)
        defer { mutatingMusicListIDs.remove(listID) }
        do {
            let result = try await collaborationRepository.addMusicListEntry(
                listID: listID,
                track: track,
                note: note,
                expectedRevision: list.entriesRevision
            )
            setCachedMusicListRevision(result.entriesRevision, listID: listID)
            await refreshMusicListEntries(listID)
            collaborationMessage = "Song added to list"
            return true
        } catch {
            await handleMusicListMutationFailure(error, listID: listID)
            return false
        }
    }

    @discardableResult
    func updateMusicListEntryNote(_ entry: RemoteMusicListEntry, note proposedNote: String) async -> Bool {
        let note = proposedNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard note.count <= 1_000 else {
            collaborationMessage = "List notes must be 1,000 characters or fewer."
            return false
        }
        guard let list = cachedMusicList(id: entry.listID), isOwnMusicList(list),
              !mutatingMusicListIDs.contains(entry.listID),
              !mutatingMusicListEntryIDs.contains(entry.id) else { return false }
        mutatingMusicListIDs.insert(entry.listID)
        mutatingMusicListEntryIDs.insert(entry.id)
        defer {
            mutatingMusicListIDs.remove(entry.listID)
            mutatingMusicListEntryIDs.remove(entry.id)
        }
        do {
            let result = try await collaborationRepository.updateMusicListEntryNote(
                entryID: entry.id,
                note: note,
                expectedRevision: list.entriesRevision
            )
            setCachedMusicListRevision(result.entriesRevision, listID: entry.listID)
            await refreshMusicListEntries(entry.listID)
            collaborationMessage = "List note updated"
            return true
        } catch {
            await handleMusicListMutationFailure(error, listID: entry.listID)
            return false
        }
    }

    @discardableResult
    func removeMusicListEntry(_ entry: RemoteMusicListEntry) async -> Bool {
        guard let list = cachedMusicList(id: entry.listID), isOwnMusicList(list),
              !mutatingMusicListIDs.contains(entry.listID),
              !mutatingMusicListEntryIDs.contains(entry.id) else { return false }
        mutatingMusicListIDs.insert(entry.listID)
        mutatingMusicListEntryIDs.insert(entry.id)
        defer {
            mutatingMusicListIDs.remove(entry.listID)
            mutatingMusicListEntryIDs.remove(entry.id)
        }
        do {
            let revision = try await collaborationRepository.removeMusicListEntry(
                entryID: entry.id,
                expectedRevision: list.entriesRevision
            )
            setCachedMusicListRevision(revision, listID: entry.listID)
            await refreshMusicListEntries(entry.listID)
            collaborationMessage = "Song removed from list"
            return true
        } catch {
            await handleMusicListMutationFailure(error, listID: entry.listID)
            return false
        }
    }

    @discardableResult
    func reorderMusicListEntries(listID: UUID, orderedEntryIDs: [UUID]) async -> Bool {
        guard let list = cachedMusicList(id: listID), isOwnMusicList(list),
              let detail = musicListDetails[listID], !detail.entries.hasMore,
              !mutatingMusicListIDs.contains(listID) else { return false }
        let currentIDs = detail.entries.items.map(\.id)
        guard orderedEntryIDs.count == currentIDs.count,
              Set(orderedEntryIDs) == Set(currentIDs) else {
            collaborationMessage = "Reload the complete list before reordering."
            return false
        }
        guard orderedEntryIDs != currentIDs else { return true }
        mutatingMusicListIDs.insert(listID)
        defer { mutatingMusicListIDs.remove(listID) }
        do {
            let revision = try await collaborationRepository.reorderMusicListEntries(
                listID: listID,
                orderedEntryIDs: orderedEntryIDs,
                expectedRevision: list.entriesRevision
            )
            setCachedMusicListRevision(revision, listID: listID)
            await refreshMusicListEntries(listID)
            collaborationMessage = "List order updated"
            return true
        } catch {
            await handleMusicListMutationFailure(error, listID: listID)
            return false
        }
    }

    @discardableResult
    func setMusicListLiked(_ listID: UUID, isLiked: Bool) async -> Bool {
        guard !likingMusicListIDs.contains(listID) else { return false }
        likingMusicListIDs.insert(listID)
        defer { likingMusicListIDs.remove(listID) }
        do {
            let persistedValue = try await collaborationRepository.setMusicListLiked(
                listID,
                isLiked: isLiked
            )
            if persistedValue {
                musicListLikeStates[listID] = true
            } else {
                musicListLikeStates[listID] = false
            }
            if var engagement = musicListDetails[listID]?.engagement {
                let delta = persistedValue == engagement.viewerHasLiked ? 0 : (persistedValue ? 1 : -1)
                engagement = RemoteMusicListEngagement(
                    entryCount: engagement.entryCount,
                    likeCount: max(0, engagement.likeCount + delta),
                    commentCount: engagement.commentCount,
                    viewerHasLiked: persistedValue
                )
                musicListDetails[listID]?.engagement = engagement
            }
            collaborationMessage = persistedValue ? "List liked" : "List unliked"
            return true
        } catch {
            collaborationMessage = "Could not update this like: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func addMusicListComment(listID: UUID, body proposedBody: String) async -> Bool {
        let body = proposedBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...2_000).contains(body.count) else {
            collaborationMessage = "Comments must contain 1 to 2,000 characters."
            return false
        }
        guard !commentingMusicListIDs.contains(listID) else { return false }
        commentingMusicListIDs.insert(listID)
        defer { commentingMusicListIDs.remove(listID) }
        do {
            let comment = try await collaborationRepository.addMusicListComment(
                listID: listID,
                body: body
            )
            var detail = musicListDetails[listID] ?? MusicListDetailState()
            detail.comments.items.removeAll { $0.id == comment.id }
            detail.comments.items.insert(comment, at: 0)
            musicListDetails[listID] = detail
            if let engagement = detail.engagement {
                musicListDetails[listID]?.engagement = RemoteMusicListEngagement(
                    entryCount: engagement.entryCount,
                    likeCount: engagement.likeCount,
                    commentCount: engagement.commentCount + 1,
                    viewerHasLiked: engagement.viewerHasLiked
                )
            }
            collaborationMessage = "Comment added"
            return true
        } catch {
            collaborationMessage = "Could not add comment: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func deleteMusicListComment(_ comment: RemoteMusicListComment) async -> Bool {
        guard canDeleteMusicListComment(comment),
              !deletingMusicListCommentIDs.contains(comment.id) else { return false }
        deletingMusicListCommentIDs.insert(comment.id)
        defer { deletingMusicListCommentIDs.remove(comment.id) }
        do {
            try await collaborationRepository.deleteMusicListComment(comment.id)
            musicListDetails[comment.listID]?.comments.items.removeAll { $0.id == comment.id }
            if let engagement = musicListDetails[comment.listID]?.engagement {
                musicListDetails[comment.listID]?.engagement = RemoteMusicListEngagement(
                    entryCount: engagement.entryCount,
                    likeCount: engagement.likeCount,
                    commentCount: max(0, engagement.commentCount - 1),
                    viewerHasLiked: engagement.viewerHasLiked
                )
            }
            collaborationMessage = "Comment deleted"
            return true
        } catch {
            collaborationMessage = "Could not delete comment: \(error.localizedDescription)"
            return false
        }
    }

    private func validatedMusicListDraft(_ draft: MusicListDraft) -> MusicListDraft? {
        if let validationMessage = draft.validationMessage {
            collaborationMessage = validationMessage
            return nil
        }
        return draft
    }

    private func cachedMusicList(id listID: UUID) -> RemoteMusicList? {
        if let list = musicListDetails[listID]?.list { return list }
        if let list = ownerMusicLists.first(where: { $0.id == listID }) { return list }
        for shelves in publicProfileShelves.values {
            if let list = shelves.lists.items.first(where: { $0.id == listID }) { return list }
        }
        return nil
    }

    private func cacheMusicList(
        _ list: RemoteMusicList,
        promoteInOwnerShelf: Bool = false
    ) {
        var detail = musicListDetails[list.id] ?? MusicListDetailState()
        detail.list = list
        musicListDetails[list.id] = detail

        let ownerIndex = ownerMusicLists.firstIndex(where: { $0.id == list.id })
        if isOwnMusicList(list) || ownerIndex != nil {
            if let index = ownerIndex,
               !promoteInOwnerShelf {
                ownerMusicLists[index] = list
            } else {
                ownerMusicLists.removeAll { $0.id == list.id }
                ownerMusicLists.insert(list, at: 0)
            }
        }

        for profileID in Array(publicProfileShelves.keys) {
            guard let index = publicProfileShelves[profileID]?.lists.items.firstIndex(where: {
                $0.id == list.id
            }) else { continue }
            publicProfileShelves[profileID]?.lists.items[index] = list
        }
    }

    private func removeCachedMusicList(_ listID: UUID) {
        ownerMusicLists.removeAll { $0.id == listID }
        musicListDetails.removeValue(forKey: listID)
        musicListLikeStates.removeValue(forKey: listID)
        for profileID in Array(publicProfileShelves.keys) {
            publicProfileShelves[profileID]?.lists.items.removeAll { $0.id == listID }
        }
    }

    private func setCachedMusicListRevision(_ revision: Int, listID: UUID) {
        guard let list = cachedMusicList(id: listID) else { return }
        cacheMusicList(RemoteMusicList(
            id: list.id,
            ownerID: list.ownerID,
            title: list.title,
            description: list.description,
            tags: list.tags,
            isRanked: list.isRanked,
            visibility: list.visibility,
            entriesRevision: revision,
            createdAt: list.createdAt,
            updatedAt: list.updatedAt,
            deletedAt: list.deletedAt,
            owner: list.owner
        ))
    }

    private func handleMusicListMutationFailure(_ error: Error, listID: UUID) async {
        let detail = error.localizedDescription.lowercased()
        if detail.contains("revision") || detail.contains("stale") || detail.contains("conflict") {
            _ = await refreshMusicListDetail(listID)
            collaborationMessage = "This list changed elsewhere. It was reloaded; review and apply your edit again."
        } else {
            collaborationMessage = "Could not update list: \(error.localizedDescription)"
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
            heartCount: 0,
            commentCount: 0,
            subjectKind: "track",
            subjectTitle: track.title,
            subjectArtist: track.artist,
            subjectArtworkURL: nil,
            subjectDeepLink: nil,
            canonicalAlbumID: nil,
            canonicalTrack: track,
            canonicalAlbum: nil,
            profile: profile
        )
        authenticatedProfileID = profileID
        isDiaryEditorUITestFixtureActive = true
        musicReviews = [review]
        ownerReviews = [review]
        ownerReviewStats = RemoteOwnerReviewStats(
            reviewCount: 1,
            averageRating: review.rating,
            lovedCount: 1,
            songCount: 1,
            albumCount: 0
        )
        let entry = RemoteListeningHistoryEntry(
            id: entryID,
            profileID: profileID,
            playedAt: Calendar.current.date(byAdding: .day, value: -2, to: Date())!,
            source: "manual",
            visibility: .privateOnly,
            isRelisten: true,
            tags: ["party", "vinyl"],
            rating: 4.5,
            reviewID: reviewID,
            canonicalTrack: track,
            profile: profile
        )
        listeningHistory = [entry]
        journalEntries = [entry]
        let subjectState = RemoteTrackSubjectState(
            profileID: profileID,
            canonicalTrackID: trackID,
            hasListened: true,
            defaultRating: 4.0,
            isLoved: true,
            wantToListen: false,
            createdAt: Date(),
            updatedAt: Date(),
            canonicalTrack: track
        )
        trackSubjectStates[trackID] = subjectState
        trackSubjectShelf = [subjectState]

        let albumID = UUID(uuidString: "70000000-0000-0000-0000-000000000007")!
        let album = RemoteCanonicalAlbum(
            id: albumID,
            title: "Northern Lights",
            artist: "Wolves at Noon",
            releaseDate: "2026-01-16",
            upc: nil,
            albumType: "album",
            totalTracks: 10,
            artworkURL: nil,
            providerAlbums: [
                RemoteProviderAlbum(
                    provider: "spotify",
                    providerAlbumID: "spotify:album:ui-northern-lights",
                    storefront: "global",
                    deepLink: URL(string: "https://open.spotify.com/album/ui-northern-lights"),
                    availability: "playable",
                    identityBasis: "provider"
                )
            ]
        )
        let albumState = RemoteAlbumSubjectState(
            profileID: profileID,
            canonicalAlbumID: albumID,
            hasListened: true,
            defaultRating: 4.5,
            isLoved: true,
            wantToListen: false,
            createdAt: Date(),
            updatedAt: Date(),
            canonicalAlbum: album
        )
        albumSubjectStates[albumID] = albumState
        albumSubjectShelf = [albumState]
        canonicalAlbumDetails[albumID] = CanonicalAlbumDetailState(
            album: album,
            ownerState: albumState,
            aggregate: RemoteCanonicalAlbumStateAggregate(
                canonicalAlbumID: albumID,
                ratingCount: 2,
                averageRating: 4.25,
                listenedCount: 2,
                lovedCount: 1,
                wantToListenCount: 0
            ),
            ratingDistribution: (1...10).map {
                RemoteCanonicalAlbumRatingBucket(
                    rating: Double($0) / 2,
                    ratingCount: $0 == 9 ? 2 : 0
                )
            }
        )
    }

    func seedSocialActivityUITestFixture() {
        seedDiaryEditorUITestFixture()
        guard let review = musicReviews.first,
              let entry = journalEntries.first,
              let track = entry.canonicalTrack,
              let canonicalTrackID = track.id else { return }
        let actor = RemoteProfile(displayName: "UI Test Listener")
        // `list_following_activity` suppresses a Diary event when the same
        // publish action also produced its visible linked Review event. Keep
        // the fixture's second card as a genuinely standalone Diary event so
        // UI coverage reflects the server feed instead of presenting one
        // atomic action twice. The member-profile fixture below deliberately
        // retains the linked owner entry to cover safe review navigation.
        let standaloneActivityEntry = RemoteListeningHistoryEntry(
            id: UUID(uuidString: "80000000-0000-0000-0000-000000000008")!,
            profileID: entry.profileID,
            playedAt: entry.playedAt,
            source: entry.source,
            visibility: .followers,
            isRelisten: entry.isRelisten,
            tags: entry.tags,
            rating: entry.rating,
            reviewID: nil,
            canonicalTrack: entry.canonicalTrack,
            profile: entry.profile
        )
        followingActivity = [
            RemoteFollowingActivityItem(
                id: UUID(uuidString: "50000000-0000-0000-0000-000000000005")!,
                actorID: entry.profileID,
                publishedAt: Date(),
                actor: actor,
                payload: .review(review)
            ),
            RemoteFollowingActivityItem(
                id: UUID(uuidString: "60000000-0000-0000-0000-000000000006")!,
                actorID: entry.profileID,
                publishedAt: entry.playedAt,
                actor: actor,
                payload: .diary(standaloneActivityEntry)
            )
        ]
        followingActivityCursor = RemoteFollowingActivityCursor(
            publishedAt: entry.playedAt,
            id: followingActivity[1].id
        )
        hasMoreFollowingActivity = false
        var shelves = PublicProfileShelfState()
        shelves.reviews.items = [review]
        shelves.diary.items = [entry]
        shelves.loved.items = [RemotePublicLovedTrack(
            profileID: entry.profileID,
            canonicalTrackID: canonicalTrackID,
            updatedAt: Date(),
            canonicalTrack: track
        )]
        publicProfileShelves[entry.profileID] = shelves
        let requestProfileID = UUID(uuidString: "81000000-0000-0000-0000-000000000008")!
        let discoveryProfileID = UUID(uuidString: "82000000-0000-0000-0000-000000000008")!
        socialProfiles = [
            RemoteSocialProfile(id: requestProfileID, displayName: "Pending Listener")
        ]
        socialFollows = [
            RemoteSocialFollow(
                followerID: requestProfileID,
                followedID: entry.profileID,
                state: "requested"
            )
        ]
        let discoveryProfiles = [
            RemoteSocialProfile(id: discoveryProfileID, displayName: "Searchable Listener")
        ]
        socialDiscoveryFixtureProfiles = discoveryProfiles
        discoveredSocialProfiles = discoveryProfiles
        let endedBroadcastID = UUID(uuidString: "72000000-0000-0000-0000-000000000007")!
        let endedBroadcast = EavesdropBroadcast(
            id: endedBroadcastID,
            hostProfileID: entry.profileID,
            hostDisplayName: "UI Test Listener",
            status: "listening",
            visibility: .followers,
            canonicalTrackID: canonicalTrackID,
            title: track.title,
            artist: track.artist,
            album: track.album,
            durationMilliseconds: track.durationMilliseconds,
            artworkURL: track.artworkURL,
            isExplicit: track.isExplicit,
            startedAt: Date().addingTimeInterval(-180),
            expiresAt: Date().addingTimeInterval(120),
            endedAt: Date().addingTimeInterval(-60),
            endedReason: "stopped",
            sourceProvider: "spotify",
            sourceDeepLink: nil,
            destinations: [:]
        )
        eavesdropDetails[endedBroadcastID] = EavesdropBroadcastDetailState(
            broadcast: endedBroadcast,
            comments: [
                RemoteEavesdropComment(
                    id: UUID(uuidString: "73000000-0000-0000-0000-000000000007")!,
                    broadcastID: endedBroadcastID,
                    authorID: UUID(uuidString: "91000000-0000-0000-0000-000000000009")!,
                    body: "That bridge was incredible.",
                    createdAt: Date().addingTimeInterval(-90),
                    author: RemoteProfile(displayName: "UI Test Live Listener")
                )
            ],
            reactions: []
        )
        socialNotifications = [
            RemoteSocialNotification(
                id: UUID(uuidString: "70000000-0000-0000-0000-000000000007")!,
                actorID: UUID(uuidString: "90000000-0000-0000-0000-000000000009")!,
                kind: "review_comment",
                createdAt: Date(),
                readAt: Date(),
                actor: RemoteProfile(displayName: "UI Test Commenter"),
                reviewID: review.id,
                musicListID: nil,
                review: RemoteNotificationReview(
                    subjectTitle: review.subjectTitle,
                    canonicalTrack: track
                ),
                musicList: nil,
                listeningBroadcastID: nil
            ),
            RemoteSocialNotification(
                id: UUID(uuidString: "71000000-0000-0000-0000-000000000007")!,
                actorID: UUID(uuidString: "91000000-0000-0000-0000-000000000009")!,
                kind: "listening_broadcast_reaction",
                createdAt: Date().addingTimeInterval(-60),
                readAt: nil,
                actor: RemoteProfile(displayName: "UI Test Live Listener"),
                reviewID: nil,
                musicListID: nil,
                review: nil,
                musicList: nil,
                listeningBroadcastID: endedBroadcastID
            )
        ]
        unreadSocialNotificationCount = 1
    }
#endif

    func deleteListeningHistoryEntry(_ entryID: UUID) async {
        do {
            try await collaborationRepository.deleteListeningHistoryEntry(entryID)
            collaborationMessage = "History entry deleted"
            await refreshListeningHistory()
            await refreshJournalEntries()
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
#if DEBUG
        if isDiaryEditorUITestFixtureActive { return }
#endif
        guard !isRefreshingSocialProfiles else { return }
        isRefreshingSocialProfiles = true
        defer { isRefreshingSocialProfiles = false }
        do {
            async let follows = collaborationRepository.socialFollows()
            async let blockedProfiles = collaborationRepository.myBlockedSocialProfiles()
            async let userID = collaborationRepository.currentUserID()
            let relationshipResult = try await (follows, blockedProfiles, userID)
            let fetchedFollows = relationshipResult.0
            let fetchedBlockedProfiles = relationshipResult.1
            let currentUserID = relationshipResult.2
            let relatedIDs = Set(fetchedFollows.flatMap { [$0.followerID, $0.followedID] })
                .subtracting([currentUserID])
            let profiles = try await collaborationRepository.socialProfiles(ids: Array(relatedIDs))

            socialProfiles = profiles
            socialFollows = fetchedFollows
            blockedSocialProfiles = fetchedBlockedProfiles
            blockedSocialProfileIDs = Set(fetchedBlockedProfiles.map(\.id))
            authenticatedProfileID = currentUserID
        } catch {
            collaborationMessage = "Could not refresh people: \(error.localizedDescription)"
        }
    }

    func refreshSocialDiscovery(search: String) async {
        let normalized = search.trimmingCharacters(in: .whitespacesAndNewlines)
#if DEBUG
        if isDiaryEditorUITestFixtureActive {
            socialDiscoveryQuery = normalized
            discoveredSocialProfiles = normalized.isEmpty
                ? socialDiscoveryFixtureProfiles
                : socialDiscoveryFixtureProfiles.filter {
                    $0.displayName.localizedCaseInsensitiveContains(normalized)
                }
            hasMoreSocialDiscovery = false
            return
        }
#endif
        let requestID = UUID()
        socialDiscoveryRequestID = requestID
        socialDiscoveryQuery = normalized
        isRefreshingSocialDiscovery = true
        defer {
            if socialDiscoveryRequestID == requestID {
                isRefreshingSocialDiscovery = false
            }
        }

        do {
            let page = try await collaborationRepository.discoverSocialProfiles(
                search: normalized.isEmpty ? nil : normalized,
                limit: socialDiscoveryPageSize + 1
            )
            guard socialDiscoveryRequestID == requestID else { return }
            let window = Array(page.prefix(socialDiscoveryPageSize))
            discoveredSocialProfiles = window
            socialDiscoveryCursor = window.last.map {
                RemoteSocialProfileCursor(displayName: $0.displayName, id: $0.id)
            }
            hasMoreSocialDiscovery = page.count > socialDiscoveryPageSize
        } catch {
            guard socialDiscoveryRequestID == requestID else { return }
            collaborationMessage = "Could not search for people."
        }
    }

    func loadMoreSocialDiscovery() async {
        guard hasMoreSocialDiscovery,
              !isRefreshingSocialDiscovery,
              !isLoadingMoreSocialDiscovery,
              let cursor = socialDiscoveryCursor else { return }
        isLoadingMoreSocialDiscovery = true
        defer { isLoadingMoreSocialDiscovery = false }

        do {
            let page = try await collaborationRepository.discoverSocialProfiles(
                search: socialDiscoveryQuery.isEmpty ? nil : socialDiscoveryQuery,
                after: cursor,
                limit: socialDiscoveryPageSize + 1
            )
            let window = Array(page.prefix(socialDiscoveryPageSize))
            discoveredSocialProfiles = mergedSocialProfileDiscovery(
                existing: discoveredSocialProfiles,
                incoming: window
            )
            socialDiscoveryCursor = window.last.map {
                RemoteSocialProfileCursor(displayName: $0.displayName, id: $0.id)
            } ?? socialDiscoveryCursor
            hasMoreSocialDiscovery = page.count > socialDiscoveryPageSize
        } catch {
            collaborationMessage = "Could not load more people."
        }
    }

    func refreshSocialNotifications(preservingLoadedPages: Bool = false) async {
#if DEBUG
        guard !isDiaryEditorUITestFixtureActive else { return }
#endif
        guard !isRefreshingSocialNotifications, !isLoadingMoreSocialNotifications else { return }
        isRefreshingSocialNotifications = true
        defer { isRefreshingSocialNotifications = false }

        do {
            let page = try await collaborationRepository.socialNotificationsPage(
                limit: socialNotificationPageSize + 1
            )
            let firstWindow = Array(page.prefix(socialNotificationPageSize))

            if preservingLoadedPages,
               !socialNotifications.isEmpty,
               page.count > socialNotificationPageSize {
                // Prefer refreshed copies of IDs in the authoritative newest
                // window, then retain every older page already loaded. New
                // notifications can displace prior first-page rows, so simply
                // dropping the old first 50 would create a gap.
                socialNotifications = mergedRefreshedSocialNotifications(
                    newestWindow: firstWindow,
                    previouslyLoaded: socialNotifications
                )
                // The loaded depth and its raw cursor remain valid because all
                // Realtime inserts are newer than that cursor.
            } else {
                socialNotifications = firstWindow
                socialNotificationCursor = firstWindow.last.map {
                    RemoteSocialNotificationCursor(createdAt: $0.createdAt, id: $0.id)
                }
                hasMoreSocialNotifications = page.count > socialNotificationPageSize
            }

            do {
                unreadSocialNotificationCount = try await collaborationRepository
                    .unreadSocialNotificationCount()
            } catch {
                // Keep the last exhaustive badge rather than replacing it with
                // a count derived from only the loaded notification pages.
            }
        } catch {
            collaborationMessage = "Could not refresh social notifications."
        }
    }

    func loadMoreSocialNotifications() async {
        guard hasMoreSocialNotifications,
              !isRefreshingSocialNotifications,
              !isLoadingMoreSocialNotifications,
              let cursor = socialNotificationCursor else { return }
        isLoadingMoreSocialNotifications = true
        defer { isLoadingMoreSocialNotifications = false }

        do {
            let page = try await collaborationRepository.socialNotificationsPage(
                beforeCreatedAt: cursor.createdAt,
                beforeID: cursor.id,
                limit: socialNotificationPageSize + 1
            )
            let rawWindow = Array(page.prefix(socialNotificationPageSize))
            let existingIDs = Set(socialNotifications.map(\.id))
            socialNotifications.append(contentsOf: rawWindow.filter {
                !existingIDs.contains($0.id)
            })
            socialNotificationCursor = rawWindow.last.map {
                RemoteSocialNotificationCursor(createdAt: $0.createdAt, id: $0.id)
            } ?? socialNotificationCursor
            hasMoreSocialNotifications = page.count > socialNotificationPageSize
        } catch {
            collaborationMessage = "Could not load older notifications."
        }
    }

    @discardableResult
    func markSocialNotificationsRead(_ notificationID: UUID? = nil) async -> Bool {
#if DEBUG
        if isDiaryEditorUITestFixtureActive {
            let now = Date()
            socialNotifications = socialNotifications.map { notification in
                guard notification.readAt == nil,
                      notificationID == nil || notification.id == notificationID else {
                    return notification
                }
                return notification.markingRead(at: now)
            }
            unreadSocialNotificationCount = socialNotifications.lazy.filter { $0.readAt == nil }.count
            return true
        }
#endif
        do {
            try await collaborationRepository.markSocialNotificationsRead(notificationID)
            await refreshSocialNotifications()
            return true
        } catch {
            collaborationMessage = "Could not update social notifications."
            return false
        }
    }

    func resolveNotificationActor(_ actorID: UUID) async throws -> RemoteSocialProfile? {
#if DEBUG
        if isDiaryEditorUITestFixtureActive {
            let profile = socialProfiles.first(where: { $0.id == actorID })
            if profile != nil { publicProfileShelves.removeValue(forKey: actorID) }
            return profile
        }
#endif
        let profile = try await collaborationRepository.notificationActorProfile(id: actorID)
        if profile != nil {
            // Never render shelves retained from an authorization context that
            // predates this forced profile lookup.
            publicProfileShelves.removeValue(forKey: actorID)
        }
        return profile
    }

    func resolveNotificationReview(_ reviewID: UUID) async throws -> RemoteMusicReview? {
#if DEBUG
        if isDiaryEditorUITestFixtureActive {
            let review = review(withID: reviewID)
            if let review {
                reviewDetailsByID[reviewID] = review
                reviewEngagementDetails[reviewID] = ReviewDetailEngagementState()
            }
            return review
        }
#endif
        let review = try await collaborationRepository.notificationReview(id: reviewID)
        if let review {
            reviewDetailsByID[reviewID] = review
            reviewEngagementDetails[reviewID] = ReviewDetailEngagementState()
        }
        return review
    }

    func resolveNotificationMusicList(_ listID: UUID) async throws -> RemoteMusicList? {
#if DEBUG
        if isDiaryEditorUITestFixtureActive {
            let list = ownerMusicLists.first(where: { $0.id == listID })
                ?? musicListDetails[listID]?.list
            if let list { musicListDetails[listID] = MusicListDetailState(list: list) }
            return list
        }
#endif
        let list = try await collaborationRepository.notificationMusicList(id: listID)
        if let list {
            cacheMusicList(list)
            musicListDetails[listID] = MusicListDetailState(list: list)
        }
        return list
    }

    func resolveNotificationBroadcast(_ broadcastID: UUID) async throws -> EavesdropBroadcast? {
#if DEBUG
        if isDiaryEditorUITestFixtureActive {
            let broadcast = eavesdropDetails[broadcastID]?.broadcast
                ?? eavesdropFeed.first(where: { $0.id == broadcastID })
            return broadcast
        }
#endif
        var rows = try await collaborationRepository.eavesdropBroadcastSnapshotRows(
            broadcastID: broadcastID
        )
        if providerState(for: .spotify) == .connected {
            rows += (try? await collaborationRepository.eavesdropBroadcastSnapshotRows(
                broadcastID: broadcastID,
                viewerProvider: .spotify,
                storefront: "global"
            )) ?? []
        }
        if providerState(for: .appleMusic) == .connected {
            rows += (try? await collaborationRepository.eavesdropBroadcastSnapshotRows(
                broadcastID: broadcastID,
                viewerProvider: .appleMusic,
                storefront: "us"
            )) ?? []
        }
        let broadcast = mergedEavesdropBroadcasts(rows).first
        if let broadcast {
            eavesdropDetails[broadcastID] = EavesdropBroadcastDetailState(broadcast: broadcast)
        }
        return broadcast
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

    func outgoingSocialFollowState(with profileID: UUID) -> String? {
        guard let authenticatedProfileID else { return nil }
        return socialFollows.first {
            $0.followerID == authenticatedProfileID && $0.followedID == profileID
        }?.state
    }

    func incomingSocialFollowState(with profileID: UUID) -> String? {
        guard let authenticatedProfileID else { return nil }
        return socialFollows.first {
            $0.followerID == profileID && $0.followedID == authenticatedProfileID
        }?.state
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
            await refreshSocialDiscovery(search: socialDiscoveryQuery)
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

    func refreshOwnerReviews() async {
#if DEBUG
        guard !isDiaryEditorUITestFixtureActive else { return }
#endif
        guard !isRefreshingOwnerReviews, !isLoadingMoreOwnerReviews else { return }
        isRefreshingOwnerReviews = true
        defer { isRefreshingOwnerReviews = false }
        do {
            async let page = collaborationRepository.ownerReviewsPage(
                limit: socialShelfPageSize + 1
            )
            async let stats = collaborationRepository.ownerReviewStats()
            let values = try await (page, stats)
            ownerReviews = Array(values.0.prefix(socialShelfPageSize))
            hasMoreOwnerReviews = values.0.count > socialShelfPageSize
            ownerReviewStats = values.1
        } catch {
            collaborationMessage = "Could not refresh your review library."
        }
    }

    func loadMoreOwnerReviews() async {
        guard hasMoreOwnerReviews,
              !isRefreshingOwnerReviews,
              !isLoadingMoreOwnerReviews,
              let cursor = ownerReviews.last else { return }
        isLoadingMoreOwnerReviews = true
        defer { isLoadingMoreOwnerReviews = false }
        do {
            let page = try await collaborationRepository.ownerReviewsPage(
                beforeCreatedAt: cursor.createdAt,
                beforeID: cursor.id,
                limit: socialShelfPageSize + 1
            )
            let existingIDs = Set(ownerReviews.map(\.id))
            ownerReviews.append(contentsOf: page.prefix(socialShelfPageSize).filter {
                !existingIDs.contains($0.id)
            })
            hasMoreOwnerReviews = page.count > socialShelfPageSize
        } catch {
            collaborationMessage = "Could not load older reviews."
        }
    }

    func review(withID reviewID: UUID) -> RemoteMusicReview? {
        reviewDetailsByID[reviewID]
            ?? ownerReviews.first(where: { $0.id == reviewID })
            ?? musicReviews.first(where: { $0.id == reviewID })
    }

    func loadReview(withID reviewID: UUID) async -> RemoteMusicReview? {
        if let cached = review(withID: reviewID) { return cached }
        do {
            let loaded = try await collaborationRepository.musicReview(id: reviewID)
            reviewDetailsByID[reviewID] = loaded
            return loaded
        } catch {
            collaborationMessage = "This review is no longer available."
            return nil
        }
    }

    func reviewEngagementDetail(for reviewID: UUID) -> ReviewDetailEngagementState {
        reviewEngagementDetails[reviewID] ?? ReviewDetailEngagementState()
    }

    @discardableResult
    func refreshReviewDetail(_ reviewID: UUID) async -> Bool {
#if DEBUG
        if isDiaryEditorUITestFixtureActive {
            reviewEngagementDetails[reviewID] = reviewEngagementDetails[reviewID]
                ?? ReviewDetailEngagementState(
                    engagement: RemoteReviewEngagement(
                        heartCount: 0,
                        commentCount: 0,
                        viewerHasHearted: false
                    )
                )
            return review(withID: reviewID) != nil
        }
#endif
        var detail = reviewEngagementDetails[reviewID] ?? ReviewDetailEngagementState()
        guard !detail.isRefreshing else { return false }
        detail.isRefreshing = true
        reviewEngagementDetails[reviewID] = detail
        defer { reviewEngagementDetails[reviewID]?.isRefreshing = false }
        do {
            async let loadedReview = collaborationRepository.musicReview(id: reviewID)
            async let comments = collaborationRepository.reviewCommentsPage(
                reviewID: reviewID,
                limit: socialShelfPageSize + 1
            )
            async let engagement = collaborationRepository.reviewEngagement(reviewID)
            let values = try await (loadedReview, comments, engagement)
            reviewDetailsByID[reviewID] = values.0
            reviewEngagementDetails[reviewID]?.comments.items = Array(values.1.prefix(socialShelfPageSize))
            reviewEngagementDetails[reviewID]?.comments.hasMore = values.1.count > socialShelfPageSize
            reviewEngagementDetails[reviewID]?.engagement = values.2
            return true
        } catch {
            collaborationMessage = "Could not load this review: \(error.localizedDescription)"
            return false
        }
    }

    func refreshReviewComments(_ reviewID: UUID) async {
        var detail = reviewEngagementDetails[reviewID] ?? ReviewDetailEngagementState()
        guard !detail.comments.isRefreshing, !detail.comments.isLoadingMore else { return }
        detail.comments.isRefreshing = true
        reviewEngagementDetails[reviewID] = detail
        defer { reviewEngagementDetails[reviewID]?.comments.isRefreshing = false }
        do {
            let page = try await collaborationRepository.reviewCommentsPage(
                reviewID: reviewID,
                limit: socialShelfPageSize + 1
            )
            reviewEngagementDetails[reviewID]?.comments.items = Array(page.prefix(socialShelfPageSize))
            reviewEngagementDetails[reviewID]?.comments.hasMore = page.count > socialShelfPageSize
            await refreshReviewEngagement(reviewID)
        } catch {
            collaborationMessage = "Could not refresh review comments."
        }
    }

    func loadMoreReviewComments(_ reviewID: UUID) async {
        guard var detail = reviewEngagementDetails[reviewID],
              detail.comments.hasMore,
              !detail.comments.isRefreshing,
              !detail.comments.isLoadingMore,
              let cursor = detail.comments.items.last else { return }
        detail.comments.isLoadingMore = true
        reviewEngagementDetails[reviewID] = detail
        defer { reviewEngagementDetails[reviewID]?.comments.isLoadingMore = false }
        do {
            let page = try await collaborationRepository.reviewCommentsPage(
                reviewID: reviewID,
                beforeCreatedAt: cursor.createdAt,
                beforeID: cursor.id,
                limit: socialShelfPageSize + 1
            )
            let existingIDs = Set(detail.comments.items.map(\.id))
            reviewEngagementDetails[reviewID]?.comments.items.append(
                contentsOf: page.prefix(socialShelfPageSize)
                    .filter { !existingIDs.contains($0.id) }
            )
            reviewEngagementDetails[reviewID]?.comments.hasMore = page.count > socialShelfPageSize
        } catch {
            collaborationMessage = "Could not load older review comments."
        }
    }

    private func refreshReviewEngagement(_ reviewID: UUID) async {
        do {
            let engagement = try await collaborationRepository.reviewEngagement(reviewID)
            var detail = reviewEngagementDetails[reviewID] ?? ReviewDetailEngagementState()
            detail.engagement = engagement
            reviewEngagementDetails[reviewID] = detail
        } catch {
            // The review and loaded comments remain usable when a count refresh
            // races a visibility change or transient connection failure.
        }
    }

    private func refreshCachedReviewDetails() async {
        let reviewIDs = Array(reviewEngagementDetails.keys)
        for reviewID in reviewIDs {
            _ = await refreshReviewDetail(reviewID)
        }
    }

    @discardableResult
    func publishTrackReview(rating: Double?, body: String, isLoved: Bool = false, containsSpoilers: Bool = false, visibility: SocialVisibilityOption? = nil) async -> Bool {
        guard let track = nowPlaying?.track else { return false }
        return await publishTrackReview(track, rating: rating, body: body, isLoved: isLoved, containsSpoilers: containsSpoilers, visibility: visibility)
    }

    @discardableResult
    func publishTrackReview(
        _ track: HarmonyTrack,
        rating: Double?,
        body: String,
        isLoved: Bool = false,
        containsSpoilers: Bool = false,
        visibility: SocialVisibilityOption? = nil,
        diary: TrackReviewDiaryRequest? = nil
    ) async -> Bool {
        guard !isPublishingMusicReview else { return false }
        guard reviewContentIsValid(rating: rating, body: body) else {
            collaborationMessage = "Add a rating or write a review before saving."
            return false
        }
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
                containsSpoilers: containsSpoilers,
                diary: diary
            )
            collaborationMessage = resolvedVisibility == .followers
                ? (diary == nil ? "Review published to approved followers" : "Review published and Diary entry saved")
                : (diary == nil ? "Private review saved" : "Private review and Diary entry saved")
            await refreshMusicReviews()
            await refreshOwnerReviews()
            await refreshTrackSubjectShelf()
            if diary != nil {
                await refreshJournalEntries()
                await refreshListeningHistory()
                await refreshFollowingActivity()
            }
            return true
        } catch {
            collaborationMessage = "Could not publish review: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func publishAlbumReview(_ album: ReviewableAlbum, rating: Double?, body: String, isLoved: Bool = false, containsSpoilers: Bool = false, visibility: SocialVisibilityOption? = nil) async -> Bool {
        guard !isPublishingMusicReview else { return false }
        guard reviewContentIsValid(rating: rating, body: body) else {
            collaborationMessage = "Add a rating or write a review before saving."
            return false
        }
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
            await refreshOwnerReviews()
            await refreshAlbumSubjectShelf()
            return true
        } catch {
            collaborationMessage = "Could not publish album review: \(error.localizedDescription)"
            return false
        }
    }

    func toggleReviewHeart(_ reviewID: UUID) async {
        guard !mutatingReviewIDs.contains(reviewID) else { return }
        mutatingReviewIDs.insert(reviewID)
        defer { mutatingReviewIDs.remove(reviewID) }
        do {
            let added = try await collaborationRepository.toggleHeart(on: reviewID)
            collaborationMessage = added ? "Reaction added" : "Reaction removed"
            await refreshReviewEngagement(reviewID)
        } catch { collaborationMessage = "Could not update reaction: \(error.localizedDescription)" }
    }

    func isOwnReview(_ review: RemoteMusicReview) -> Bool { review.profileID == authenticatedProfileID }
    func isOwnComment(_ comment: RemoteReviewComment) -> Bool { comment.authorID == authenticatedProfileID }
    func canDeleteReviewComment(_ comment: RemoteReviewComment, from review: RemoteMusicReview) -> Bool {
        reviewCommentCanBeDeleted(
            commentAuthorID: comment.authorID,
            reviewOwnerID: review.profileID,
            viewerID: authenticatedProfileID
        )
    }
    func hasHeart(on reviewID: UUID) -> Bool {
        reviewEngagementDetails[reviewID]?.engagement?.viewerHasHearted ?? false
    }

    @discardableResult
    func addReviewComment(to reviewID: UUID, body: String) async -> Bool {
        let comment = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...2000).contains(comment.count) else {
            collaborationMessage = "Comments must contain 1 to 2,000 characters."
            return false
        }
        guard !mutatingReviewIDs.contains(reviewID) else { return false }
        mutatingReviewIDs.insert(reviewID)
        defer { mutatingReviewIDs.remove(reviewID) }
        do {
            try await collaborationRepository.addComment(to: reviewID, body: comment)
            collaborationMessage = "Comment added"
            await refreshReviewComments(reviewID)
            return true
        } catch {
            collaborationMessage = "Could not update review: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func deleteReviewComment(_ comment: RemoteReviewComment, from review: RemoteMusicReview) async -> Bool {
        guard canDeleteReviewComment(comment, from: review) else {
            collaborationMessage = "This comment could not be deleted."
            return false
        }
        guard !mutatingReviewIDs.contains(review.id) else { return false }
        mutatingReviewIDs.insert(review.id)
        defer { mutatingReviewIDs.remove(review.id) }
        do {
            try await collaborationRepository.deleteComment(comment.id)
            collaborationMessage = "Comment deleted"
            await refreshReviewComments(review.id)
            return true
        } catch {
            collaborationMessage = "Could not update review: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func updateReview(_ reviewID: UUID, rating: Double?, body: String, visibility: SocialVisibilityOption, isLoved: Bool, containsSpoilers: Bool = false) async -> Bool {
        guard reviewContentIsValid(rating: rating, body: body) else {
            collaborationMessage = "Add a rating or write a review before saving."
            return false
        }
        let updatesTrackState = review(withID: reviewID).map {
            $0.id == reviewID && $0.subjectKind == "track" && $0.canonicalTrack?.id != nil
        } ?? false
        let didUpdate = await performReviewMutation(reviewID, successMessage: "Review updated") {
            try await self.collaborationRepository.updateReview(
                reviewID,
                rating: rating,
                body: body,
                visibility: visibility,
                isLoved: isLoved,
                containsSpoilers: containsSpoilers
            )
        }
        if didUpdate && updatesTrackState { await refreshTrackSubjectShelf() }
        return didUpdate
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
        let affectedAlbum = review(withID: reviewID)?.canonicalAlbum
        guard !mutatingReviewIDs.contains(reviewID) else { return false }
        mutatingReviewIDs.insert(reviewID)
        defer { mutatingReviewIDs.remove(reviewID) }
        do {
            try await operation()
            collaborationMessage = successMessage
            await refreshMusicReviews()
            await refreshOwnerReviews()
            if reviewDetailsByID[reviewID] != nil {
                if let refreshed = try? await collaborationRepository.musicReview(id: reviewID) {
                    reviewDetailsByID[reviewID] = refreshed
                } else {
                    reviewDetailsByID.removeValue(forKey: reviewID)
                    reviewEngagementDetails.removeValue(forKey: reviewID)
                }
            }
            if let affectedAlbum {
                _ = await refreshAlbumSubjectState(for: affectedAlbum)
                await refreshCanonicalAlbumDetail(affectedAlbum)
            }
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
                let track = HarmonyTrack(
                    id: remote.canonicalTrack.id ?? UUID(),
                    canonicalTrackID: remote.canonicalTrack.id,
                    title: remote.canonicalTrack.title,
                    artist: remote.canonicalTrack.artist,
                    album: remote.canonicalTrack.album ?? "",
                    duration: TimeInterval(remote.canonicalTrack.durationMilliseconds ?? 0) / 1000,
                    symbol: "music.note",
                    artworkURL: remote.canonicalTrack.artworkURL,
                    isExplicit: remote.canonicalTrack.isExplicit,
                    isrc: remote.canonicalTrack.isrc,
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
            storefront: remote.storefront,
            availability: availability,
            deepLinkURL: remote.deepLink
        )
    }

    private static func harmonyTrack(_ result: SpotifySearchTrack) -> HarmonyTrack {
        HarmonyTrack(
            canonicalTrackID: result.canonicalTrackID,
            title: result.title,
            artist: result.artist,
            album: result.album,
            duration: TimeInterval(result.durationMilliseconds) / 1000,
            symbol: "music.note",
            artworkURL: result.artworkURL,
            isExplicit: result.isExplicit,
            isrc: result.isrc,
            mappings: [ProviderTrackMapping(
                provider: .spotify,
                providerID: result.providerID,
                storefront: "global",
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
                canonicalTrackID: existing.canonicalTrackID ?? track.canonicalTrackID,
                title: existing.title,
                artist: existing.artist,
                album: existing.album,
                duration: existing.duration,
                symbol: existing.symbol,
                artworkURL: existing.artworkURL ?? track.artworkURL,
                isExplicit: existing.isExplicit || track.isExplicit,
                isrc: existing.isrc ?? track.isrc,
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
        if let lhsCanonical = lhs.canonicalTrackID, let rhsCanonical = rhs.canonicalTrackID {
            return lhsCanonical == rhsCanonical
        }
        if lhs.id == rhs.id { return true }
        let lhsProviderIDs = Set(lhs.mappings.filter { !$0.providerID.isEmpty }.map { "\($0.provider.rawValue):\($0.providerID)" })
        let rhsProviderIDs = Set(rhs.mappings.filter { !$0.providerID.isEmpty }.map { "\($0.provider.rawValue):\($0.providerID)" })
        if !lhsProviderIDs.isDisjoint(with: rhsProviderIDs) { return true }
        if let lhsISRC = normalizedISRC(lhs.isrc), let rhsISRC = normalizedISRC(rhs.isrc) {
            return lhsISRC == rhsISRC
        }
        let lhsAlbum = normalizedIdentityText(lhs.album)
        let rhsAlbum = normalizedIdentityText(rhs.album)
        guard !lhsAlbum.isEmpty, !rhsAlbum.isEmpty, lhs.duration > 0, rhs.duration > 0 else { return false }
        return normalizedIdentityText(lhs.title) == normalizedIdentityText(rhs.title)
            && normalizedIdentityText(lhs.artist) == normalizedIdentityText(rhs.artist)
            && lhsAlbum == rhsAlbum
            && abs(lhs.duration - rhs.duration) <= 2
    }

    private static func normalizedIdentityText(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }

    private static func normalizedISRC(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.uppercased().filter { $0 != "-" && !$0.isWhitespace }
        return normalized.isEmpty ? nil : normalized
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
