//
//  HarmonyApp.swift
//  Harmony
//
//  Created by Geri Doe on 7/25/22.
//

import SwiftUI

@main
struct HarmonyApp: App {
    @StateObject private var sessionStore: HarmonySessionStore

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
                .task { await sessionStore.bootstrap() }
                .onOpenURL { url in
                    sessionStore.handleOpenURL(url)
                }
        }
    }
}
