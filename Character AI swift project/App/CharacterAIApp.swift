//
//  CharacterAIApp.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 26/09/2026.
//

import SwiftUI

@main
struct CharacterAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var authStore: AuthStore

    init() {
        // Release smoke tests can show the signed-out UI without reading saved credentials.
        let authStore = AuthStore(restoreSession: !CommandLine.arguments.contains("--no-session-restore"))

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
            SettingsView(
                username: authStore.session?.username ?? "",
                authStore: authStore
            )
        }
        .windowBackgroundDragBehavior(.enabled)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        LocalOllamaLifecycle.shared.applicationWillTerminate()
    }
}
