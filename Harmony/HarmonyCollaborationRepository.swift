import Foundation
import Supabase

private enum HarmonyRepositoryError: LocalizedError {
    case invalidCanonicalAlbumAggregate
    case canonicalAlbumUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidCanonicalAlbumAggregate:
            "The album rating summary was unavailable."
        case .canonicalAlbumUnavailable:
            "Harmony could not load this canonical album."
        }
    }
}

struct RemoteHarmonySession: Decodable {
    let id: UUID
    let title: String
    let inviteCode: String
    let queueRevision: Int
    let playbackState: RemotePlaybackState?
    let endedAt: Date?
    let expiresAt: Date?
    let allowCollaboratorInvites: Bool
    let playbackMode: SessionPlaybackMode

    enum CodingKeys: String, CodingKey {
        case id, title
        case inviteCode = "invite_code"
        case queueRevision = "queue_revision"
        case playbackState = "playback_state"
        case endedAt = "ended_at"
        case expiresAt = "expires_at"
        case allowCollaboratorInvites = "allow_collaborator_invites"
        case playbackMode = "playback_mode"
    }
}

struct RemotePlaybackState: Decodable {
    let status: String?
}

private struct CreateSessionParameters: Encodable {
    let p_title: String
    let p_invite_code: String
    let p_playback_mode: String
    let p_allow_collaborator_invites: Bool
    let p_expires_at: Date?
}

private struct UpdateInvitePermissionParameters: Encodable {
    let p_session_id: UUID
    let p_allow_collaborator_invites: Bool
}

private struct QueueCommandParameters<Payload: Encodable>: Encodable {
    let p_session_id: UUID
    let p_command_id: UUID
    let p_expected_revision: Int
    let p_type: String
    let p_payload: Payload
}

private struct AddPayload: Encodable { let canonical_track_id: UUID }
private struct ResolveCanonicalTrackParameters: Encodable {
    let p_provider: String
    let p_provider_id: String
    let p_title: String
    let p_artist: String
    let p_album: String?
    let p_duration_ms: Int?
    let p_artwork_url: String?
    let p_is_explicit: Bool
    let p_deep_link: String?
    let p_isrc: String?
    let p_storefront: String
}
private struct PublishListeningPresenceParameters: Encodable {
    let p_canonical_track_id: UUID
    let p_provider: String?
    let p_provider_track_id: String?
    let p_provider_deep_link: String?
    let p_status = "listening"
    let p_visibility: String
    let p_started_at: Date
    let p_expires_at: Date
}
private struct CreateTrackReviewParameters: Encodable {
    let p_subject_kind = "track"
    let p_canonical_track_id: UUID
    let p_provider: String?
    let p_provider_subject_id: String?
    let p_rating: Double
    let p_body: String
    let p_visibility: String
    let p_contains_spoilers: Bool
    let p_is_loved: Bool
}
private struct CreateAlbumReviewParameters: Encodable {
    let p_subject_kind = "album"
    let p_canonical_track_id: UUID? = nil
    let p_provider: String
    let p_provider_subject_id: String
    let p_subject_title: String
    let p_subject_artist: String
    let p_subject_artwork_url: String?
    let p_subject_deep_link: String?
    let p_rating: Double
    let p_body: String
    let p_visibility: String
    let p_contains_spoilers: Bool
    let p_is_loved: Bool
}
private struct CreateCanonicalAlbumReviewParameters: Encodable {
    let p_subject_kind = "album"
    let p_canonical_track_id: UUID? = nil
    let p_provider: String
    let p_provider_subject_id: String
    let p_subject_title: String
    let p_subject_artist: String
    let p_subject_artwork_url: String?
    let p_subject_deep_link: String?
    let p_rating: Double
    let p_body: String
    let p_visibility: String
    let p_contains_spoilers: Bool
    let p_is_loved: Bool
    let p_canonical_album_id: UUID?
    let p_provider_storefront: String
    let p_album_upc: String? = nil
    let p_album_release_date: String? = nil
    let p_album_total_tracks: Int? = nil
    let p_album_type: String? = nil
}
private struct ReviewReactionParameters: Encodable { let p_review_id: UUID; let p_kind = "heart" }
private struct ReviewCommentParameters: Encodable { let p_review_id: UUID; let p_body: String }
private struct ReviewIDParameters: Encodable { let p_review_id: UUID }
private struct CommentIDParameters: Encodable { let p_comment_id: UUID }
private struct NotificationIDParameters: Encodable { let p_notification_id: UUID? }
private struct UpdateReviewParameters: Encodable {
    let p_review_id: UUID
    let p_rating: Double
    let p_body: String
    let p_visibility: String
    let p_contains_spoilers: Bool
    let p_is_loved: Bool
}
private struct SocialProfileParameters: Encodable { let p_profile_id: UUID }
private struct RespondToFollowParameters: Encodable { let p_requester_id: UUID; let p_accept: Bool }
private struct UpdateAccountProfile: Encodable { let display_name: String }
private struct UpdateSocialSettings: Encodable {
    let live_visibility: String
    let history_visibility: String
    let reviews_visibility: String
    let shelf_visibility: String
    let record_harmony_plays: Bool
}
private struct RecordListeningHistoryParameters: Encodable {
    let p_canonical_track_id: UUID
    let p_provider: String?
    let p_provider_track_id: String?
    let p_played_at: Date
    let p_source: String
    let p_visibility: String
    let p_is_relisten: Bool
    let p_tags: [String]
    let p_rating: Double?
}
private struct UpdateListeningDiaryEntryParameters: Encodable {
    let p_entry_id: UUID
    let p_played_at: Date
    let p_visibility: String
    let p_is_relisten: Bool
    let p_tags: [String]
    let p_review_id: UUID?
    let p_rating: Double?
}
private struct SetTrackSubjectStateParameters: Encodable {
    let p_canonical_track_id: UUID
    let p_has_listened: Bool
    let p_default_rating: Double?
    let p_is_loved: Bool
    let p_want_to_listen: Bool
}
private struct ListeningDiaryPageParameters: Encodable {
    let p_before_played_at: Date?
    let p_before_id: UUID?
    let p_limit: Int
}
private struct TrackSubjectStatePageParameters: Encodable {
    let p_before_updated_at: Date?
    let p_before_canonical_track_id: UUID?
    let p_limit: Int
}
private struct SetAlbumSubjectStateParameters: Encodable {
    let p_canonical_album_id: UUID
    let p_has_listened: Bool
    let p_default_rating: Double?
    let p_is_loved: Bool
    let p_want_to_listen: Bool
}
private struct AlbumSubjectStatePageParameters: Encodable {
    let p_before_updated_at: Date?
    let p_before_canonical_album_id: UUID?
    let p_limit: Int
    let p_scope: String
}
private struct CanonicalAlbumIDParameters: Encodable {
    let p_canonical_album_id: UUID
}
private struct CanonicalAlbumReviewsPageParameters: Encodable {
    let p_canonical_album_id: UUID
    let p_before_created_at: Date?
    let p_before_id: UUID?
    let p_limit: Int
}
private struct ResolveCanonicalAlbumParameters: Encodable {
    let p_provider: String
    let p_provider_id: String
    let p_title: String
    let p_artist: String
    let p_artwork_url: String?
    let p_deep_link: String?
    let p_upc: String? = nil
    let p_release_date: String? = nil
    let p_total_tracks: Int? = nil
    let p_album_type: String? = nil
    let p_storefront: String
}
private struct FollowingActivityPageParameters: Encodable {
    let p_before_published_at: Date?
    let p_before_id: UUID?
    let p_limit: Int
}
private struct ProfileReviewsPageParameters: Encodable {
    let p_profile_id: UUID
    let p_before_created_at: Date?
    let p_before_id: UUID?
    let p_limit: Int
}
private struct ProfileDiaryPageParameters: Encodable {
    let p_profile_id: UUID
    let p_before_played_at: Date?
    let p_before_id: UUID?
    let p_limit: Int
}
private struct ProfileLovedPageParameters: Encodable {
    let p_profile_id: UUID
    let p_before_updated_at: Date?
    let p_before_canonical_track_id: UUID?
    let p_limit: Int
}
private struct ProfileMusicListsPageParameters: Encodable {
    let p_profile_id: UUID
    let p_before_updated_at: Date?
    let p_before_id: UUID?
    let p_limit: Int
}
private struct MusicListEntriesPageParameters: Encodable {
    let p_list_id: UUID
    let p_after_position: Int?
    let p_limit: Int
}
private struct CreateMusicListParameters: Encodable {
    let p_title: String
    let p_description: String
    let p_tags: [String]
    let p_is_ranked: Bool
    let p_visibility: String
}
private struct UpdateMusicListParameters: Encodable {
    let p_list_id: UUID
    let p_title: String
    let p_description: String
    let p_tags: [String]
    let p_is_ranked: Bool
    let p_visibility: String
}
private struct SaveMusicListParameters: Encodable {
    let p_list_id: UUID?
    let p_title: String
    let p_description: String
    let p_tags: [String]
    let p_is_ranked: Bool
    let p_visibility: String
    let p_entries: [MusicListDraftEntryPayload]
    let p_expected_revision: Int?
}
private struct MusicListIDParameters: Encodable { let p_list_id: UUID }
private struct AddMusicListEntryParameters: Encodable {
    let p_list_id: UUID
    let p_canonical_track_id: UUID
    let p_note: String
    let p_expected_revision: Int
}
private struct MusicListEntryRevisionParameters: Encodable {
    let p_entry_id: UUID
    let p_expected_revision: Int
}
private struct UpdateMusicListEntryNoteParameters: Encodable {
    let p_entry_id: UUID
    let p_note: String
    let p_expected_revision: Int
}
private struct ReorderMusicListEntriesParameters: Encodable {
    let p_list_id: UUID
    let p_ordered_entry_ids: [UUID]
    let p_expected_revision: Int
}
private struct SetMusicListLikedParameters: Encodable {
    let p_list_id: UUID
    let p_is_liked: Bool
}
private struct MusicListCommentsPageParameters: Encodable {
    let p_list_id: UUID
    let p_before_created_at: Date?
    let p_before_id: UUID?
    let p_limit: Int
}
private struct AddMusicListCommentParameters: Encodable {
    let p_list_id: UUID
    let p_body: String
}
private struct MusicListCommentIDParameters: Encodable { let p_comment_id: UUID }
private struct HistoryEntryIDParameters: Encodable { let p_entry_id: UUID }
private struct RemovePayload: Encodable { let queue_item_id: UUID }
private struct MovePayload: Encodable { let queue_item_id: UUID; let position: Double }
private struct PlaybackPayload: Encodable { let status: String }
private struct SkipQueueParameters: Encodable {
    let p_session_id: UUID
    let p_command_id: UUID
    let p_expected_revision: Int
}
private struct RemoteTrackID: Decodable { let id: UUID }
private struct QueueCommandResult: Decodable { let status: String; let revision: Int }
private struct SpotifyTokenExchangeParameters: Encodable { let code: String; let codeVerifier: String; let redirectURI: String }
private struct RemotePresence: Codable { let profileID: UUID }

