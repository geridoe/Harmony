import Foundation
import Supabase

struct RemoteHarmonySession: Decodable {
    let id: UUID
    let title: String
    let inviteCode: String
    let queueRevision: Int
    let playbackState: RemotePlaybackState?

    enum CodingKeys: String, CodingKey {
        case id, title
        case inviteCode = "invite_code"
        case queueRevision = "queue_revision"
        case playbackState = "playback_state"
    }
}

struct RemotePlaybackState: Decodable {
    let status: String?
}

private struct CreateSessionParameters: Encodable {
    let p_title: String
    let p_invite_code: String
    let p_playback_mode = "conductor_playback"
    let p_allow_collaborator_invites = true
}

private struct QueueCommandParameters<Payload: Encodable>: Encodable {
    let p_session_id: UUID
    let p_command_id: UUID
    let p_expected_revision: Int
    let p_type: String
    let p_payload: Payload
}

private struct AddPayload: Encodable { let canonical_track_id: UUID }
private struct RemovePayload: Encodable { let queue_item_id: UUID }
private struct MovePayload: Encodable { let queue_item_id: UUID; let position: Double }
private struct PlaybackPayload: Encodable { let status: String }
private struct SkipQueueParameters: Encodable {
    let p_session_id: UUID
    let p_command_id: UUID
    let p_expected_revision: Int
}
private struct RemoteTrackID: Decodable { let id: UUID }
private struct RemoteCanonicalTrackReference: Decodable {
    let canonicalTrackID: UUID
    enum CodingKeys: String, CodingKey { case canonicalTrackID = "canonical_track_id" }
}
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

struct RemoteCatalogTrack: Decodable {
    let title: String
    let artist: String
    let album: String?
    let durationMilliseconds: Int?
    let artworkURL: URL?
    let providerTracks: [RemoteProviderTrack]?

    enum CodingKeys: String, CodingKey {
        case title, artist, album
        case durationMilliseconds = "duration_ms"
        case artworkURL = "artwork_url"
        case providerTracks = "provider_tracks"
    }
}

struct RemoteProviderTrack: Decodable {
    let provider: String
    let providerID: String
    let availability: String
    enum CodingKeys: String, CodingKey {
        case provider, availability
        case providerID = "provider_id"
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

struct SpotifyAccessCredential: Decodable {
    let accessToken: String
    let expiresAt: String
    let scopes: [String]
}

private struct SpotifyDisconnectResponse: Decodable { let disconnected: Bool }
private struct SpotifySearchParameters: Encodable { let query: String }
private struct SpotifySearchResponse: Decodable { let tracks: [SpotifySearchTrack] }
struct SpotifySearchTrack: Decodable {
    let title: String
    let artist: String
    let album: String
    let durationSeconds: Int
    let artworkURL: URL?
    let providerID: String
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

    func createSession(title: String) async throws -> RemoteHarmonySession {
        try await authenticate()
        let parameters = CreateSessionParameters(
            p_title: title,
            p_invite_code: Self.makeInviteCode()
        )
        return try await client.rpc("create_session", params: parameters).execute().value
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
            .select("id,title,invite_code,queue_revision,playback_state")
            .eq("id", value: id.uuidString)
            .single()
            .execute()
            .value
    }

    func providerConnections() async throws -> [RemoteProviderConnection] {
        try await authenticate()
        return try await client
            .from("provider_connection_statuses")
            .select("provider,expires_at")
            .execute()
            .value
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

    func searchSpotify(query: String) async throws -> [SpotifySearchTrack] {
        try await authenticate()
        let response: SpotifySearchResponse = try await client.functions.invoke(
            "spotify-search",
            options: FunctionInvokeOptions(body: SpotifySearchParameters(query: query))
        )
        return response.tracks
    }

    func members(for sessionID: UUID) async throws -> [RemoteSessionMember] {
        try await client.from("session_members").select("profile_id,role,profiles(display_name)").eq("session_id", value: sessionID.uuidString).execute().value
    }

    func currentUserID() async throws -> UUID {
        try await authenticate()
        return try await client.auth.session.user.id
    }

    func add(track: HarmonyTrack, to sessionID: UUID, expectedRevision: Int) async throws -> Int {
        let canonicalTrackID: UUID
        if let spotify = track.mappings.first(where: { $0.provider == .spotify && !$0.providerID.isEmpty }) {
            let mapping: RemoteCanonicalTrackReference = try await client
                .from("provider_tracks")
                .select("canonical_track_id")
                .eq("provider", value: "spotify")
                .eq("provider_id", value: spotify.providerID)
                .single()
                .execute()
                .value
            canonicalTrackID = mapping.canonicalTrackID
        } else {
            let trackID: RemoteTrackID = try await client
                .from("canonical_tracks")
                .select("id")
                .eq("title", value: track.title)
                .eq("artist", value: track.artist)
                .single()
                .execute()
                .value
            canonicalTrackID = trackID.id
        }
        return try await executeCommand(QueueCommandParameters(
            p_session_id: sessionID,
            p_command_id: UUID(),
            p_expected_revision: expectedRevision,
            p_type: "add",
            p_payload: AddPayload(canonical_track_id: canonicalTrackID)
        ))
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
            .select("id,position,added_by,canonical_tracks(title,artist,album,duration_ms,artwork_url,provider_tracks(provider,provider_id,availability))")
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
    case revisionConflict, invalidResponse
    var errorDescription: String? {
        switch self {
        case .revisionConflict: return "The queue changed on another device. Refresh and try again."
        case .invalidResponse: return "Harmony received an invalid server response."
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

final class LivePresenceSubscription {
    let channel: RealtimeChannelV2
    let token: RealtimeSubscription

    init(channel: RealtimeChannelV2, token: RealtimeSubscription) {
        self.channel = channel
        self.token = token
    }
}
