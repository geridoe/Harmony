//
//  HarmonyApp.swift
//  Harmony
//
//  Created by Geri Doe on 7/25/22.
//

import SwiftUI

@main
struct HarmonyApp: App {
    @UIApplicationDelegateAdaptor(HarmonyAppDelegate.self) private var appDelegate
    @StateObject private var sessionStore: HarmonySessionStore
    @StateObject private var accountController = HarmonyAccountController()
    @StateObject private var notificationController = HarmonyNotificationController.shared

    init() {
        let store = HarmonySessionStore(seedSampleData: false)
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-test-collaborator-reordering-allowed") {
            store.seedCollaboratorReorderingUITestFixture(allowed: true)
        } else if arguments.contains("--ui-test-collaborator-reordering-disabled") {
            store.seedCollaboratorReorderingUITestFixture(allowed: false)
        } else if arguments.contains("--ui-test-diary-editor") {
            store.seedDiaryEditorUITestFixture()
        }
#endif
        _sessionStore = StateObject(wrappedValue: store)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sessionStore)
                .environmentObject(accountController)
                .environmentObject(notificationController)
                .task {
                    async let storeBootstrap: Void = sessionStore.bootstrap()
                    async let accountBootstrap: Void = accountController.bootstrap()
                    async let notificationBootstrap: Void = notificationController.refreshAuthorization()
                    _ = await (storeBootstrap, accountBootstrap, notificationBootstrap)
                }
                .onOpenURL { url in
                    sessionStore.handleOpenURL(url)
                }
                .onReceive(NotificationCenter.default.publisher(for: HarmonyNotificationController.destinationNotification)) { event in
                    guard let destination = event.object as? HarmonyNotificationDestination,
                          let url = destination.url else { return }
                    sessionStore.handleOpenURL(url)
                }
        }
    }
}