struct RemoteQueueSnapshot: Decodable {
    let id: UUID
    let position: Double
    let addedBy: UUID
    let canonicalTrack: RemoteCatalogTrack

    enum CodingKeys: String, CodingKey {
        case id, position
        case addedBy = "added_by"
        case canonicalTrack = "canonical_tracks"
    }
}

struct RemoteSessionMember: Decodable {
    let profileID: UUID
    let role: String
    let profile: RemoteProfile
    enum CodingKeys: String, CodingKey { case profileID = "profile_id"; case role; case profile = "profiles" }
}

struct RemoteProfile: Codable { let displayName: String; enum CodingKeys: String, CodingKey { case displayName = "display_name" } }

enum SocialVisibilityOption: String, CaseIterable, Codable, Identifiable {
    case privateOnly = "private"
    case followers

    var id: String { rawValue }
    var title: String { self == .privateOnly ? "Only me" : "Followers" }
}

struct RemoteAccountProfile: Decodable {
    let id: UUID
    let displayName: String
    enum CodingKeys: String, CodingKey { case id; case displayName = "display_name" }
}

struct RemoteSocialSettings: Decodable {
    let profileID: UUID
    let liveVisibility: SocialVisibilityOption
    let historyVisibility: SocialVisibilityOption
    let reviewsVisibility: SocialVisibilityOption
    let shelfVisibility: SocialVisibilityOption
    let recordHarmonyPlays: Bool
    enum CodingKeys: String, CodingKey {
        case profileID = "profile_id"
        case liveVisibility = "live_visibility"
        case historyVisibility = "history_visibility"
        case reviewsVisibility = "reviews_visibility"
        case shelfVisibility = "shelf_visibility"
        case recordHarmonyPlays = "record_harmony_plays"
    }
}

private struct RemoteSocialActivityEvent: Decodable, Identifiable {
    let id: UUID
    let actorID: UUID
    let kind: String
    let diaryEntryID: UUID?
    let reviewID: UUID?
    let listID: UUID?
    let publishedAt: Date
    let actor: RemoteProfile

    enum CodingKeys: String, CodingKey {
        case id, kind, actor
        case actorID = "actor_id"
        case diaryEntryID = "diary_entry_id"
        case reviewID = "review_id"
        case listID = "list_id"
        case publishedAt = "published_at"
    }
}

enum RemoteFollowingActivityPayload {
    case diary(RemoteListeningHistoryEntry)
    case review(RemoteMusicReview)
    case musicList(RemoteMusicList)
}

struct RemoteFollowingActivityItem: Identifiable {
    let id: UUID
    let actorID: UUID
    let publishedAt: Date
    let actor: RemoteProfile
    let payload: RemoteFollowingActivityPayload
}

struct RemoteFollowingActivityCursor {
    let publishedAt: Date
    let id: UUID
}

struct RemoteFollowingActivityPage {
    let items: [RemoteFollowingActivityItem]
    let cursor: RemoteFollowingActivityCursor?
    let hasMore: Bool
}

struct RemoteSocialProfile: Decodable, Identifiable {
    let id: UUID
    let displayName: String
    enum CodingKeys: String, CodingKey { case id; case displayName = "display_name" }
}

struct RemoteSocialFollow: Decodable, Identifiable {
    let followerID: UUID
    let followedID: UUID
    let state: String
    var id: String { "\(followerID.uuidString):\(followedID.uuidString)" }
    enum CodingKeys: String, CodingKey {
        case state
        case followerID = "follower_id"
        case followedID = "followed_id"
    }
}

struct RemoteSocialBlock: Decodable {
    let blockedID: UUID
    enum CodingKeys: String, CodingKey { case blockedID = "blocked_id" }
}

struct RemoteNotificationReview: Decodable {
    let subjectTitle: String?
    let canonicalTrack: RemoteCatalogTrack?
    enum CodingKeys: String, CodingKey {
        case subjectTitle = "subject_title"
        case canonicalTrack = "canonical_tracks"
    }
}

struct RemoteNotificationMusicList: Decodable {
    let title: String
}

struct RemoteSocialNotification: Decodable, Identifiable {
    let id: UUID
    let kind: String
    let createdAt: Date
    let readAt: Date?
    let actor: RemoteProfile
    let review: RemoteNotificationReview?
    let musicList: RemoteNotificationMusicList?
    enum CodingKeys: String, CodingKey {
        case id, kind, actor, review
        case musicList = "music_list"
        case createdAt = "created_at"
        case readAt = "read_at"
    }
}

struct RemoteCatalogTrack: Codable {
    let id: UUID?
    let title: String
    let artist: String
    let album: String?
    let durationMilliseconds: Int?
    let artworkURL: URL?
    let isExplicit: Bool
    let isrc: String?
    let providerTracks: [RemoteProviderTrack]?

    init(
        id: UUID?,
        title: String,
        artist: String,
        album: String?,
        durationMilliseconds: Int?,
        artworkURL: URL?,
        isExplicit: Bool,
        isrc: String? = nil,
        providerTracks: [RemoteProviderTrack]?
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMilliseconds = durationMilliseconds
        self.artworkURL = artworkURL
        self.isExplicit = isExplicit
        self.isrc = isrc
        self.providerTracks = providerTracks
    }

    enum CodingKeys: String, CodingKey {
        case id, title, artist, album, isrc
        case durationMilliseconds = "duration_ms"
        case artworkURL = "artwork_url"
        case isExplicit = "is_explicit"
        case providerTracks = "provider_tracks"
    }
}

struct RemoteProviderTrack: Codable {
    let provider: String
    let providerID: String
    let storefront: String?
    let availability: String
    let deepLink: URL?
    enum CodingKeys: String, CodingKey {
        case provider, storefront, availability
        case providerID = "provider_id"
        case deepLink = "deep_link"
    }
}

struct RemoteProviderConnection: Decodable {
    let provider: String
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case provider
        case expiresAt = "expires_at"
    }
}

struct RemoteListeningPresence: Decodable, Identifiable {
    let profileID: UUID
    let status: String
    let provider: String?
    let providerDeepLink: URL?
    let startedAt: Date
    let expiresAt: Date
    let canonicalTrack: RemoteCatalogTrack?
    let profile: RemoteProfile

    var id: UUID { profileID }
    enum CodingKeys: String, CodingKey {
        case status, provider
        case profileID = "profile_id"
        case providerDeepLink = "provider_deep_link"
        case startedAt = "started_at"
        case expiresAt = "expires_at"
        case canonicalTrack = "canonical_tracks"
        case profile = "profiles"
    }
}

struct RemoteListeningHistoryEntry: Decodable, Identifiable {
    let id: UUID
    let profileID: UUID
    let playedAt: Date
    let source: String
    let visibility: SocialVisibilityOption
    let isRelisten: Bool
    let tags: [String]
    let reviewID: UUID?
    let rating: Double?
    let canonicalTrack: RemoteCatalogTrack?
    let profile: RemoteProfile
    enum CodingKeys: String, CodingKey {
        case id, source, visibility, tags, rating
        case reviewID = "review_id"
        case profileID = "profile_id"
        case playedAt = "played_at"
        case isRelisten = "is_relisten"
        case canonicalTrack = "canonical_tracks"
        case profile = "profiles"
    }

    init(
        id: UUID,
        profileID: UUID,
        playedAt: Date,
        source: String,
        visibility: SocialVisibilityOption,
        isRelisten: Bool,
        tags: [String],
        rating: Double? = nil,
        reviewID: UUID?,
        canonicalTrack: RemoteCatalogTrack?,
        profile: RemoteProfile
    ) {
        self.id = id
        self.profileID = profileID
        self.playedAt = playedAt
        self.source = source
        self.visibility = visibility
        self.isRelisten = isRelisten
        self.tags = tags
        self.rating = rating
        self.reviewID = reviewID
        self.canonicalTrack = canonicalTrack
        self.profile = profile
    }
}

struct RemoteTrackSubjectState: Decodable, Identifiable {
    let profileID: UUID
    let canonicalTrackID: UUID
    let hasListened: Bool
    let defaultRating: Double?
    let isLoved: Bool
    let wantToListen: Bool
    let createdAt: Date
    let updatedAt: Date
    let canonicalTrack: RemoteCatalogTrack?

    var id: UUID { canonicalTrackID }

    enum CodingKeys: String, CodingKey {
        case profileID = "profile_id"
        case canonicalTrackID = "canonical_track_id"
        case hasListened = "has_listened"
        case defaultRating = "default_rating"
        case isLoved = "is_loved"
        case wantToListen = "want_to_listen"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case canonicalTrack = "canonical_tracks"
    }

    func preservingCanonicalTrack(_ fallback: RemoteCatalogTrack?) -> RemoteTrackSubjectState {
        RemoteTrackSubjectState(
            profileID: profileID,
            canonicalTrackID: canonicalTrackID,
            hasListened: hasListened,
            defaultRating: defaultRating,
            isLoved: isLoved,
            wantToListen: wantToListen,
            createdAt: createdAt,
            updatedAt: updatedAt,
            canonicalTrack: canonicalTrack ?? fallback
        )
    }
}

struct RemoteAlbumSubjectState: Decodable, Identifiable {
    let profileID: UUID
    let canonicalAlbumID: UUID
    let hasListened: Bool
    let defaultRating: Double?
    let isLoved: Bool
    let wantToListen: Bool
    let createdAt: Date
    let updatedAt: Date
    let canonicalAlbum: RemoteCanonicalAlbum?

    var id: UUID { canonicalAlbumID }

    enum CodingKeys: String, CodingKey {
        case profileID = "profile_id"
        case canonicalAlbumID = "canonical_album_id"
        case hasListened = "has_listened"
        case defaultRating = "default_rating"
        case isLoved = "is_loved"
        case wantToListen = "want_to_listen"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case canonicalAlbum = "canonical_albums"
    }

