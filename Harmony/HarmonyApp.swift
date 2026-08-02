//
//  HarmonyApp.swift
//  Harmony
//
//  Created by Geri Doe on 7/25/22.
//

import SwiftUI

@main
struct HarmonyApp: App {
    @StateObject private var sessionStore = HarmonySessionStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sessionStore)
        }
    }
}
