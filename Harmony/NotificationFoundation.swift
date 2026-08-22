import Foundation
import Combine
import UIKit
import UserNotifications

enum HarmonyNotificationDestination: Equatable, Identifiable {
    case review(UUID)
    case musicList(UUID)
    case broadcast(UUID)
    case profile(UUID)
    case session(UUID)

    var id: String {
        switch self {
        case .review(let id): return "review:\(id)"
        case .musicList(let id): return "list:\(id)"
        case .broadcast(let id): return "broadcast:\(id)"
        case .profile(let id): return "profile:\(id)"
        case .session(let id): return "session:\(id)"
        }
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let kind = userInfo["kind"] as? String else { return nil }
        func identifier(_ key: String) -> UUID? {
            (userInfo[key] as? String).flatMap(UUID.init(uuidString:))
        }
        switch kind {
        case "review", "review_comment", "review_reaction":
            guard let id = identifier("review_id") else { return nil }
            self = .review(id)
        case "broadcast", "broadcast_comment", "broadcast_reaction":
            guard let id = identifier("broadcast_id") else { return nil }
            self = .broadcast(id)
        case "music_list_comment", "music_list_like":
            guard let id = identifier("music_list_id") else { return nil }
            self = .musicList(id)
        case "follow", "follow_request", "follow_accepted":
            guard let id = identifier("profile_id") ?? identifier("actor_id") else { return nil }
            self = .profile(id)
        case "session_invite":
            guard let id = identifier("session_id") else { return nil }
            self = .session(id)
        default:
            return nil
        }
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == "harmony",
              url.host?.lowercased() == "notification" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
        switch parts[0] {
        case "review": self = .review(id)
        case "list": self = .musicList(id)
        case "broadcast": self = .broadcast(id)
        case "profile": self = .profile(id)
        case "session": self = .session(id)
        default: return nil
        }
    }

    var url: URL? {
        let route: String
        switch self {
        case .review(let id): route = "review/\(id.uuidString)"
        case .musicList(let id): route = "list/\(id.uuidString)"
        case .broadcast(let id): route = "broadcast/\(id.uuidString)"
        case .profile(let id): route = "profile/\(id.uuidString)"
        case .session(let id): route = "session/\(id.uuidString)"
        }
        return URL(string: "harmony://notification/\(route)")
    }
}

struct HarmonyNotificationPreferences: Codable, Equatable {
    var follows = true
    var socialActivity = true
    var sessions = true
    var liveListening = true
}

@MainActor
final class HarmonyNotificationController: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = HarmonyNotificationController()
    static let destinationNotification = Notification.Name("HarmonyNotificationDestination")

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published var preferences: HarmonyNotificationPreferences {
        didSet { persistPreferences() }
    }

    private let preferencesKey = "harmony.notification-preferences.v1"
    private let registeredDeviceKey = "harmony.notification-device-id.v1"
    private let repository = HarmonyCollaborationRepository()
    private var preferenceSyncTask: Task<Void, Never>?

    override private init() {
        if let data = UserDefaults.standard.data(forKey: preferencesKey),
           let stored = try? JSONDecoder().decode(HarmonyNotificationPreferences.self, from: data) {
            preferences = stored
        } else {
            preferences = HarmonyNotificationPreferences()
        }
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func refreshAuthorization() async {
        authorizationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestAuthorizationAndRegister() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            await refreshAuthorization()
            guard granted else { return }
            UIApplication.shared.registerForRemoteNotifications()
            HarmonyLog.notifications.info("Notification authorization granted")
        } catch {
            HarmonyLog.notifications.error("Notification authorization failed: \(HarmonyLog.safeFailure(error), privacy: .public)")
        }
    }

    func register(deviceToken: Data) async {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
#if DEBUG
        let environment = "sandbox"
#else
        let environment = "production"
#endif
        do {
            let id = try await repository.registerNotificationDevice(
                token: token,
                environment: environment,
                bundleID: bundleID,
                label: UIDevice.current.model
            )
            UserDefaults.standard.set(id.uuidString, forKey: registeredDeviceKey)
            HarmonyLog.notifications.info("APNs device registration persisted")
        } catch {
            HarmonyLog.notifications.error("APNs device persistence failed: \(HarmonyLog.safeFailure(error), privacy: .public)")
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let destination = HarmonyNotificationDestination(userInfo: info) else { return }
        await MainActor.run {
            NotificationCenter.default.post(
                name: Self.destinationNotification,
                object: destination
            )
        }
    }

    private func persistPreferences() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        UserDefaults.standard.set(data, forKey: preferencesKey)
        preferenceSyncTask?.cancel()
        let snapshot = preferences
        preferenceSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            do {
                try await self.repository.setNotificationPreferences(snapshot)
            } catch {
                HarmonyLog.notifications.error("Notification preference sync failed: \(HarmonyLog.safeFailure(error), privacy: .public)")
            }
        }
    }
}

final class HarmonyAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        HarmonyLog.notifications.info("APNs device registration succeeded")
        Task { @MainActor in
            await HarmonyNotificationController.shared.register(deviceToken: deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        HarmonyLog.notifications.error("APNs registration failed: \(HarmonyLog.safeFailure(error), privacy: .public)")
    }
}