    func preservingCanonicalAlbum(_ fallback: RemoteCanonicalAlbum?) -> RemoteAlbumSubjectState {
        RemoteAlbumSubjectState(
            profileID: profileID,
            canonicalAlbumID: canonicalAlbumID,
            hasListened: hasListened,
            defaultRating: defaultRating,
            isLoved: isLoved,
            wantToListen: wantToListen,
            createdAt: createdAt,
            updatedAt: updatedAt,
            canonicalAlbum: canonicalAlbum ?? fallback
        )
    }
}

struct RemotePublicLovedTrack: Decodable, Identifiable {
    let profileID: UUID
    let canonicalTrackID: UUID
    let updatedAt: Date
    let canonicalTrack: RemoteCatalogTrack?

    var id: UUID { canonicalTrackID }

    enum CodingKeys: String, CodingKey {
        case profileID = "profile_id"
        case canonicalTrackID = "canonical_track_id"
        case updatedAt = "updated_at"
        case canonicalTrack = "canonical_tracks"
    }
}

struct RemoteMusicReview: Decodable, Identifiable {
    let id: UUID
    let profileID: UUID
    let rating: Double
    let body: String
    let createdAt: Date
    let visibility: SocialVisibilityOption
    let containsSpoilers: Bool
    let isLoved: Bool
    let subjectKind: String
    let subjectTitle: String?
    let subjectArtist: String?
    let subjectArtworkURL: URL?
    let subjectDeepLink: URL?
    let canonicalAlbumID: UUID?
    let canonicalTrack: RemoteCatalogTrack?
    let canonicalAlbum: RemoteCanonicalAlbum?
    let profile: RemoteProfile
    let comments: [RemoteReviewComment]
    let reactions: [RemoteReviewReaction]
    enum CodingKeys: String, CodingKey {
        case id, rating, body, visibility
        case containsSpoilers = "contains_spoilers"
        case isLoved = "is_loved"
        case subjectKind = "subject_kind"
        case subjectTitle = "subject_title"
        case subjectArtist = "subject_artist"
        case subjectArtworkURL = "subject_artwork_url"
        case subjectDeepLink = "subject_deep_link"
        case canonicalAlbumID = "canonical_album_id"
        case profileID = "profile_id"
        case createdAt = "created_at"
        case canonicalTrack = "canonical_tracks"
        case canonicalAlbum = "canonical_albums"
        case profile = "profiles"
        case comments = "review_comments"
        case reactions = "review_reactions"
    }
}

struct RemoteCanonicalAlbum: Decodable, Identifiable {
    let id: UUID
    let title: String
    let artist: String?
    let releaseDate: String?
    let upc: String?
    let albumType: String?
    let totalTracks: Int?
    let artworkURL: URL?
    let providerAlbums: [RemoteProviderAlbum]

    enum CodingKeys: String, CodingKey {
        case id, title, artist, upc
        case releaseDate = "release_date"
        case albumType = "album_type"
        case totalTracks = "total_tracks"
        case artworkURL = "artwork_url"
        case providerAlbums = "provider_albums"
    }
}

struct RemoteProviderAlbum: Decodable, Identifiable {
    let provider: String
    let providerAlbumID: String
    let storefront: String
    let deepLink: URL?
    let availability: String
    let identityBasis: String

    var id: String { "\(provider):\(providerAlbumID):\(storefront)" }

    enum CodingKeys: String, CodingKey {
        case provider, storefront, availability
        case providerAlbumID = "provider_album_id"
        case deepLink = "deep_link"
        case identityBasis = "identity_basis"
    }
}

struct RemoteCanonicalAlbumStateAggregate: Decodable, Equatable {
    let canonicalAlbumID: UUID
    let ratingCount: Int
    let averageRating: Double?
    let listenedCount: Int
    let lovedCount: Int
    let wantToListenCount: Int

    enum CodingKeys: String, CodingKey {
        case canonicalAlbumID = "canonical_album_id"
        case ratingCount = "rating_count"
        case averageRating = "average_rating"
        case listenedCount = "listened_count"
        case lovedCount = "loved_count"
        case wantToListenCount = "want_to_listen_count"
    }
}

struct RemoteCanonicalAlbumRatingBucket: Decodable, Equatable, Identifiable {
    let rating: Double
    let ratingCount: Int
    var id: Double { rating }

    enum CodingKeys: String, CodingKey {
        case rating
        case ratingCount = "rating_count"
    }
}

struct RemoteReviewComment: Decodable, Identifiable {
    let id: UUID
    let authorID: UUID
    let body: String
    let createdAt: Date
    let profile: RemoteProfile
    enum CodingKeys: String, CodingKey {
        case id, body
        case authorID = "author_id"
        case createdAt = "created_at"
        case profile = "profiles"
    }
}

struct RemoteReviewReaction: Decodable {
    let profileID: UUID
    let kind: String
    enum CodingKeys: String, CodingKey { case profileID = "profile_id"; case kind }
}

/// An owner-authored, ordered collection of canonical tracks. Entry rows are
/// loaded independently so list indexes stay compact and can paginate without
/// exposing private child counts through an unrelated query.
struct RemoteMusicList: Codable, Identifiable {
    let id: UUID
    let ownerID: UUID
    let title: String
    let description: String
    let tags: [String]
    let isRanked: Bool
    let visibility: SocialVisibilityOption
    let entriesRevision: Int
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?
    let owner: RemoteProfile

    enum CodingKeys: String, CodingKey {
        case id, title, description, tags, visibility, owner
        case ownerID = "owner_id"
        case isRanked = "is_ranked"
        case entriesRevision = "entries_revision"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

struct RemoteMusicListEntry: Codable, Identifiable {
    let id: UUID
    let listID: UUID
    let canonicalTrackID: UUID
    let position: Int
    let note: String
    let createdAt: Date
    let updatedAt: Date
    /// Present on paginated reads that request the canonical relationship.
    /// Mutation RPCs return the newly written base row in their JSON envelope,
    /// so that response legitimately omits the embedded track.
    let canonicalTrack: RemoteCatalogTrack?

    enum CodingKeys: String, CodingKey {
        case id, position, note
        case listID = "list_id"
        case canonicalTrackID = "canonical_track_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case canonicalTrack = "canonical_tracks"
    }
}

struct RemoteMusicListEntryMutation: Codable {
    let entry: RemoteMusicListEntry
    let entriesRevision: Int

    enum CodingKeys: String, CodingKey {
        case entry
        case entriesRevision = "entries_revision"
    }
}

struct RemoteMusicListEngagement: Codable, Equatable {
    let entryCount: Int
    let likeCount: Int
    let commentCount: Int
    let viewerHasLiked: Bool

    enum CodingKeys: String, CodingKey {
        case entryCount = "entry_count"
        case likeCount = "like_count"
        case commentCount = "comment_count"
        case viewerHasLiked = "viewer_has_liked"
    }
}

/// The exact ordered-entry JSON accepted by `save_music_list`. Array order is
/// authoritative; positions are assigned and validated transactionally.
private struct MusicListDraftEntryPayload: Encodable {
    let canonicalTrackID: UUID
    let note: String

    enum CodingKeys: String, CodingKey {
        case canonicalTrackID = "canonical_track_id"
        case note
    }
}

struct RemoteMusicListComment: Codable, Identifiable {
    let id: UUID
    let listID: UUID
    let authorID: UUID
    let body: String
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?
    let author: RemoteProfile

    enum CodingKeys: String, CodingKey {
        case id, body, author
        case listID = "list_id"
        case authorID = "author_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

struct SpotifyAccessCredential: Decodable {
    let accessToken: String
    let expiresAt: String
    let scopes: [String]
}

private struct SpotifyDisconnectResponse: Decodable { let disconnected: Bool }
private struct DeleteAccountResponse: Decodable { let deleted: Bool }
private struct SpotifySearchParameters: Encodable { let query: String }
private struct SpotifySearchResponse: Decodable { let tracks: [SpotifySearchTrack] }
private struct EdgeFunctionErrorResponse: Decodable {
    let error: String
    let upstreamStatus: Int?
}
struct SpotifyHistoryImportResponse: Decodable { let imported: Int; let skipped: Int }
struct SpotifyNowListeningResponse: Decodable {
    let published: Bool
    let reason: String?
    let title: String?
    let artist: String?
    let isPlaying: Bool?
}
enum SpotifyHistoryImportError: LocalizedError {
    case reconnectRequired
    case rateLimited
    case unavailable

    var errorDescription: String? {
        switch self {
        case .reconnectRequired: return "Reconnect Spotify to approve recent-listening access."
        case .rateLimited: return "Spotify is rate limiting history imports. Try again shortly."
        case .unavailable: return "Spotify listening history is temporarily unavailable."
        }
    }
}
enum SpotifyNowListeningError: LocalizedError {
    case reconnectRequired
    case rateLimited
    case unavailable

    var errorDescription: String? {
        switch self {
        case .reconnectRequired: return "Reconnect Spotify to approve playback access."
        case .rateLimited: return "Spotify is rate limiting playback checks. Try again shortly."
        case .unavailable: return "Spotify playback activity is temporarily unavailable."
        }
    }
}
struct SpotifySearchTrack: Decodable {
    let title: String
    let artist: String
    let album: String
    let durationMilliseconds: Int
    let artworkURL: URL?
    let providerID: String
    let deepLinkURL: URL?
    let isExplicit: Bool
    let isrc: String?
    let canonicalTrackID: UUID?
    let albumProviderID: String
    let albumArtist: String
    let albumDeepLinkURL: URL?
}

@MainActor
final class HarmonyCollaborationRepository {
    private static let musicListSelection = "id,owner_id,title,description,tags,is_ranked,visibility,entries_revision,created_at,updated_at,deleted_at,owner:profiles!music_lists_owner_id_fkey(display_name)"
    private static let musicListEntrySelection = "id,list_id,canonical_track_id,position,note,created_at,updated_at,canonical_tracks(id,title,artist,album,duration_ms,artwork_url,is_explicit,isrc,provider_tracks(provider,provider_id,storefront,availability,deep_link))"
    private static let musicListCommentSelection = "id,list_id,author_id,body,created_at,updated_at,deleted_at,author:profiles!music_list_comments_author_id_fkey(display_name)"
    private static let albumSubjectStateSelection = "profile_id,canonical_album_id,has_listened,default_rating,is_loved,want_to_listen,created_at,updated_at,canonical_albums(id,title,artist,release_date,upc,album_type,total_tracks,artwork_url,provider_albums(provider,provider_album_id,storefront,deep_link,availability,identity_basis))"
    private static let legacyMusicReviewSelection = "id,profile_id,subject_kind,subject_title,subject_artist,subject_artwork_url,subject_deep_link,rating,body,visibility,contains_spoilers,is_loved,created_at,canonical_tracks(id,title,artist,album,duration_ms,artwork_url,is_explicit),profiles(display_name),review_comments(id,author_id,body,created_at,profiles(display_name)),review_reactions(profile_id,kind)"
    private static let musicReviewSelection = "id,profile_id,subject_kind,subject_title,subject_artist,subject_artwork_url,subject_deep_link,canonical_album_id,rating,body,visibility,contains_spoilers,is_loved,created_at,canonical_tracks(id,title,artist,album,duration_ms,artwork_url,is_explicit),canonical_albums(id,title,artist,release_date,upc,album_type,total_tracks,artwork_url,provider_albums(provider,provider_album_id,storefront,deep_link,availability,identity_basis)),profiles(display_name),review_comments(id,author_id,body,created_at,profiles(display_name)),review_reactions(profile_id,kind)"

