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

/// Persistence for the signed-in session. The Keychain is the production store.
protocol SessionStorage {
    func save(_ data: Data, forKey key: String) throws
    func loadData(forKey key: String) throws -> Data?
    func delete(forKey key: String) throws
}

extension KeychainStore: SessionStorage {}

/// Owns the authenticated state. `session` is published only after the token
/// has been validated by the server, so no other layer can observe a session
/// that has not been accepted.
@MainActor
final class AuthStore: ObservableObject {
    @Published private(set) var session: AuthSession? {
        didSet {
            sessionGeneration = UUID()
            resources.clear()
            conversations.clear()
        }
    }

    /// True only while a stored session is being validated at launch.
    @Published private(set) var isRestoringSession: Bool

    /// Why the last restore did not authenticate, shown on the login screen.
    @Published private(set) var authMessage: String?

    /// Non-secret session identity; caches are never keyed by tokens.
    private(set) var sessionGeneration = UUID()
    let resources = ResourceCache()
    let conversations = ResourceCache(countLimit: 8, costLimit: 32 * 1024 * 1024)

    static let invalidSessionMessage = "Character.AI rejected this saved session. Sign in with a valid session ID."
    static let unverifiedSessionMessage = "Couldn't verify your saved session. Check your connection and sign in again."

    private let storage: SessionStorage
    private static let sessionKey = "authSession"
    private var signInAttempt = 0
    private var hasStartedRestore = false

    var isAuthenticated: Bool {
        session != nil
    }

    init(
        storage: SessionStorage = KeychainStore(),
        session: AuthSession? = nil
    ) {
        self.storage = storage
        self.session = session
        self.isRestoringSession = session == nil
            && (try? storage.loadData(forKey: AuthStore.sessionKey)) != nil
    }

    /// Validates the token with the server, then persists and publishes the
    /// session. Nothing is written or published when validation fails. A newer
    /// sign-in supersedes an older one, so a late outcome never replaces it.
    func signIn(
        sessionToken: String,
        userID: String,
        username: String,
        validator: SessionValidator = SessionValidator()
    ) async throws {
        signInAttempt += 1
        let attempt = signInAttempt

        do {
            let account = try await validator.validate(sessionToken: sessionToken)
            guard attempt == signInAttempt else { throw CancellationError() }
            try activate(AuthSession(
                sessionToken: sessionToken,
                userID: userID,
                username: account.username ?? username
            ))
        } catch {
            guard attempt == signInAttempt else { throw CancellationError() }
            throw error
        }
    }

    /// Validates a session saved by an earlier launch before it can authenticate.
    /// A rejected session is removed; a session that could not be checked stays
    /// stored so the next launch can retry. Neither case authenticates.
    func restoreStoredSession(validator: SessionValidator = SessionValidator()) async {
        guard isRestoringSession, !hasStartedRestore else { return }
        hasStartedRestore = true
        defer { isRestoringSession = false }

        let stored: AuthSession
        do {
            guard let data = try storage.loadData(forKey: AuthStore.sessionKey) else { return }
            stored = try JSONDecoder().decode(AuthSession.self, from: data)
        } catch {
            authLogger.error("Failed to read stored session: \(error.localizedDescription, privacy: .private)")
            clearStoredSession()
            return
        }

        do {
            let account = try await validator.validate(sessionToken: stored.sessionToken)
            try activate(AuthSession(
                sessionToken: stored.sessionToken,
                userID: stored.userID,
                username: account.username ?? stored.username
            ))
        } catch SessionValidationError.invalidSession {
            clearStoredSession()
            authMessage = AuthStore.invalidSessionMessage
        } catch is CancellationError {
            return
        } catch {
            authLogger.error("Stored session could not be verified: \(error.localizedDescription, privacy: .private)")
            authMessage = AuthStore.unverifiedSessionMessage
        }
    }

    func clearSession() {
        session = nil
        clearStoredSession()
    }

    /// Clears the session only when the failed request was made with the
    /// session that is still current. A late 401 from an older session or
    /// request therefore cannot remove a newer valid one.
    func invalidateSession(ifGeneration generation: UUID, authorization: String?) {
        guard generation == sessionGeneration,
              let current = session,
              authorization == "Token \(current.sessionToken)" else { return }
        clearSession()
    }

    private func activate(_ newSession: AuthSession) throws {
        // Called only with a session the server has accepted.
        do {
            let data = try JSONEncoder().encode(newSession)
            try storage.save(data, forKey: AuthStore.sessionKey)
        } catch {
            authLogger.error("Failed to persist authenticated session: \(error.localizedDescription, privacy: .private)")
            throw error
        }
        authMessage = nil
        session = newSession
    }

    private func clearStoredSession() {
        do {
            try storage.delete(forKey: AuthStore.sessionKey)
        } catch {
            authLogger.error("Failed to clear stored session: \(error.localizedDescription, privacy: .private)")
        }
    }
}
