import Foundation
import Supabase

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
}
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

struct RemoteProfile: Decodable { let displayName: String; enum CodingKeys: String, CodingKey { case displayName = "display_name" } }

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
    let recordHarmonyPlays: Bool
    enum CodingKeys: String, CodingKey {
        case profileID = "profile_id"
        case liveVisibility = "live_visibility"
        case historyVisibility = "history_visibility"
        case reviewsVisibility = "reviews_visibility"
        case recordHarmonyPlays = "record_harmony_plays"
    }
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

struct RemoteSocialNotification: Decodable, Identifiable {
    let id: UUID
    let kind: String
    let createdAt: Date
    let readAt: Date?
    let actor: RemoteProfile
    let review: RemoteNotificationReview?
    enum CodingKeys: String, CodingKey {
        case id, kind, actor, review
        case createdAt = "created_at"
        case readAt = "read_at"
    }
}

struct RemoteCatalogTrack: Decodable {
    let title: String
    let artist: String
    let album: String?
    let durationMilliseconds: Int?
    let artworkURL: URL?
    let isExplicit: Bool
    let providerTracks: [RemoteProviderTrack]?

    enum CodingKeys: String, CodingKey {
        case title, artist, album
        case durationMilliseconds = "duration_ms"
        case artworkURL = "artwork_url"
        case isExplicit = "is_explicit"
        case providerTracks = "provider_tracks"
    }
}

struct RemoteProviderTrack: Decodable {
    let provider: String
    let providerID: String
    let availability: String
    let deepLink: URL?
    enum CodingKeys: String, CodingKey {
        case provider, availability
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
    let canonicalTrack: RemoteCatalogTrack?
    let profile: RemoteProfile
    enum CodingKeys: String, CodingKey {
        case id, source, visibility, tags
        case profileID = "profile_id"
        case playedAt = "played_at"
        case isRelisten = "is_relisten"
        case canonicalTrack = "canonical_tracks"
        case profile = "profiles"
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
    let canonicalTrack: RemoteCatalogTrack?
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
        case profileID = "profile_id"
        case createdAt = "created_at"
        case canonicalTrack = "canonical_tracks"
        case profile = "profiles"
        case comments = "review_comments"
        case reactions = "review_reactions"
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
    let durationSeconds: Int
    let artworkURL: URL?
    let providerID: String
    let deepLinkURL: URL?
    let isExplicit: Bool
    let albumProviderID: String
    let albumArtist: String
    let albumDeepLinkURL: URL?
}

@MainActor
final class HarmonyCollaborationRepository {
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
            .select("profile_id,live_visibility,history_visibility,reviews_visibility,record_harmony_plays")
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
                record_harmony_plays: settings.recordHarmonyPlays
            ))
            .eq("profile_id", value: userID.uuidString)
            .select("profile_id,live_visibility,history_visibility,reviews_visibility,record_harmony_plays")
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
            .select("id,kind,created_at,read_at,actor:profiles!social_notifications_actor_id_fkey(display_name),review:music_reviews!social_notifications_review_id_fkey(subject_title,canonical_tracks(title,artist,album,duration_ms,artwork_url,is_explicit))")
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
            .select("id,profile_id,played_at,source,visibility,is_relisten,tags,canonical_tracks(title,artist,album,duration_ms,artwork_url,is_explicit),profiles(display_name)")
            .order("played_at", ascending: false)
            .limit(100).execute().value
    }

    func musicReviews() async throws -> [RemoteMusicReview] {
        try await authenticate()
        return try await client.from("music_reviews")
            .select("id,profile_id,subject_kind,subject_title,subject_artist,subject_artwork_url,subject_deep_link,rating,body,visibility,contains_spoilers,is_loved,created_at,canonical_tracks(title,artist,album,duration_ms,artwork_url,is_explicit),profiles(display_name),review_comments(id,author_id,body,created_at,profiles(display_name)),review_reactions(profile_id,kind)")
            .order("created_at", ascending: false).limit(50).execute().value
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
            p_tags: []
        )).execute()
    }

    func createListeningDiaryEntry(
        track: HarmonyTrack,
        playedAt: Date,
        isRelisten: Bool,
        tags: [String],
        visibility: SocialVisibilityOption
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
                p_tags: tags
            )
        ).execute().value
    }

    func createListeningDiaryEntry(
        track: HarmonyTrack,
        listenedOn: Date,
        isRelisten: Bool,
        tags: [String],
        visibility: SocialVisibilityOption
    ) async throws -> RemoteListeningHistoryEntry {
        try await createListeningDiaryEntry(
            track: track,
            playedAt: listenedOn,
            isRelisten: isRelisten,
            tags: tags,
            visibility: visibility
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
        _ = try await client.rpc("create_music_review", params: CreateAlbumReviewParameters(
            p_provider: album.provider == .spotify ? "spotify" : "apple_music",
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
        )).execute()
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

    private func canonicalTrackID(for track: HarmonyTrack) async throws -> UUID {
        if let mapping = track.mappings.first(where: { !$0.providerID.isEmpty }) {
            return try await client.rpc(
                "resolve_harmony_track",
                params: ResolveCanonicalTrackParameters(
                    p_provider: mapping.provider == .spotify ? "spotify" : "apple_music",
                    p_provider_id: mapping.providerID,
                    p_title: track.title,
                    p_artist: track.artist,
                    p_album: track.album,
                    p_duration_ms: Int(track.duration * 1000),
                    p_artwork_url: track.artworkURL?.absoluteString,
                    p_is_explicit: track.isExplicit,
                    p_deep_link: mapping.deepLinkURL?.absoluteString
                )
            ).execute().value
        }
        let trackID: RemoteTrackID = try await client
            .from("canonical_tracks")
            .select("id")
            .eq("title", value: track.title)
            .eq("artist", value: track.artist)
            .single()
            .execute()
            .value
        return trackID.id
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
            .select("id,position,added_by,canonical_tracks(title,artist,album,duration_ms,artwork_url,is_explicit,provider_tracks(provider,provider_id,availability,deep_link))")
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
    case revisionConflict, invalidResponse, inviteCodeGenerationFailed
    var errorDescription: String? {
        switch self {
        case .revisionConflict: return "The queue changed on another device. Refresh and try again."
        case .invalidResponse: return "Harmony received an invalid server response."
        case .inviteCodeGenerationFailed: return "Harmony could not create a unique invite code. Please try again."
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