    private static func isMissingCanonicalAlbumContract(_ error: Error) -> Bool {
        guard let error = error as? PostgrestError else { return false }
        return ["PGRST200", "PGRST202", "PGRST204", "42703", "42P01"].contains(error.code)
    }

    // Defer plist-dependent client creation until a live backend operation is
    // requested. This keeps local queue behavior and unit tests independent of
    // a test-host Info.plist while production still fails fast on misconfiguration.
    private lazy var client = HarmonySupabaseClient.shared

    func authenticate() async throws {
        if client.auth.currentSession == nil {
            try await client.auth.signInAnonymously()
        } else {
            _ = try await client.auth.session
        }
    }

    func createSession(title: String, allowCollaboratorInvites: Bool, playbackMode: SessionPlaybackMode, expiresAt: Date?) async throws -> RemoteHarmonySession {
        try await authenticate()
        for attempt in 1...3 {
            do {
                let parameters = CreateSessionParameters(
                    p_title: title,
                    p_invite_code: Self.makeInviteCode(),
                    p_playback_mode: playbackMode.rawValue,
                    p_allow_collaborator_invites: allowCollaboratorInvites,
                    p_expires_at: expiresAt
                )
                return try await client.rpc("create_session", params: parameters).execute().value
            } catch let error as PostgrestError where error.code == "23505" && attempt < 3 {
                continue
            }
        }
        throw CollaborationError.inviteCodeGenerationFailed
    }

    func joinSession(inviteCode: String) async throws -> RemoteHarmonySession {
        try await authenticate()
        return try await client.rpc(
            "join_session_by_invite",
            params: ["p_invite_code": inviteCode.uppercased()]
        ).execute().value
    }

    func endSession(id: UUID) async throws {
        try await client.rpc("end_harmony_session", params: ["p_session_id": id.uuidString]).execute()
    }

    func leaveSession(id: UUID) async throws {
        try await client.rpc("leave_harmony_session", params: ["p_session_id": id.uuidString]).execute()
    }

    func session(id: UUID) async throws -> RemoteHarmonySession {
        try await client
            .from("sessions")
            .select("id,title,invite_code,queue_revision,playback_state,ended_at,expires_at,allow_collaborator_invites,playback_mode")
            .eq("id", value: id.uuidString)
            .single()
            .execute()
            .value
    }

    func recentSessions() async throws -> [RemoteHarmonySession] {
        try await authenticate()
        return try await client
            .from("sessions")
            .select("id,title,invite_code,queue_revision,playback_state,ended_at,expires_at,allow_collaborator_invites,playback_mode")
            .order("created_at", ascending: false)
            .limit(20)
            .execute()
            .value
    }

    func setCollaboratorInvitesAllowed(in sessionID: UUID, allowed: Bool) async throws -> RemoteHarmonySession {
        try await client.rpc(
            "set_harmony_collaborator_invites",
            params: UpdateInvitePermissionParameters(
                p_session_id: sessionID,
                p_allow_collaborator_invites: allowed
            )
        ).execute().value
    }

    func providerConnections() async throws -> [RemoteProviderConnection] {
        try await authenticate()
        return try await client
            .from("provider_connection_statuses")
            .select("provider,expires_at")
            .execute()
            .value
    }

    func accountProfile() async throws -> RemoteAccountProfile {
        try await authenticate()
        let userID = try await currentUserID()
        return try await client.from("profiles")
            .select("id,display_name")
            .eq("id", value: userID.uuidString)
            .single().execute().value
    }

    func updateDisplayName(_ displayName: String) async throws -> RemoteAccountProfile {
        try await authenticate()
        let userID = try await currentUserID()
        return try await client.from("profiles")
            .update(UpdateAccountProfile(display_name: displayName))
            .eq("id", value: userID.uuidString)
            .select("id,display_name")
            .single().execute().value
    }

    func socialSettings() async throws -> RemoteSocialSettings {
        try await authenticate()
        let userID = try await currentUserID()
        return try await client.from("profile_social_settings")
            .select("profile_id,live_visibility,history_visibility,reviews_visibility,shelf_visibility,record_harmony_plays")
            .eq("profile_id", value: userID.uuidString)
            .single().execute().value
    }

    func updateSocialSettings(_ settings: RemoteSocialSettings) async throws -> RemoteSocialSettings {
        try await authenticate()
        let userID = try await currentUserID()
        return try await client.from("profile_social_settings")
            .update(UpdateSocialSettings(
                live_visibility: settings.liveVisibility.rawValue,
                history_visibility: settings.historyVisibility.rawValue,
                reviews_visibility: settings.reviewsVisibility.rawValue,
                shelf_visibility: settings.shelfVisibility.rawValue,
                record_harmony_plays: settings.recordHarmonyPlays
            ))
            .eq("profile_id", value: userID.uuidString)
            .select("profile_id,live_visibility,history_visibility,reviews_visibility,shelf_visibility,record_harmony_plays")
            .single().execute().value
    }

    func socialProfiles() async throws -> [RemoteSocialProfile] {
        try await authenticate()
        let userID = try await currentUserID()
        return try await client.from("profiles")
            .select("id,display_name")
            .neq("id", value: userID.uuidString)
            .order("display_name")
            .execute().value
    }

    func socialFollows() async throws -> [RemoteSocialFollow] {
        try await authenticate()
        return try await client.from("social_follows")
            .select("follower_id,followed_id,state")
            .execute().value
    }

    func socialBlocks() async throws -> [RemoteSocialBlock] {
        try await authenticate()
        return try await client.from("profile_blocks")
            .select("blocked_id")
            .execute().value
    }

    func socialNotifications() async throws -> [RemoteSocialNotification] {
        try await authenticate()
        return try await client.from("social_notifications")
            .select("id,kind,created_at,read_at,actor:profiles!social_notifications_actor_id_fkey(display_name),review:music_reviews!social_notifications_review_id_fkey(subject_title,canonical_tracks(title,artist,album,duration_ms,artwork_url,is_explicit)),music_list:music_lists!social_notifications_music_list_id_fkey(title)")
            .order("created_at", ascending: false)
            .limit(50).execute().value
    }

    func markSocialNotificationsRead(_ notificationID: UUID?) async throws {
        try await authenticate()
        _ = try await client.rpc(
            "mark_social_notifications_read",
            params: NotificationIDParameters(p_notification_id: notificationID)
        ).execute()
    }

    func requestSocialFollow(_ profileID: UUID) async throws {
        try await authenticate()
        _ = try await client.rpc("request_social_follow", params: SocialProfileParameters(p_profile_id: profileID)).execute()
    }

    func respondToSocialFollow(from requesterID: UUID, accept: Bool) async throws {
        try await authenticate()
        _ = try await client.rpc(
            "respond_to_social_follow",
            params: RespondToFollowParameters(p_requester_id: requesterID, p_accept: accept)
        ).execute()
    }

    func removeSocialFollow(_ profileID: UUID) async throws {
        try await authenticate()
        _ = try await client.rpc("remove_social_follow", params: SocialProfileParameters(p_profile_id: profileID)).execute()
    }

    func removeSocialFollower(_ profileID: UUID) async throws {
        try await authenticate()
        _ = try await client.rpc("remove_social_follower", params: SocialProfileParameters(p_profile_id: profileID)).execute()
    }

    func blockSocialProfile(_ profileID: UUID) async throws {
        try await authenticate()
        _ = try await client.rpc("block_social_profile", params: SocialProfileParameters(p_profile_id: profileID)).execute()
    }

    func unblockSocialProfile(_ profileID: UUID) async throws {
        try await authenticate()
        _ = try await client.rpc("unblock_social_profile", params: SocialProfileParameters(p_profile_id: profileID)).execute()
    }

    func listeningFeed() async throws -> [RemoteListeningPresence] {
        try await authenticate()
        return try await client
            .from("listening_presence")
            .select("profile_id,status,provider,provider_deep_link,started_at,expires_at,canonical_tracks(title,artist,album,duration_ms,artwork_url,is_explicit),profiles(display_name)")
            .order("updated_at", ascending: false)
            .execute()
            .value
    }

    func listeningHistory() async throws -> [RemoteListeningHistoryEntry] {
        try await authenticate()
        return try await client.from("listening_history_entries")
            .select("id,profile_id,played_at,source,visibility,is_relisten,tags,review_id,rating,canonical_tracks(id,title,artist,album,duration_ms,artwork_url,is_explicit),profiles(display_name)")
            .order("played_at", ascending: false)
            .limit(100).execute().value
    }

    func listeningDiaryPage(
        beforePlayedAt: Date? = nil,
        beforeID: UUID? = nil,
        limit: Int = 51
    ) async throws -> [RemoteListeningHistoryEntry] {
        try await authenticate()
        return try await client.rpc(
            "list_my_listening_diary",
            params: ListeningDiaryPageParameters(
                p_before_played_at: beforePlayedAt,
                p_before_id: beforeID,
                p_limit: limit
            )
        )
        .select("id,profile_id,played_at,source,visibility,is_relisten,tags,review_id,rating,canonical_tracks(id,title,artist,album,duration_ms,artwork_url,is_explicit),profiles(display_name)")
        .execute().value
    }

    func trackSubjectState(canonicalTrackID: UUID) async throws -> RemoteTrackSubjectState? {
        try await authenticate()
        let states: [RemoteTrackSubjectState] = try await client
            .from("profile_track_subject_states")
            .select("profile_id,canonical_track_id,has_listened,default_rating,is_loved,want_to_listen,created_at,updated_at,canonical_tracks(id,title,artist,album,duration_ms,artwork_url,is_explicit)")
            .eq("canonical_track_id", value: canonicalTrackID.uuidString)
            .limit(1)
            .execute().value
        return states.first
    }

