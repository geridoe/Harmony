import Foundation
import OSLog

enum HarmonyLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "Harmony"

    static let authentication = Logger(subsystem: subsystem, category: "authentication")
    static let notifications = Logger(subsystem: subsystem, category: "notifications")
    static let network = Logger(subsystem: subsystem, category: "network")

    /// Returns stable diagnostic data without copying descriptions, tokens, URLs,
    /// email addresses, or server response bodies into device logs.
    static func safeFailure(_ error: Error) -> String {
        let value = error as NSError
        return "\(value.domain):\(value.code)"
    }
}
