import Foundation
import Supabase

enum HarmonySupabaseConfiguration {
    static let projectURL: URL = requiredURL(for: "SupabaseURL")
    static let publishableKey: String = requiredString(for: "SupabasePublishableKey")
    static let spotifyClientID: String = requiredString(for: "SpotifyClientID")
    static let spotifyRedirectURI: URL = requiredURL(for: "SpotifyRedirectURI")

    private static func requiredURL(for key: String) -> URL {
        guard let url = URL(string: requiredString(for: key)) else {
            preconditionFailure("Missing or invalid \(key) in Info.plist")
        }
        return url
    }

    private static func requiredString(for key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty else {
            preconditionFailure("Missing \(key) in Info.plist")
        }
        return value
    }
}

@MainActor
final class HarmonySupabaseClient {
    static let shared = SupabaseClient(
        supabaseURL: HarmonySupabaseConfiguration.projectURL,
        supabaseKey: HarmonySupabaseConfiguration.publishableKey
    )
}