    func trackSubjectStatePage(
        beforeUpdatedAt: Date? = nil,
        beforeCanonicalTrackID: UUID? = nil,
        limit: Int = 51
    ) async throws -> [RemoteTrackSubjectState] {
        try await authenticate()
        return try await client.rpc(
            "list_my_track_subject_states",
            params: TrackSubjectStatePageParameters(
                p_before_updated_at: beforeUpdatedAt,
                p_before_canonical_track_id: beforeCanonicalTrackID,
                p_limit: limit
            )
        )
        .select("profile_id,canonical_track_id,has_listened,default_rating,is_loved,want_to_listen,created_at,updated_at,canonical_tracks(id,title,artist,album,duration_ms,artwork_url,is_explicit)")
        .execute().value
    }

    func albumSubjectState(canonicalAlbumID: UUID) async throws -> RemoteAlbumSubjectState? {
        try await authenticate()
        let states: [RemoteAlbumSubjectState] = try await client
            .from("profile_album_subject_states")
            .select(Self.albumSubjectStateSelection)
            .eq("canonical_album_id", value: canonicalAlbumID.uuidString)
            .limit(1)
            .execute().value
        return states.first
    }

    func resolveCanonicalAlbum(_ album: ReviewableAlbum) async throws -> RemoteCanonicalAlbum {
        try await authenticate()
        let canonicalID: UUID
        if let existingID = album.canonicalAlbumID {
            canonicalID = existingID
        } else {
            canonicalID = try await client.rpc(
                "resolve_harmony_album_v2",
                params: ResolveCanonicalAlbumParameters(
                    p_provider: album.provider == .spotify ? "spotify" : "apple_music",
                    p_provider_id: album.providerID,
                    p_title: album.title,
                    p_artist: album.artist,
                    p_artwork_url: album.artworkURL?.absoluteString,
                    p_deep_link: album.deepLinkURL?.absoluteString,
                    p_storefront: album.storefront
                )
            ).execute().value
        }
        let albums: [RemoteCanonicalAlbum] = try await client
            .from("canonical_albums")
            .select("id,title,artist,release_date,upc,album_type,total_tracks,artwork_url,provider_albums(provider,provider_album_id,storefront,deep_link,availability,identity_basis)")
            .eq("id", value: canonicalID.uuidString)
            .limit(1)
            .execute().value
        guard let resolved = albums.first else {
            throw HarmonyRepositoryError.canonicalAlbumUnavailable
        }
        return resolved
    }

    func albumSubjectStatePage(
        beforeUpdatedAt: Date? = nil,
        beforeCanonicalAlbumID: UUID? = nil,
        limit: Int = 51,
        scope: String = "all"
    ) async throws -> [RemoteAlbumSubjectState] {
        try await authenticate()
        return try await client.rpc(
            "list_my_album_subject_states",
            params: AlbumSubjectStatePageParameters(
                p_before_updated_at: beforeUpdatedAt,
                p_before_canonical_album_id: beforeCanonicalAlbumID,
                p_limit: limit,
                p_scope: scope
            )
        )
        .select(Self.albumSubjectStateSelection)
        .execute().value
    }

    func updateAlbumSubjectState(
        canonicalAlbumID: UUID,
        draft: AlbumSubjectStateDraft
    ) async throws -> RemoteAlbumSubjectState {
        try await authenticate()
        let draft = draft.normalizedForSubmission
        return try await client.rpc(
            "set_my_album_subject_state",
            params: SetAlbumSubjectStateParameters(
                p_canonical_album_id: canonicalAlbumID,
                p_has_listened: draft.hasListened,
                p_default_rating: draft.defaultRating,
                p_is_loved: draft.isLoved,
                p_want_to_listen: draft.wantToListen
            )
        ).execute().value
    }

    func canonicalAlbumReviews(
        canonicalAlbumID: UUID,
        beforeCreatedAt: Date? = nil,
        beforeID: UUID? = nil,
        limit: Int = 51
    ) async throws -> [RemoteMusicReview] {
        try await authenticate()
        return try await client.rpc(
            "list_canonical_album_reviews",
            params: CanonicalAlbumReviewsPageParameters(
                p_canonical_album_id: canonicalAlbumID,
                p_before_created_at: beforeCreatedAt,
                p_before_id: beforeID,
                p_limit: limit
            )
        )
        .select(Self.musicReviewSelection)
        .execute().value
    }

    func canonicalAlbumStateAggregate(
        canonicalAlbumID: UUID
    ) async throws -> RemoteCanonicalAlbumStateAggregate {
        try await authenticate()
        let rows: [RemoteCanonicalAlbumStateAggregate] = try await client.rpc(
            "get_canonical_album_state_aggregate",
            params: CanonicalAlbumIDParameters(p_canonical_album_id: canonicalAlbumID)
        ).execute().value
        guard let aggregate = rows.first else {
            throw HarmonyRepositoryError.invalidCanonicalAlbumAggregate
        }
        return aggregate
    }

    func canonicalAlbumRatingDistribution(
        canonicalAlbumID: UUID
    ) async throws -> [RemoteCanonicalAlbumRatingBucket] {
        try await authenticate()
        return try await client.rpc(
            "list_canonical_album_rating_distribution",
            params: CanonicalAlbumIDParameters(p_canonical_album_id: canonicalAlbumID)
        ).execute().value
    }

    func followingActivityPage(
        beforePublishedAt: Date? = nil,
        beforeID: UUID? = nil,
        limit: Int = 50
    ) async throws -> RemoteFollowingActivityPage {
        try await authenticate()
        let pageSize = min(max(limit, 1), 99)
        let rawEvents: [RemoteSocialActivityEvent] = try await client.rpc(
            "list_following_activity",
            params: FollowingActivityPageParameters(
                p_before_published_at: beforePublishedAt,
                p_before_id: beforeID,
                p_limit: pageSize + 1
            )
        )
        .select("id,actor_id,kind,diary_entry_id,review_id,list_id,published_at,actor:profiles!social_activity_events_actor_id_fkey(display_name)")
        .execute().value

        let cursorEvents = Array(rawEvents.prefix(pageSize))
        let reviewIDs = cursorEvents.compactMap(\.reviewID)
        let diaryIDs = cursorEvents.compactMap(\.diaryEntryID)
        let listIDs = cursorEvents.compactMap(\.listID)
        let reviews = try await activityReviews(ids: reviewIDs)
        let diaryEntries = try await activityDiaryEntries(ids: diaryIDs)
        let musicLists = try await activityMusicLists(ids: listIDs)
        let reviewsByID = Dictionary(uniqueKeysWithValues: reviews.map { ($0.id, $0) })
        let diaryByID = Dictionary(uniqueKeysWithValues: diaryEntries.map { ($0.id, $0) })
        let listsByID = Dictionary(uniqueKeysWithValues: musicLists.map { ($0.id, $0) })
        let items = cursorEvents.compactMap { event -> RemoteFollowingActivityItem? in
            let payload: RemoteFollowingActivityPayload
            switch event.kind {
            case "review_published":
                guard let id = event.reviewID, let review = reviewsByID[id] else { return nil }
                payload = .review(review)
            case "diary_logged":
                guard let id = event.diaryEntryID, let entry = diaryByID[id] else { return nil }
                payload = .diary(entry)
            case "list_published":
                guard let id = event.listID, let list = listsByID[id] else { return nil }
                payload = .musicList(list)
            default:
                return nil
            }
            return RemoteFollowingActivityItem(
                id: event.id,
                actorID: event.actorID,
                publishedAt: event.publishedAt,
                actor: event.actor,
                payload: payload
            )
        }
        let rawCursor = cursorEvents.last.map {
            RemoteFollowingActivityCursor(publishedAt: $0.publishedAt, id: $0.id)
        }
        return RemoteFollowingActivityPage(
            items: items,
            cursor: rawCursor,
            hasMore: rawEvents.count > pageSize
        )
    }

    func publicProfileReviewsPage(
        profileID: UUID,
        beforeCreatedAt: Date? = nil,
        beforeID: UUID? = nil,
        limit: Int = 51
    ) async throws -> [RemoteMusicReview] {
        try await authenticate()
        let params = ProfileReviewsPageParameters(
            p_profile_id: profileID,
            p_before_created_at: beforeCreatedAt,
            p_before_id: beforeID,
            p_limit: limit
        )
        do {
            return try await client.rpc("list_profile_music_reviews", params: params)
                .select(Self.musicReviewSelection)
                .execute().value
        } catch where Self.isMissingCanonicalAlbumContract(error) {
            return try await client.rpc("list_profile_music_reviews", params: params)
                .select(Self.legacyMusicReviewSelection)
                .execute().value
        }
    }

    func publicProfileDiaryPage(
        profileID: UUID,
        beforePlayedAt: Date? = nil,
        beforeID: UUID? = nil,
        limit: Int = 51
    ) async throws -> [RemoteListeningHistoryEntry] {
        try await authenticate()
        return try await client.rpc(
            "list_profile_listening_diary",
            params: ProfileDiaryPageParameters(
                p_profile_id: profileID,
                p_before_played_at: beforePlayedAt,
                p_before_id: beforeID,
                p_limit: limit
            )
        )
        .select("id,profile_id,played_at,source,visibility,is_relisten,tags,review_id,rating,canonical_tracks(id,title,artist,album,duration_ms,artwork_url,is_explicit),profiles(display_name)")
        .execute().value
    }

    func publicProfileLovedPage(
        profileID: UUID,
        beforeUpdatedAt: Date? = nil,
        beforeCanonicalTrackID: UUID? = nil,
        limit: Int = 51
    ) async throws -> [RemotePublicLovedTrack] {
        try await authenticate()
        return try await client.rpc(
            "list_profile_loved_tracks",
            params: ProfileLovedPageParameters(
                p_profile_id: profileID,
                p_before_updated_at: beforeUpdatedAt,
                p_before_canonical_track_id: beforeCanonicalTrackID,
                p_limit: limit
            )
        )
        .select("profile_id,canonical_track_id,updated_at,canonical_tracks(id,title,artist,album,duration_ms,artwork_url,is_explicit)")
        .execute().value
    }

    func ownerMusicListsPage(
        beforeUpdatedAt: Date? = nil,
        beforeID: UUID? = nil,
        limit: Int = 51
    ) async throws -> [RemoteMusicList] {
        let profileID = try await currentUserID()
        return try await publicProfileMusicListsPage(
            profileID: profileID,
            beforeUpdatedAt: beforeUpdatedAt,
            beforeID: beforeID,
            limit: limit
        )
    }

