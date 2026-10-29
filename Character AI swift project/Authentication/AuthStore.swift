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
            conversationRequests.clear()
            personas.setAccount(session?.userID)
            CharacterMessageMarkdown.clearCache()
            CharacterMessageFormattingView.clearCache()
        }
    }

    /// True only while a stored session is being validated at launch.
    @Published private(set) var isRestoringSession: Bool

    /// Why the last restore did not authenticate, shown on the login screen.
    @Published private(set) var authMessage: String?

    /// Identity from a previously validated Keychain session, never an authenticated session.
    @Published private(set) var offlineAccountID: String?
    @Published private(set) var isOfflineReading = false

    /// Non-secret session identity; caches are never keyed by tokens.
    private(set) var sessionGeneration = UUID()
    let personas: PersonaStore
    let resources = ResourceCache()
    let conversations = ResourceCache(countLimit: 8, costLimit: 32 * 1024 * 1024)
    let conversationRequests = ConversationRequestState()

    static let invalidSessionMessage = "Character.AI rejected this saved session. Sign in with a valid session token."
    static let unverifiedSessionMessage = "Couldn't verify your saved session. Check your connection and sign in again."

    private let storage: SessionStorage
    private static let sessionKey = "authSession"
    private static let webSessionCookieKey = "webSessionCookie"
    private var signInAttempt = 0
    private var hasStartedRestore = false
    private var cachedWebSessionCookie: String??

    var isAuthenticated: Bool {
        session != nil
    }

    init(
        storage: SessionStorage? = nil,
        session: AuthSession? = nil,
        personas: PersonaStore? = nil,
        restoreSession: Bool = true
    ) {
        self.storage = storage ?? KeychainStore()
        self.session = session
        self.personas = personas ?? PersonaStore()
        self.personas.setAccount(session?.userID)
        // Defer the Keychain read until restoreStoredSession so launch performs
        // one protected-item access instead of probing in init and reading again.
        self.isRestoringSession = session == nil && restoreSession
    }

    /// Validates the token with the server, then persists and publishes the
    /// session. Nothing is written or published when validation fails. A newer
    /// sign-in supersedes an older one, so a late outcome never replaces it.
    /// The token is the only thing the user supplies: the account ID and
    /// username come from the validated response.
    func signIn(
        sessionToken: String,
        validator: SessionValidator? = nil
    ) async throws {
        signInAttempt += 1
        let attempt = signInAttempt

        do {
            let account = try await (validator ?? SessionValidator()).validate(sessionToken: sessionToken)
            try Task.checkCancellation()
            guard attempt == signInAttempt else { throw CancellationError() }
            guard let resolvedUserID = account.userID else {
                throw SessionValidationError.accountIDUnavailable
            }
            try activate(AuthSession(
                sessionToken: sessionToken,
                userID: resolvedUserID,
                username: account.username ?? ""
            ))
        } catch {
            try Task.checkCancellation()
            guard attempt == signInAttempt else { throw CancellationError() }
            throw error
        }
    }

    /// Validates a session saved by an earlier launch before it can authenticate.
    /// A rejected session is removed; a session that could not be checked stays
    /// stored so the next launch can retry. Neither case authenticates.
    func restoreStoredSession(validator: SessionValidator? = nil) async {
        guard isRestoringSession, !hasStartedRestore else { return }
        hasStartedRestore = true
        signInAttempt += 1
        let attempt = signInAttempt
        defer { if attempt == signInAttempt { isRestoringSession = false } }

        let stored: AuthSession
        do {
            guard let data = try storage.loadData(forKey: AuthStore.sessionKey) else {
                // A cookie saved during an unfinished sign-in cannot be trusted
                // to belong to whoever signs in next.
                try? clearWebSessionCookie()
                return
            }
            stored = try JSONDecoder().decode(AuthSession.self, from: data)
        } catch {
            authLogger.error("Failed to read stored session: \(error.localizedDescription, privacy: .private)")
            clearStoredSession()
            return
        }

        do {
            let account = try await (validator ?? SessionValidator()).validate(sessionToken: stored.sessionToken)
            try Task.checkCancellation()
            guard attempt == signInAttempt else { return }
            guard let resolvedUserID = account.userID else {
                clearStoredSession()
                authMessage = "Your Character.AI account ID is unavailable. Sign in again with a valid session token."
                return
            }
            try activate(AuthSession(
                sessionToken: stored.sessionToken,
                userID: resolvedUserID,
                username: account.username ?? stored.username
            ))
        } catch SessionValidationError.invalidSession {
            guard attempt == signInAttempt, !Task.isCancelled else { return }
            clearStoredSession()
            authMessage = AuthStore.invalidSessionMessage
        } catch is CancellationError {
            return
        } catch {
            guard attempt == signInAttempt, !Task.isCancelled else { return }
            authLogger.error("Stored session could not be verified: \(error.localizedDescription, privacy: .private)")
            if error as? SessionValidationError == .unavailable,
               !stored.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                offlineAccountID = stored.userID
            }
            authMessage = AuthStore.unverifiedSessionMessage
        }
    }

    /// Explicit opt-in; does not publish an unvalidated session or allow requests.
    func enterOfflineReading() {
        guard session == nil, offlineAccountID != nil else { return }
        isOfflineReading = true
    }

    func exitOfflineReading() { isOfflineReading = false }

    func clearSession() {
        signInAttempt += 1
        isRestoringSession = false
        isOfflineReading = false
        offlineAccountID = nil
        session = nil
        clearStoredSession()
    }

    // MARK: - Web session cookie (character search)

    /// Optional `web-next-auth` cookie for Character.AI's search-results
    /// endpoint, which rejects the app's session token. It is stored beside
    /// the session in the Keychain and sent only to `character.ai` by
    /// `CharacterSearchService`.
    var hasWebSessionCookie: Bool { webSessionCookie() != nil }

    func webSessionCookie() -> String? {
        if let cachedWebSessionCookie { return cachedWebSessionCookie }
        let cookie = (try? storage.loadData(forKey: Self.webSessionCookieKey))
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap { try? WebSessionCookie.normalizedHeader(from: $0) }
        cachedWebSessionCookie = .some(cookie)
        return cookie
    }

    /// Validates and normalizes what the user pasted before anything is saved.
    /// Accepts either a complete `Cookie:` header or a bare token value.
    func saveWebSessionCookie(_ raw: String) throws {
        let header = try WebSessionCookie.normalizedHeader(from: raw)
        try storage.save(Data(header.utf8), forKey: Self.webSessionCookieKey)
        cachedWebSessionCookie = header
    }

    func clearWebSessionCookie() throws {
        try storage.delete(forKey: Self.webSessionCookieKey)
        cachedWebSessionCookie = nil
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
        offlineAccountID = nil
        isOfflineReading = false
        session = newSession
    }

    private func clearStoredSession() {
        do {
            try storage.delete(forKey: AuthStore.sessionKey)
        } catch {
            authLogger.error("Failed to clear stored session: \(error.localizedDescription, privacy: .private)")
        }
        // The search cookie belongs to the account that supplied it. Never
        // carry it across a sign-out or a rejected stored session into a
        // different account.
        try? clearWebSessionCookie()
    }
}

