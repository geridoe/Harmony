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

    private static func makeInviteCode() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).uppercased()
    }
}