    func publicProfileMusicListsPage(
        profileID: UUID,
        beforeUpdatedAt: Date? = nil,
        beforeID: UUID? = nil,
        limit: Int = 51
    ) async throws -> [RemoteMusicList] {
        try await authenticate()
        return try await client.rpc(
            "list_profile_music_lists",
            params: ProfileMusicListsPageParameters(
                p_profile_id: profileID,
                p_before_updated_at: beforeUpdatedAt,
                p_before_id: beforeID,
                p_limit: limit
            )
        )
        .select(Self.musicListSelection)
        .execute().value
    }

    func musicList(id: UUID) async throws -> RemoteMusicList? {
        try await authenticate()
        return try await client.rpc(
            "get_music_list",
            params: MusicListIDParameters(p_list_id: id)
        )
            .select(Self.musicListSelection)
            .single()
            .execute().value
    }

    func musicListEntriesPage(
        listID: UUID,
        afterPosition: Int? = nil,
        limit: Int = 100
    ) async throws -> [RemoteMusicListEntry] {
        try await authenticate()
        return try await client.rpc(
            "list_music_list_entries",
            params: MusicListEntriesPageParameters(
                p_list_id: listID,
                p_after_position: afterPosition,
                p_limit: limit
            )
        )
        .select(Self.musicListEntrySelection)
        .execute().value
    }

    func musicListCommentsPage(
        listID: UUID,
        beforeCreatedAt: Date? = nil,
        beforeID: UUID? = nil,
        limit: Int = 51
    ) async throws -> [RemoteMusicListComment] {
        try await authenticate()
        return try await client.rpc(
            "list_music_list_comments",
            params: MusicListCommentsPageParameters(
                p_list_id: listID,
                p_before_created_at: beforeCreatedAt,
                p_before_id: beforeID,
                p_limit: limit
            )
        )
        .select(Self.musicListCommentSelection)
        .execute().value
    }

    func musicListEngagement(_ listID: UUID) async throws -> RemoteMusicListEngagement {
        try await authenticate()
        return try await client.rpc(
            "get_music_list_engagement",
            params: MusicListIDParameters(p_list_id: listID)
        )
        .execute().value
    }

    private func activityReviews(ids: [UUID]) async throws -> [RemoteMusicReview] {
        guard !ids.isEmpty else { return [] }
        do {
            return try await client.from("music_reviews")
                .select(Self.musicReviewSelection)
                .in("id", values: ids.map(\.uuidString))
                .execute().value
        } catch where Self.isMissingCanonicalAlbumContract(error) {
            return try await client.from("music_reviews")
                .select(Self.legacyMusicReviewSelection)
                .in("id", values: ids.map(\.uuidString))
                .execute().value
        }
    }

    private func activityDiaryEntries(ids: [UUID]) async throws -> [RemoteListeningHistoryEntry] {
        guard !ids.isEmpty else { return [] }
        return try await client.from("listening_history_entries")
            .select("id,profile_id,played_at,source,visibility,is_relisten,tags,review_id,rating,canonical_tracks(id,title,artist,album,duration_ms,artwork_url,is_explicit),profiles(display_name)")
            .in("id", values: ids.map(\.uuidString))
            .execute().value
    }

    private func activityMusicLists(ids: [UUID]) async throws -> [RemoteMusicList] {
        guard !ids.isEmpty else { return [] }
        return try await client.from("music_lists")
            .select(Self.musicListSelection)
            .in("id", values: ids.map(\.uuidString))
            .execute().value
    }

    func trackSubjectState(for track: HarmonyTrack) async throws -> RemoteTrackSubjectState? {
        try await trackSubjectState(canonicalTrackID: canonicalTrackID(for: track))
    }

    func updateTrackSubjectState(
        canonicalTrackID: UUID,
        hasListened: Bool,
        defaultRating: Double?,
        isLoved: Bool,
        wantToListen: Bool
    ) async throws -> RemoteTrackSubjectState {
        try await updateTrackSubjectState(
            canonicalTrackID: canonicalTrackID,
            draft: TrackSubjectStateDraft(
                hasListened: hasListened,
                defaultRating: defaultRating,
                isLoved: isLoved,
                wantToListen: wantToListen
            )
        )
    }

    func updateTrackSubjectState(
        canonicalTrackID: UUID,
        draft: TrackSubjectStateDraft
    ) async throws -> RemoteTrackSubjectState {
        try await authenticate()
        let draft = draft.normalizedForSubmission
        return try await client.rpc(
            "set_my_track_subject_state",
            params: SetTrackSubjectStateParameters(
                p_canonical_track_id: canonicalTrackID,
                p_has_listened: draft.hasListened,
                p_default_rating: draft.defaultRating,
                p_is_loved: draft.isLoved,
                p_want_to_listen: draft.wantToListen
            )
        ).execute().value
    }

    func updateTrackSubjectState(
        for track: HarmonyTrack,
        hasListened: Bool,
        defaultRating: Double?,
        isLoved: Bool,
        wantToListen: Bool
    ) async throws -> RemoteTrackSubjectState {
        try await updateTrackSubjectState(
            canonicalTrackID: canonicalTrackID(for: track),
            hasListened: hasListened,
            defaultRating: defaultRating,
            isLoved: isLoved,
            wantToListen: wantToListen
        )
    }

    func musicReviews() async throws -> [RemoteMusicReview] {
        try await authenticate()
        do {
            return try await client.from("music_reviews")
                .select(Self.musicReviewSelection)
                .order("created_at", ascending: false).limit(50).execute().value
        } catch where Self.isMissingCanonicalAlbumContract(error) {
            return try await client.from("music_reviews")
                .select(Self.legacyMusicReviewSelection)
                .order("created_at", ascending: false).limit(50).execute().value
        }
    }

    func exchangeSpotifyAuthorization(_ response: SpotifyAuthorizationResponse) async throws {
        try await authenticate()
        try await client.functions.invoke(
            "spotify-token-exchange",
            options: FunctionInvokeOptions(body: SpotifyTokenExchangeParameters(
                code: response.code,
                codeVerifier: response.codeVerifier,
                redirectURI: HarmonySupabaseConfiguration.spotifyRedirectURI.absoluteString
            ))
        )
    }

    func spotifyAccessCredential() async throws -> SpotifyAccessCredential {
        try await authenticate()
        return try await client.functions.invoke("spotify-access-token")
    }

    func disconnectSpotify() async throws {
        try await authenticate()
        let response: SpotifyDisconnectResponse = try await client.functions.invoke("spotify-disconnect")
        guard response.disconnected else { throw CollaborationError.invalidResponse }
    }

    func deleteAccount() async throws {
        try await authenticate()
        let response: DeleteAccountResponse = try await client.functions.invoke("delete-account")
        guard response.deleted else { throw CollaborationError.invalidResponse }
        try await client.auth.signOut(scope: .local)
    }

    func searchSpotify(query: String) async throws -> [SpotifySearchTrack] {
        try await authenticate()
        do {
            let response: SpotifySearchResponse = try await client.functions.invoke(
                "spotify-search",
                options: FunctionInvokeOptions(body: SpotifySearchParameters(query: query))
            )
            return response.tracks
        } catch let FunctionsError.httpError(_, data) {
            let response = try? JSONDecoder().decode(EdgeFunctionErrorResponse.self, from: data)
            switch (response?.error, response?.upstreamStatus) {
            case ("spotify_not_connected", _), ("spotify_refresh_failed", _), (_, 401):
                throw SpotifyCatalogError.reconnectRequired
            case (_, 403):
                throw SpotifyCatalogError.accessRestricted
            case (_, 429):
                throw SpotifyCatalogError.rateLimited
            default:
                throw SpotifyCatalogError.temporarilyUnavailable
            }
        }
    }

    func importSpotifyHistory() async throws -> SpotifyHistoryImportResponse {
        try await authenticate()
        do {
            return try await client.functions.invoke("spotify-history-import")
        } catch let FunctionsError.httpError(_, data) {
            let response = try? JSONDecoder().decode(EdgeFunctionErrorResponse.self, from: data)
            switch response?.error {
            case "spotify_history_scope_missing", "spotify_not_connected", "spotify_refresh_failed":
                throw SpotifyHistoryImportError.reconnectRequired
            default:
                if response?.upstreamStatus == 429 { throw SpotifyHistoryImportError.rateLimited }
                throw SpotifyHistoryImportError.unavailable
            }
        }
    }

    func publishSpotifyNowListening() async throws -> SpotifyNowListeningResponse {
        try await authenticate()
        do {
            return try await client.functions.invoke("spotify-now-listening")
        } catch let FunctionsError.httpError(_, data) {
            let response = try? JSONDecoder().decode(EdgeFunctionErrorResponse.self, from: data)
            switch response?.error {
            case "spotify_playback_scope_missing", "spotify_not_connected", "spotify_refresh_failed":
                throw SpotifyNowListeningError.reconnectRequired
            default:
                if response?.upstreamStatus == 429 { throw SpotifyNowListeningError.rateLimited }
                throw SpotifyNowListeningError.unavailable
            }
        }
    }

    func members(for sessionID: UUID) async throws -> [RemoteSessionMember] {
        try await client.from("session_members").select("profile_id,role,profiles(display_name)").eq("session_id", value: sessionID.uuidString).execute().value
    }

    func currentUserID() async throws -> UUID {
        try await authenticate()
        return try await client.auth.session.user.id
    }

    func add(track: HarmonyTrack, to sessionID: UUID, expectedRevision: Int) async throws -> Int {
        let canonicalTrackID = try await canonicalTrackID(for: track)
        return try await executeCommand(QueueCommandParameters(
            p_session_id: sessionID,
            p_command_id: UUID(),
            p_expected_revision: expectedRevision,
            p_type: "add",
            p_payload: AddPayload(canonical_track_id: canonicalTrackID)
        ))
    }

    func publishListeningPresence(track: HarmonyTrack, visibility: SocialVisibilityOption) async throws {
        try await authenticate()
        let mapping = track.mappings.first(where: { !$0.providerID.isEmpty })
        let canonicalTrackID = try await canonicalTrackID(for: track)
        _ = try await client.rpc(
            "publish_listening_presence",
            params: PublishListeningPresenceParameters(
                p_canonical_track_id: canonicalTrackID,
                p_provider: mapping.map { $0.provider == .spotify ? "spotify" : "apple_music" },
                p_provider_track_id: mapping?.providerID,
                p_provider_deep_link: mapping?.deepLinkURL?.absoluteString,
                p_visibility: visibility.rawValue,
                p_started_at: Date(),
                p_expires_at: Date().addingTimeInterval(5 * 60)
            )
        ).execute()
    }