// MARK: - Web session cookie input

enum WebSessionCookieError: LocalizedError, Equatable {
    case empty
    case malformed
    case tooLong

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Paste a web session cookie, or leave the field empty."
        case .malformed:
            return "That doesn't look like a cookie. Copy the full Cookie header or just the session-token value."
        case .tooLong:
            return "That cookie is too long. Copy only the web session cookie."
        }
    }
}

/// Turns pasted search credentials into one safe `Cookie` header. The user may
/// paste the whole header from browser developer tools (`a=b; c=d`) or only the
/// token value; a bare value is named `web-next-auth`, matching Character.AI's
/// web client.
nonisolated enum WebSessionCookie {
    static let maxLength = 8_192
    static let defaultName = "web-next-auth"

    static func normalizedHeader(from raw: String) throws -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw WebSessionCookieError.empty }

        if value.lowercased().hasPrefix("cookie:") {
            value = String(value.dropFirst("cookie:".count))
                .trimmingCharacters(in: .whitespaces)
        }

        guard value.utf8.count <= maxLength else {
            throw WebSessionCookieError.tooLong
        }
        // A header value may not contain control characters or line breaks:
        // pasted text must never be able to add another HTTP header.
        guard value.unicodeScalars.allSatisfy({ scalar in
            scalar.isASCII && scalar.value >= 0x20 && scalar.value != 0x7F
        }) else {
            throw WebSessionCookieError.malformed
        }

        let normalized = try containsCookieName(value) || value.contains(";")
            ? normalizedCookiePairs(from: value)
            : normalizedBareValue(value)

        guard normalized.utf8.count <= maxLength else {
            throw WebSessionCookieError.tooLong
        }
        return normalized
    }

    private static func containsCookieName(_ value: String) -> Bool {
        value.range(
            of: #"^(?:__Secure-|__Host-)?(?:web-)?next-auth[^=;\s]*="#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func normalizedCookiePairs(from value: String) throws -> String {
        var pairs: [String] = []
        for rawPair in value.split(separator: ";", omittingEmptySubsequences: true) {
            let pair = rawPair.trimmingCharacters(in: .whitespaces)
            guard let separator = pair.firstIndex(of: "=") else {
                throw WebSessionCookieError.malformed
            }
            let name = pair[..<separator].trimmingCharacters(in: .whitespaces)
            let cookieValue = pair[pair.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty,
                  !cookieValue.isEmpty,
                  !name.contains(where: { $0.isWhitespace || $0 == "," || $0 == "\"" }) else {
                throw WebSessionCookieError.malformed
            }
            pairs.append("\(canonicalName(name))=\(cookieValue)")
        }
        guard !pairs.isEmpty else { throw WebSessionCookieError.malformed }
        return pairs.joined(separator: "; ")
    }

    /// Earlier builds guessed a NextAuth-style suffix for a bare value. Repair
    /// those saved/imported names so an existing Keychain item keeps working
    /// after the correction to the real cookie name.
    private static func canonicalName(_ name: String) -> String {
        let lowercased = name.lowercased()
        let legacyNames = [
            "web-next-auth.session-token",
            "__secure-web-next-auth.session-token",
            "__secure-next-auth.session-token",
            "next-auth.session-token"
        ]
        return legacyNames.contains(lowercased) ? defaultName : name
    }

    private static func normalizedBareValue(_ value: String) throws -> String {
        let lowercased = value.lowercased()
        guard !value.contains(";"),
              !value.contains(where: { $0.isWhitespace }),
              !lowercased.hasPrefix("token "),
              !lowercased.hasPrefix("bearer ") else {
            throw WebSessionCookieError.malformed
        }
        return "\(defaultName)=\(value)"
    }
}
