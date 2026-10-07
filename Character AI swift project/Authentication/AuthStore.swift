//
//  AuthStore.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 26/09/2026.
//

import Foundation
import Combine
import OSLog

private let authLogger = Logger(subsystem: "CharacterAI", category: "Authentication")

@MainActor
final class AuthStore: ObservableObject {
    @Published private(set) var session: AuthSession?

    private let keychainStore: KeychainStore
    private let sessionKey = "authSession"

    var isAuthenticated: Bool {
        session != nil
    }

    init(
        keychainStore: KeychainStore? = nil,
        session: AuthSession? = nil
    ) {
        self.keychainStore = keychainStore ?? KeychainStore()
        self.session = session
    }

    func setSession(_ session: AuthSession) {
        self.session = session

        do {
            let data = try JSONEncoder().encode(session)
            try keychainStore.save(data, forKey: sessionKey)
        } catch {
            authLogger.error("Failed to persist authenticated session: \(error.localizedDescription, privacy: .private)")
        }
    }

    func loadStoredSession() {
        do {
            guard let data = try keychainStore.loadData(forKey: sessionKey) else { return }
            self.session = try JSONDecoder().decode(AuthSession.self, from: data)
        } catch {
            authLogger.error("Failed to load stored session: \(error.localizedDescription, privacy: .private)")
        }
    }

    func clearSession() {
        session = nil

        do {
            try keychainStore.delete(forKey: sessionKey)
        } catch {
            authLogger.error("Failed to clear stored session: \(error.localizedDescription, privacy: .private)")
        }
    }
}