    func stopListeningPresence() async throws {
        try await authenticate()
        _ = try await client.rpc("stop_listening_presence").execute()
    }

    func recordListeningHistory(track: HarmonyTrack, visibility: SocialVisibilityOption) async throws {
        try await authenticate()
        let mapping = track.mappings.first(where: { !$0.providerID.isEmpty })
        let canonicalTrackID = try await canonicalTrackID(for: track)
        _ = try await client.rpc("record_listening_history", params: RecordListeningHistoryParameters(
            p_canonical_track_id: canonicalTrackID,
            p_provider: mapping.map { $0.provider == .spotify ? "spotify" : "apple_music" },
            p_provider_track_id: mapping?.providerID,
            p_played_at: Date(),
            p_source: "harmony_room",
            p_visibility: visibility.rawValue,
            p_is_relisten: false,
            p_tags: [],
            p_rating: nil
        )).execute()
    }

    func createListeningDiaryEntry(
        track: HarmonyTrack,
        playedAt: Date,
        isRelisten: Bool,
        tags: [String],
        visibility: SocialVisibilityOption,
        rating: Double? = nil
    ) async throws -> RemoteListeningHistoryEntry {
        try await authenticate()
        let mapping = track.mappings.first(where: { !$0.providerID.isEmpty })
        let canonicalTrackID = try await canonicalTrackID(for: track)
        return try await client.rpc(
            "record_listening_history",
            params: RecordListeningHistoryParameters(
                p_canonical_track_id: canonicalTrackID,
                p_provider: mapping.map { $0.provider == .spotify ? "spotify" : "apple_music" },
                p_provider_track_id: mapping?.providerID,
                p_played_at: playedAt,
                p_source: "manual",
                p_visibility: visibility.rawValue,
                p_is_relisten: isRelisten,
                p_tags: tags,
                p_rating: rating
            )
        ).execute().value
    }

    func updateListeningDiaryEntry(
        _ entryID: UUID,
        playedAt: Date,
        isRelisten: Bool,
        tags: [String],
        visibility: SocialVisibilityOption,
        reviewID: UUID?,
        rating: Double? = nil
    ) async throws {
        try await authenticate()
        _ = try await client.rpc(
            "update_listening_diary_entry_with_rating",
            params: UpdateListeningDiaryEntryParameters(
                p_entry_id: entryID,
                p_played_at: playedAt,
                p_visibility: visibility.rawValue,
                p_is_relisten: isRelisten,
                p_tags: tags,
                p_review_id: reviewID,
                p_rating: rating
            )
        ).execute()
    }

    func createListeningDiaryEntry(
        track: HarmonyTrack,
        listenedOn: Date,
        isRelisten: Bool,
        tags: [String],
        visibility: SocialVisibilityOption,
        rating: Double? = nil
    ) async throws -> RemoteListeningHistoryEntry {
        try await createListeningDiaryEntry(
            track: track,
            playedAt: listenedOn,
            isRelisten: isRelisten,
            tags: tags,
            visibility: visibility,
            rating: rating
        )
    }

    func deleteListeningHistoryEntry(_ entryID: UUID) async throws {
        try await authenticate()
        _ = try await client.rpc("delete_listening_history_entry", params: HistoryEntryIDParameters(p_entry_id: entryID)).execute()
    }

    func createTrackReview(track: HarmonyTrack, rating: Double, body: String, visibility: SocialVisibilityOption, isLoved: Bool, containsSpoilers: Bool = false) async throws {
        try await authenticate()
        let mapping = track.mappings.first(where: { !$0.providerID.isEmpty })
        let canonicalTrackID = try await canonicalTrackID(for: track)
        _ = try await client.rpc("create_music_review", params: CreateTrackReviewParameters(
            p_canonical_track_id: canonicalTrackID,
            p_provider: mapping.map { $0.provider == .spotify ? "spotify" : "apple_music" },
            p_provider_subject_id: mapping?.providerID,
            p_rating: rating,
            p_body: body,
            p_visibility: visibility.rawValue,
            p_contains_spoilers: containsSpoilers,
            p_is_loved: isLoved
        )).execute()
    }

    func createAlbumReview(album: ReviewableAlbum, rating: Double, body: String, visibility: SocialVisibilityOption, isLoved: Bool = false, containsSpoilers: Bool = false) async throws {
        try await authenticate()
        let provider = album.provider == .spotify ? "spotify" : "apple_music"
        let legacyParameters = CreateAlbumReviewParameters(
            p_provider: provider,
            p_provider_subject_id: album.providerID,
            p_subject_title: album.title,
            p_subject_artist: album.artist,
            p_subject_artwork_url: album.artworkURL?.absoluteString,
            p_subject_deep_link: album.deepLinkURL?.absoluteString,
            p_rating: rating,
            p_body: body,
            p_visibility: visibility.rawValue,
            p_contains_spoilers: containsSpoilers,
            p_is_loved: isLoved
        )
        do {
            _ = try await client.rpc("create_music_review", params: CreateCanonicalAlbumReviewParameters(
                p_provider: provider,
                p_provider_subject_id: album.providerID,
                p_subject_title: album.title,
                p_subject_artist: album.artist,
                p_subject_artwork_url: album.artworkURL?.absoluteString,
                p_subject_deep_link: album.deepLinkURL?.absoluteString,
                p_rating: rating,
                p_body: body,
                p_visibility: visibility.rawValue,
                p_contains_spoilers: containsSpoilers,
                p_is_loved: isLoved,
                p_canonical_album_id: album.canonicalAlbumID,
                p_provider_storefront: album.storefront
            )).execute()
        } catch where Self.isMissingCanonicalAlbumContract(error) {
            _ = try await client.rpc("create_music_review", params: legacyParameters).execute()
        }
    }

    func toggleHeart(on reviewID: UUID) async throws -> Bool {
        try await authenticate()
        return try await client.rpc("toggle_review_reaction", params: ReviewReactionParameters(p_review_id: reviewID)).execute().value
    }

    func addComment(to reviewID: UUID, body: String) async throws {
        try await authenticate()
        _ = try await client.rpc("add_review_comment", params: ReviewCommentParameters(p_review_id: reviewID, p_body: body)).execute()
    }

    func deleteComment(_ commentID: UUID) async throws {
        try await authenticate()
        _ = try await client.rpc("delete_review_comment", params: CommentIDParameters(p_comment_id: commentID)).execute()
    }

    func updateReview(_ reviewID: UUID, rating: Double, body: String, visibility: SocialVisibilityOption, isLoved: Bool, containsSpoilers: Bool = false) async throws {
        try await authenticate()
        _ = try await client.rpc("update_music_review", params: UpdateReviewParameters(
            p_review_id: reviewID,
            p_rating: rating,
            p_body: body,
            p_visibility: visibility.rawValue,
            p_contains_spoilers: containsSpoilers,
            p_is_loved: isLoved
        )).execute()
    }

    func deleteReview(_ reviewID: UUID) async throws {
        try await authenticate()
        _ = try await client.rpc("delete_music_review", params: ReviewIDParameters(p_review_id: reviewID)).execute()
    }

    func createMusicList(
        title: String,
        description: String,
        tags: [String],
        isRanked: Bool,
        visibility: SocialVisibilityOption
    ) async throws -> RemoteMusicList {
        try await authenticate()
        return try await client.rpc(
            "create_music_list",
            params: CreateMusicListParameters(
                p_title: title,
                p_description: description,
                p_tags: tags,
                p_is_ranked: isRanked,
                p_visibility: visibility.rawValue
            )
        )
        .select(Self.musicListSelection)
        .single()
        .execute().value
    }

    func updateMusicList(
        _ listID: UUID,
        title: String,
        description: String,
        tags: [String],
        isRanked: Bool,
        visibility: SocialVisibilityOption
    ) async throws -> RemoteMusicList {
        try await authenticate()
        return try await client.rpc(
            "update_music_list",
            params: UpdateMusicListParameters(
                p_list_id: listID,
                p_title: title,
                p_description: description,
                p_tags: tags,
                p_is_ranked: isRanked,
                p_visibility: visibility.rawValue
            )
        )
        .select(Self.musicListSelection)
        .single()
        .execute().value
    }

    func saveMusicList(
        listID: UUID?,
        title: String,
        description: String,
        tags: [String],
        isRanked: Bool,
        visibility: SocialVisibilityOption,
        entries: [MusicListDraftEntry],
        expectedRevision: Int?
    ) async throws -> RemoteMusicList {
        try await authenticate()
        var resolvedEntries: [MusicListDraftEntryPayload] = []
        resolvedEntries.reserveCapacity(entries.count)
        for entry in entries {
            resolvedEntries.append(MusicListDraftEntryPayload(
                canonicalTrackID: try await canonicalTrackID(for: entry.track),
                note: entry.note
            ))
        }
        return try await client.rpc(
            "save_music_list",
            params: SaveMusicListParameters(
                p_list_id: listID,
                p_title: title,
                p_description: description,
                p_tags: tags,
                p_is_ranked: isRanked,
                p_visibility: visibility.rawValue,
                p_entries: resolvedEntries,
                p_expected_revision: expectedRevision
            )
        )
        .select(Self.musicListSelection)
        .single()
        .execute().value
    }

    func deleteMusicList(_ listID: UUID) async throws {
        try await authenticate()
        _ = try await client.rpc(
            "delete_music_list",
            params: MusicListIDParameters(p_list_id: listID)
        ).execute()
    }

    func addMusicListEntry(
        listID: UUID,
        track: HarmonyTrack,
        note: String = "",
        expectedRevision: Int
    ) async throws -> RemoteMusicListEntryMutation {
        let canonicalTrackID = try await canonicalTrackID(for: track)
        return try await addMusicListEntry(
            listID: listID,
            canonicalTrackID: canonicalTrackID,
            note: note,
            expectedRevision: expectedRevision
        )
    }

    func addMusicListEntry(
        listID: UUID,
        canonicalTrackID: UUID,
        note: String = "",
        expectedRevision: Int
    ) async throws -> RemoteMusicListEntryMutation {
        try await authenticate()
        return try await client.rpc(
            "add_music_list_entry",
            params: AddMusicListEntryParameters(
                p_list_id: listID,
                p_canonical_track_id: canonicalTrackID,
                p_note: note,
                p_expected_revision: expectedRevision
            )
        ).execute().value
    }

