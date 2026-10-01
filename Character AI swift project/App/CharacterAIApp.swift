//
//  CharacterAIApp.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 26/09/2026.
//

import SwiftUI

@main
struct CharacterAIApp: App {
    @StateObject private var authStore: AuthStore

    init() {
        let authStore = AuthStore()

        print("AUTH STORE CREATED")
        authStore.loadStoredSession()

        _authStore = StateObject(wrappedValue: authStore)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(authStore)
        }

        SettingsScene
    }

    private var SettingsScene: some Scene {
        Settings {
            SettingsView(username: authStore.session?.username ?? "")
        }
    }
}
