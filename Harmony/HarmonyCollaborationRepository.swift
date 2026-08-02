import Foundation
import Supabase

struct RemoteHarmonySession: Decodable {
    let id: UUID
    let title: String
    let inviteCode: String
    let queueRevision: Int

    enum CodingKeys: String, CodingKey {
        case id, title
        case inviteCode = "invite_code"
        case queueRevision = "queue_revision"
    }
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
private struct RemoteTrackID: Decodable { let id: UUID }
private struct QueueCommandResult: Decodable { let status: String; let revision: Int }

struct RemoteQueueSnapshot: Decodable {
    let id: UUID
    let position: Double
    let canonicalTrack: RemoteCatalogTrack

    enum CodingKeys: String, CodingKey {
        case id, position
        case canonicalTrack = "canonical_tracks"
    }
}

struct RemoteCatalogTrack: Decodable {
    let title: String
    let artist: String
    let album: String?
    let durationMilliseconds: Int?

    enum CodingKeys: String, CodingKey {
        case title, artist, album
        case durationMilliseconds = "duration_ms"
    }
}

@MainActor
final class HarmonyCollaborationRepository {
    private let client = HarmonySupabaseClient.shared

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

    func add(track: HarmonyTrack, to sessionID: UUID, expectedRevision: Int) async throws -> Int {
        let trackID: RemoteTrackID = try await client
            .from("canonical_tracks")
            .select("id")
            .eq("title", value: track.title)
            .eq("artist", value: track.artist)
            .single()
            .execute()
            .value
        let parameters = QueueCommandParameters(
            p_session_id: sessionID,
            p_command_id: UUID(),
            p_expected_revision: expectedRevision,
            p_type: "add",
            p_payload: AddPayload(canonical_track_id: trackID.id)
        )
        let result: QueueCommandResult = try await client
            .rpc("apply_queue_command", params: parameters)
            .execute()
            .value
        guard result.status == "applied" else { throw CollaborationError.revisionConflict }
        return result.revision
    }

    func queue(for sessionID: UUID) async throws -> [RemoteQueueSnapshot] {
        try await client
            .from("queue_items")
            .select("id,position,canonical_tracks(title,artist,album,duration_ms)")
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

    private static func makeInviteCode() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).uppercased()
    }
}

enum CollaborationError: LocalizedError {
    case revisionConflict
    var errorDescription: String? { "The queue changed on another device. Refresh and try again." }
}

final class LiveQueueSubscription {
    let channel: RealtimeChannelV2
    let token: RealtimeSubscription

    init(channel: RealtimeChannelV2, token: RealtimeSubscription) {
        self.channel = channel
        self.token = token
    }
}