    func updateMusicListEntryNote(
        entryID: UUID,
        note: String,
        expectedRevision: Int
    ) async throws -> RemoteMusicListEntryMutation {
        try await authenticate()
        return try await client.rpc(
            "update_music_list_entry_note",
            params: UpdateMusicListEntryNoteParameters(
                p_entry_id: entryID,
                p_note: note,
                p_expected_revision: expectedRevision
            )
        ).execute().value
    }

    func removeMusicListEntry(
        entryID: UUID,
        expectedRevision: Int
    ) async throws -> Int {
        try await authenticate()
        return try await client.rpc(
            "remove_music_list_entry",
            params: MusicListEntryRevisionParameters(
                p_entry_id: entryID,
                p_expected_revision: expectedRevision
            )
        ).execute().value
    }

    func reorderMusicListEntries(
        listID: UUID,
        orderedEntryIDs: [UUID],
        expectedRevision: Int
    ) async throws -> Int {
        try await authenticate()
        return try await client.rpc(
            "reorder_music_list_entries",
            params: ReorderMusicListEntriesParameters(
                p_list_id: listID,
                p_ordered_entry_ids: orderedEntryIDs,
                p_expected_revision: expectedRevision
            )
        ).execute().value
    }

    func setMusicListLiked(_ listID: UUID, isLiked: Bool) async throws -> Bool {
        try await authenticate()
        return try await client.rpc(
            "set_music_list_liked",
            params: SetMusicListLikedParameters(
                p_list_id: listID,
                p_is_liked: isLiked
            )
        ).execute().value
    }

    func addMusicListComment(listID: UUID, body: String) async throws -> RemoteMusicListComment {
        try await authenticate()
        return try await client.rpc(
            "add_music_list_comment",
            params: AddMusicListCommentParameters(p_list_id: listID, p_body: body)
        )
        .select(Self.musicListCommentSelection)
        .single()
        .execute().value
    }

    func deleteMusicListComment(_ commentID: UUID) async throws {
        try await authenticate()
        _ = try await client.rpc(
            "delete_music_list_comment",
            params: MusicListCommentIDParameters(p_comment_id: commentID)
        ).execute()
    }

    private func canonicalTrackID(for track: HarmonyTrack) async throws -> UUID {
        if let canonicalTrackID = track.canonicalTrackID { return canonicalTrackID }
        let mapping = track.mappings
            .filter { !$0.providerID.isEmpty }
            .sorted {
                ($0.provider.rawValue, $0.storefront, $0.providerID)
                    < ($1.provider.rawValue, $1.storefront, $1.providerID)
            }
            .first
        if let mapping {
            return try await client.rpc(
                "resolve_harmony_track_v2",
                params: ResolveCanonicalTrackParameters(
                    p_provider: mapping.provider == .spotify ? "spotify" : "apple_music",
                    p_provider_id: mapping.providerID,
                    p_title: track.title,
                    p_artist: track.artist,
                    p_album: track.album,
                    p_duration_ms: track.duration > 0 ? Int(track.duration * 1000) : nil,
                    p_artwork_url: track.artworkURL?.absoluteString,
                    p_is_explicit: track.isExplicit,
                    p_deep_link: mapping.deepLinkURL?.absoluteString,
                    p_isrc: track.isrc,
                    p_storefront: mapping.storefront
                )
            ).execute().value
        }
        throw CollaborationError.missingCanonicalTrackIdentity
    }
    func remove(queueItemID: UUID, from sessionID: UUID, expectedRevision: Int) async throws -> Int {
        try await executeCommand(QueueCommandParameters(p_session_id: sessionID, p_command_id: UUID(), p_expected_revision: expectedRevision, p_type: "remove", p_payload: RemovePayload(queue_item_id: queueItemID)))
    }

    func move(queueItemID: UUID, to position: Double, in sessionID: UUID, expectedRevision: Int) async throws -> Int {
        try await executeCommand(QueueCommandParameters(p_session_id: sessionID, p_command_id: UUID(), p_expected_revision: expectedRevision, p_type: "move", p_payload: MovePayload(queue_item_id: queueItemID, position: position)))
    }

    func setPlayback(state: PlaybackState, in sessionID: UUID, expectedRevision: Int) async throws -> Int {
        let type = state == .playing ? "play" : "pause"
        return try await executeCommand(QueueCommandParameters(p_session_id: sessionID, p_command_id: UUID(), p_expected_revision: expectedRevision, p_type: type, p_payload: PlaybackPayload(status: state == .playing ? "playing" : "paused")))
    }

    func skip(in sessionID: UUID, expectedRevision: Int) async throws -> Int {
        let result: QueueCommandResult = try await client.rpc(
            "skip_queue_item",
            params: SkipQueueParameters(
                p_session_id: sessionID,
                p_command_id: UUID(),
                p_expected_revision: expectedRevision
            )
        ).execute().value
        guard result.status == "applied" else { throw CollaborationError.revisionConflict }
        return result.revision
    }

    private func executeCommand<Payload: Encodable>(_ parameters: QueueCommandParameters<Payload>) async throws -> Int {
        let result: QueueCommandResult = try await client.rpc("apply_queue_command", params: parameters).execute().value
        guard result.status == "applied" else { throw CollaborationError.revisionConflict }
        return result.revision
    }

    func queue(for sessionID: UUID) async throws -> [RemoteQueueSnapshot] {
        try await client
            .from("queue_items")
            .select("id,position,added_by,canonical_tracks(id,title,artist,album,duration_ms,isrc,artwork_url,is_explicit,provider_tracks(provider,provider_id,storefront,availability,deep_link))")
            .eq("session_id", value: sessionID.uuidString)
            .order("position", ascending: true)
            .execute()
            .value
    }

    func observeQueue(sessionID: UUID, onChange: @escaping @Sendable () -> Void) async throws -> LiveQueueSubscription {
        let channel = client.channel("queue-\(sessionID.uuidString)")
        let token = channel.onPostgresChange(
            AnyAction.self,
            schema: "public",
            table: "queue_events",
            filter: .eq("session_id", value: sessionID.uuidString)
        ) { _ in
            onChange()
        }
        try await channel.subscribeWithError()
        return LiveQueueSubscription(channel: channel, token: token)
    }

    func observeSession(sessionID: UUID, onChange: @escaping @Sendable () -> Void) async throws -> LiveSessionSubscription {
        let channel = client.channel("session-\(sessionID.uuidString)")
        let token = channel.onPostgresChange(
            AnyAction.self,
            schema: "public",
            table: "sessions",
            filter: .eq("id", value: sessionID.uuidString)
        ) { _ in
            onChange()
        }
        try await channel.subscribeWithError()
        return LiveSessionSubscription(channel: channel, token: token)
    }

    func observeSocialActivity(onChange: @escaping @Sendable () -> Void) async throws -> LiveSocialSubscription {
        try await authenticate()
        let profileID = try await currentUserID()
        let channel = client.channel("social-\(profileID.uuidString)")
        let tables = [
            "profiles",
            "social_follows",
            "profile_blocks",
            "listening_presence",
            "listening_history_entries",
            "music_reviews",
            "review_comments",
            "review_reactions",
            "social_notifications",
            "social_activity_events",
            "profile_social_settings",
        ]
        let tokens = tables.map { table in
            channel.onPostgresChange(AnyAction.self, schema: "public", table: table) { _ in
                onChange()
            }
        }
        try await channel.subscribeWithError()
        return LiveSocialSubscription(channel: channel, tokens: tokens)
    }

    func observePresence(
        sessionID: UUID,
        profileID: UUID,
        onChange: @escaping @Sendable (_ joins: Set<UUID>, _ leaves: Set<UUID>) -> Void
    ) async throws -> LivePresenceSubscription {
        try await authenticate()
        let channel = client.channel("presence-\(sessionID.uuidString)") { config in
            config.presence.key = profileID.uuidString
        }
        let token = channel.onPresenceChange { action in
            let joins = Set(action.joins.keys.compactMap(UUID.init(uuidString:)))
            let leaves = Set(action.leaves.keys.compactMap(UUID.init(uuidString:)))
            onChange(joins, leaves)
        }
        try await channel.subscribeWithError()
        try await channel.track(RemotePresence(profileID: profileID))
        return LivePresenceSubscription(channel: channel, token: token)
    }

    private static func makeInviteCode() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).uppercased()
    }
}

enum CollaborationError: LocalizedError {
    case revisionConflict, invalidResponse, inviteCodeGenerationFailed, missingCanonicalTrackIdentity
    var errorDescription: String? {
        switch self {
        case .revisionConflict: return "The queue changed on another device. Refresh and try again."
        case .invalidResponse: return "Harmony received an invalid server response."
        case .inviteCodeGenerationFailed: return "Harmony could not create a unique invite code. Please try again."
        case .missingCanonicalTrackIdentity: return "Harmony could not safely identify this recording. Choose it from a connected music service and try again."
        }
    }
}

enum SpotifyCatalogError: LocalizedError {
    case reconnectRequired, accessRestricted, rateLimited, temporarilyUnavailable

    var errorDescription: String? {
        switch self {
        case .reconnectRequired:
            return "Reconnect Spotify, then try the search again."
        case .accessRestricted:
            return "Spotify has restricted this catalog request for the current developer app."
        case .rateLimited:
            return "Spotify's search limit was reached. Wait a moment and try again."
        case .temporarilyUnavailable:
            return "Spotify search is temporarily unavailable. Try again shortly."
        }
    }
}

final class LiveQueueSubscription {
    let channel: RealtimeChannelV2
    let token: RealtimeSubscription

    init(channel: RealtimeChannelV2, token: RealtimeSubscription) {
        self.channel = channel
        self.token = token
    }
}

final class LiveSessionSubscription {
    let channel: RealtimeChannelV2
    let token: RealtimeSubscription

    init(channel: RealtimeChannelV2, token: RealtimeSubscription) {
        self.channel = channel
        self.token = token
    }
}

final class LivePresenceSubscription {
    let channel: RealtimeChannelV2
    let token: RealtimeSubscription

    init(channel: RealtimeChannelV2, token: RealtimeSubscription) {
        self.channel = channel
        self.token = token
    }
}

final class LiveSocialSubscription {
    let channel: RealtimeChannelV2
    let tokens: [RealtimeSubscription]

    init(channel: RealtimeChannelV2, tokens: [RealtimeSubscription]) {
        self.channel = channel
        self.tokens = tokens
    }
}
