import Foundation
import Combine

// Synthetic fixtures only; no real credentials appear here or in output.
nonisolated struct Probe: Decodable, Sendable {}

// URLProtocol calls arrive on Foundation queues; shared fixture state is locked.
nonisolated final class AuthStubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        let status: Int
        let body: Data
        var delay: TimeInterval = 0
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var validationReplies: [String: Reply] = [:]
    nonisolated(unsafe) private static var accountReplies: [String: Reply] = [:]
    nonisolated(unsafe) private static var dataReplies: [String: Reply] = [:]
    nonisolated(unsafe) private static var requestLog: [(String, String, String)] = []

    static func configure(
        validation: [String: Reply],
        accounts: [String: Reply] = [:],
        data: [String: Reply]
    ) {
        lock.lock()
        defer { lock.unlock() }
        validationReplies = validation
        accountReplies = accounts
        dataReplies = data
        requestLog = []
    }

    static var requests: [(String, String, String)] {
        lock.lock()
        defer { lock.unlock() }
        return requestLog
    }

    static func reply(host: String, path: String, token: String) -> Reply {
        lock.lock()
        defer { lock.unlock() }
        let table: [String: Reply]
        if path.contains("get_user_personas") {
            table = validationReplies
        } else if host == "plus.character.ai" && path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "chat/user" {
            table = accountReplies
        } else {
            table = dataReplies
        }
        return table[token] ?? Reply(status: 500, body: Data())
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "neo.character.ai" || request.url?.host == "plus.character.ai"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requestLog.append((request.url?.host ?? "", request.url?.path ?? "", request.value(forHTTPHeaderField: "Authorization") ?? ""))
        Self.lock.unlock()
        let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let token = authorization.hasPrefix("Token ")
            ? String(authorization.dropFirst("Token ".count))
            : ""
        let reply = Self.reply(
            host: request.url?.host ?? "",
            path: request.url?.path ?? "",
            token: token
        )
        let deliver: @Sendable () -> Void = { [self] in
            guard let url = request.url,
                  let response = HTTPURLResponse(
                    url: url,
                    statusCode: reply.status,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                  ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        if reply.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: deliver)
        } else {
            deliver()
        }
    }

    override func stopLoading() {}
}

final class InMemorySessionStorage: SessionStorage {
    var data: Data?
    private(set) var loadCount = 0

    func save(_ data: Data, forKey key: String) throws { self.data = data }
    func loadData(forKey key: String) throws -> Data? {
        loadCount += 1
        return data
    }
    func delete(forKey key: String) throws { data = nil }
}

private func personasBody(username: String?) -> Data {
    let usernameField = username.map { ",\"user__username\":\"\($0)\"" } ?? ""
    return Data("{\"personas\":[{\"id\":1,\"external_id\":\"persona-1\",\"title\":\"Synthetic\"\(usernameField)}]}".utf8)
}

@main
@MainActor
struct AuthChecks {
    static var failures: [String] = []
    static let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthStubProtocol.self]
        return URLSession(configuration: configuration)
    }()
    static var validator: SessionValidator { SessionValidator(session: urlSession) }
    static let dataURL = URL(string: "https://neo.character.ai/character/v1/get_character_info")!

    static func expect(_ condition: Bool, _ name: String) {
        if condition { print("PASS \(name)") }
        else { failures.append(name); print("FAIL \(name)") }
    }
    static func makeStore(_ storage: InMemorySessionStorage? = nil) -> AuthStore {
        AuthStore(storage: storage ?? InMemorySessionStorage())
    }
    static func storedSession(_ storage: InMemorySessionStorage) -> AuthSession? {
        guard let data = storage.data else { return nil }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }
    static func encodedSession(token: String, username: String) -> Data {
        try! JSONEncoder().encode(AuthSession(sessionToken: token, userID: "", username: username))
    }
    static func isCancellation<T>(_ result: Result<T, Error>) -> Bool {
        if case .failure(let error) = result { return error is CancellationError }
        return false
    }

    static func validSessionWithoutTypedFields() async throws {
        let storage = InMemorySessionStorage()
        let store = makeStore(storage)
        try await store.signIn(sessionToken: "VALID_SESSION", validator: validator)
        expect(store.isAuthenticated, "valid session without typed fields authenticates")
        expect(store.session?.username == "USER_123", "username resolves from the authenticated identity field")
        expect(store.session?.userID == "123456", "account ID resolves from the authenticated account endpoint")
        expect(storedSession(storage)?.sessionToken == "VALID_SESSION", "validated session is persisted")
    }

    static func accountEndpointSupportsStringIDs() async throws {
        let store = makeStore()
        try await store.signIn(sessionToken: "STRING_ACCOUNT_ID", validator: validator)
        expect(store.session?.userID == "account-string-id", "account endpoint string IDs are preserved")
    }

    static func identityComesFromServer() async throws {
        let store = makeStore()
        try await store.signIn(sessionToken: "VALID_SESSION", validator: validator)
        expect(store.session?.username == "USER_123", "username comes only from the validated response")
        expect(store.session?.userID == "123456", "account ID comes only from the authenticated endpoint")
    }

    static func accountEndpointSupportsTopLevelUserID() async throws {
        let store = makeStore()
        try await store.signIn(sessionToken: "TOP_LEVEL_ACCOUNT_ID", validator: validator)
        expect(store.session?.userID == "top-level-account-id", "top-level account user_id is resolved")
    }

    static func accountEndpointSupportsUserExternalID() async throws {
        let store = makeStore()
        try await store.signIn(sessionToken: "EXTERNAL_ACCOUNT_ID", validator: validator)
        expect(store.session?.userID == "7654321", "account user__id is resolved")
    }

    static func missingAccountIDIsRejectedWithoutPersisting() async throws {
        let storage = InMemorySessionStorage()
        let store = makeStore(storage)
        var thrown: Error?
        do { try await store.signIn(sessionToken: "MISSING_ACCOUNT_ID", validator: validator) }
        catch { thrown = error }
        expect(thrown as? SessionValidationError == .accountIDUnavailable, "login rejects an empty account ID")
        expect(!store.isAuthenticated && storage.data == nil, "login with no account ID never authenticates or persists")
    }

    static func accountIDEndpointUsesAuthenticatedToken() async throws {
        try await makeStore().signIn(sessionToken: "VALID_SESSION", validator: validator)
        let accountRequest = AuthStubProtocol.requests.first { $0.0 == "plus.character.ai" }
        expect(accountRequest?.1.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "chat/user", "account ID uses the account endpoint")
        expect(accountRequest?.2 == "Token VALID_SESSION", "account ID request authenticates with the session")
    }

    static func missingAPIUsernameStaysEmpty() async throws {
        let store = makeStore()
        try await store.signIn(sessionToken: "VALID_NO_USERNAME", validator: validator)
        expect(store.isAuthenticated, "valid session without API username still authenticates")
        expect(store.session?.username == "", "missing API username stays empty rather than fabricating identity")
    }

    static func invalidSessionNeverPublishesAuthentication() async throws {
        let storage = InMemorySessionStorage()
        let store = makeStore(storage)
        var published: [Bool] = []
        var cancellables = Set<AnyCancellable>()
        store.$session.sink { published.append($0 != nil) }.store(in: &cancellables)
        var thrown: Error?
        do { try await store.signIn(sessionToken: "INVALID_SESSION", validator: validator) }
        catch { thrown = error }
        expect(thrown as? SessionValidationError == .invalidSession, "invalid session produces an invalid-session error")
        expect(!store.isAuthenticated, "invalid session does not authenticate")
        expect(published.allSatisfy { !$0 }, "authenticated state is never published for an invalid session")
        expect(storage.data == nil, "invalid session is not persisted")
        withExtendedLifetime(cancellables) {}
    }

    static func unverifiedSessionIsNotAuthenticated() async throws {
        let storage = InMemorySessionStorage()
        let store = makeStore(storage)
        var thrown: Error?
        do { try await store.signIn(sessionToken: "UNVERIFIED_SESSION", validator: validator) }
        catch { thrown = error }
        expect(thrown as? SessionValidationError == .unavailable, "unverifiable session reports unavailable, not invalid")
        expect(!store.isAuthenticated && storage.data == nil, "unverifiable session neither authenticates nor persists")
    }

    static func failedLoginDoesNotPoisonNextAttempt() async throws {
        let storage = InMemorySessionStorage()
        let store = makeStore(storage)
        do { try await store.signIn(sessionToken: "INVALID_SESSION", validator: validator) }
        catch {}
        expect(!store.isAuthenticated, "failed attempt leaves the user signed out")
        try await store.signIn(sessionToken: "VALID_SESSION", validator: validator)
        expect(store.isAuthenticated && store.session?.username == "USER_123", "valid login after a failure authenticates normally")
        expect(storedSession(storage)?.sessionToken == "VALID_SESSION", "valid login after a failure is persisted")
    }

    static func lateFailureFromOlderSignInCannotReplaceNewer() async throws {
        let store = makeStore()
        let older = Task { try await store.signIn(sessionToken: "SLOW_INVALID", validator: validator) }
        try await Task.sleep(nanoseconds: 50_000_000)
        try await store.signIn(sessionToken: "VALID_SESSION", validator: validator)
        let result = await older.result
        expect(isCancellation(result), "older failed sign-in is superseded, not reported as a login error")
        expect(store.session?.username == "USER_123", "late failure leaves the newer valid session in place")
    }

    static func lateSuccessFromOlderSignInCannotReplaceNewer() async throws {
        let store = makeStore()
        let older = Task { try await store.signIn(sessionToken: "SLOW_VALID", validator: validator) }
        try await Task.sleep(nanoseconds: 50_000_000)
        try await store.signIn(sessionToken: "NEW_SESSION", validator: validator)
        let result = await older.result
        expect(isCancellation(result), "older successful sign-in cannot overwrite a newer one")
        expect(store.session?.username == "NEW_USER", "newer session remains current after an older success completes")
    }

    static func late401FromOlderSessionCannotClearNewerSession() async throws {
        let store = makeStore()
        try await store.signIn(sessionToken: "OLD_SESSION", validator: validator)
        let client = AuthenticatedHTTPClient(session: urlSession, authStore: store)
        let inFlight = Task { () -> Void in let _: Probe = try await client.get(dataURL) }
        try await Task.sleep(nanoseconds: 50_000_000)
        try await store.signIn(sessionToken: "NEW_SESSION", validator: validator)
        _ = try? await inFlight.value
        expect(store.session?.username == "NEW_USER", "late 401 from the old session does not clear the new session")
    }

    static func late401AfterSameTokenResignInCannotClearNewSession() async throws {
        let store = makeStore()
        try await store.signIn(sessionToken: "OLD_SESSION", validator: validator)
        let client = AuthenticatedHTTPClient(session: urlSession, authStore: store)
        let inFlight = Task { () -> Void in let _: Probe = try await client.get(dataURL) }
        try await Task.sleep(nanoseconds: 50_000_000)
        store.clearSession()
        try await store.signIn(sessionToken: "OLD_SESSION", validator: validator)
        _ = try? await inFlight.value
        expect(store.isAuthenticated, "late 401 from a previous session with the same token does not clear the re-established session")
    }

    static func current401ClearsSessionAndStorage() async throws {
        let storage = InMemorySessionStorage()
        let store = makeStore(storage)
        try await store.signIn(sessionToken: "CURRENT_401", validator: validator)
        let client = AuthenticatedHTTPClient(session: urlSession, authStore: store)
        var thrown: Error?
        do { let _: Probe = try await client.get(dataURL) } catch { thrown = error }
        expect(thrown as? NetworkError != nil, "401 on the current session surfaces as an authentication failure")
        expect(!store.isAuthenticated, "401 on the current session signs the user out")
        expect(storage.data == nil, "401 on the current session removes the stored session")
    }

    static func restoreRejectsInvalidStoredSession() async throws {
        let storage = InMemorySessionStorage()
        storage.data = encodedSession(token: "INVALID_SESSION", username: "STALE_NAME")
        let store = makeStore(storage)
        expect(store.isRestoringSession, "stored session holds the app in restoring state until validated")
        expect(!store.isAuthenticated, "stored session is not authenticated before validation")
        await store.restoreStoredSession(validator: validator)
        expect(!store.isAuthenticated, "rejected stored session does not authenticate")
        expect(!store.isRestoringSession, "restore completes after rejection")
        expect(storage.data == nil, "rejected stored session is removed")
        expect(store.authMessage == AuthStore.invalidSessionMessage, "rejected stored session explains why login is required")
    }

    static func restoreAcceptsValidStoredSessionOnlyAfterValidation() async throws {
        let storage = InMemorySessionStorage()
        storage.data = encodedSession(token: "VALID_SESSION", username: "STALE_NAME")
        let store = makeStore(storage)
        expect(storage.loadCount == 0, "AuthStore initialization does not access Keychain")
        expect(!store.isAuthenticated, "stored session is not authenticated before restore runs")
        await store.restoreStoredSession(validator: validator)
        expect(storage.loadCount == 1, "launch restoration reads the stored session once")
        expect(store.isAuthenticated, "valid stored session authenticates after validation")
        expect(store.session?.username == "USER_123", "restored session uses the validated identity")
        expect(store.session?.userID == "123456", "restored session refreshes the account ID")
        expect(!store.isRestoringSession, "restore completes after success")
    }

    static func restoreKeepsStoredSessionWhenUnverified() async throws {
        let storage = InMemorySessionStorage()
        storage.data = encodedSession(token: "UNVERIFIED_SESSION", username: "STORED_NAME")
        let store = makeStore(storage)
        await store.restoreStoredSession(validator: validator)
        expect(!store.isAuthenticated, "unverifiable stored session does not authenticate")
        expect(storage.data != nil, "unverifiable stored session is kept for a later retry")
        expect(store.authMessage == AuthStore.unverifiedSessionMessage, "unverifiable stored session explains the state")
    }

    static func offlineReadingRequiresPreviouslyStoredIdentity() async throws {
        let storage = InMemorySessionStorage()
        storage.data = try JSONEncoder().encode(AuthSession(sessionToken: "UNVERIFIED_SESSION", userID: "account-a", username: "fixture"))
        let store = makeStore(storage)
        await store.restoreStoredSession(validator: validator)
        expect(!store.isAuthenticated && store.offlineAccountID == "account-a", "offline identity is separate from authentication")
        store.enterOfflineReading()
        expect(store.isOfflineReading && store.session == nil, "offline reading never publishes a session")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("veyrin-offline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let history = CharacterAIHistoryStore(supportDirectory: root)
        let summary = ConversationSummary(id: "chat", chatID: "chat", characterID: "character", characterName: "Fixture", characterAvatarURI: "", lastUpdated: "", state: "STATE_ACTIVE", lastMessage: nil)
        let turn = Turn(turnID: "turn", chatID: "chat", authorID: "character", authorName: "Fixture", isHuman: false, candidates: [Candidate(candidateId: "candidate", rawContent: "fixture", isFinal: true)], primaryCandidateID: "candidate")
        try history.save(accountID: "account-a", summary: summary, turns: [turn])
        let model = ChatViewModel(authStore: store, historyStore: history)
        let requestsBefore = AuthStubProtocol.requests.count
        await model.loadRecentChats()
        await model.loadConversationHistory(chatID: "chat", characterID: "character", summary: summary)
        expect(model.recentChats.map(\.chatID) == ["chat"] && model.turns == [turn], "offline sidebar and conversation load saved data")
        expect(model.isHistoryReadOnly && AuthStubProtocol.requests.count == requestsBefore, "offline history is read-only and sends no fixture requests")
        store.exitOfflineReading()
        expect(!store.isOfflineReading && storage.data != nil, "leaving offline reading keeps the stored session")
        store.clearSession()
        store.enterOfflineReading()
        expect(!store.isOfflineReading && store.offlineAccountID == nil, "sign out removes offline access")
    }

    static func main() async {
        AuthStubProtocol.configure(
            validation: [
                "VALID_SESSION": .init(status: 200, body: personasBody(username: "USER_123")),
                "VALID_NO_USERNAME": .init(status: 200, body: personasBody(username: nil)),
                "INVALID_SESSION": .init(status: 401, body: Data()),
                "UNVERIFIED_SESSION": .init(status: 500, body: Data()),
                "SLOW_INVALID": .init(status: 401, body: Data(), delay: 0.3),
                "SLOW_VALID": .init(status: 200, body: personasBody(username: "USER_123"), delay: 0.3),
                "OLD_SESSION": .init(status: 200, body: personasBody(username: "OLD_USER")),
                "NEW_SESSION": .init(status: 200, body: personasBody(username: "NEW_USER")),
                "CURRENT_401": .init(status: 200, body: personasBody(username: "CURRENT_USER")),
                "STRING_ACCOUNT_ID": .init(status: 200, body: personasBody(username: "STRING_USER")),
                "TOP_LEVEL_ACCOUNT_ID": .init(status: 200, body: personasBody(username: "TOP_USER")),
                "EXTERNAL_ACCOUNT_ID": .init(status: 200, body: personasBody(username: "EXTERNAL_USER")),
                "MISSING_ACCOUNT_ID": .init(status: 200, body: personasBody(username: "NO_ID_USER")),
            ],
            accounts: [
                "VALID_SESSION": .init(status: 200, body: Data("{\"user\":{\"user\":{\"id\":123456}}}".utf8)),
                "VALID_NO_USERNAME": .init(status: 200, body: Data("{\"user\":{\"user\":{\"id\":123456}}}".utf8)),
                "SLOW_VALID": .init(status: 200, body: Data("{\"user\":{\"user\":{\"id\":123456}}}".utf8)),
                "OLD_SESSION": .init(status: 200, body: Data("{\"user\":{\"user\":{\"id\":123456}}}".utf8)),
                "NEW_SESSION": .init(status: 200, body: Data("{\"user\":{\"user\":{\"id\":123456}}}".utf8)),
                "CURRENT_401": .init(status: 200, body: Data("{\"user\":{\"user\":{\"id\":123456}}}".utf8)),
                "STRING_ACCOUNT_ID": .init(status: 200, body: Data("{\"user\":{\"user\":{\"id\":\"account-string-id\"}}}".utf8)),
                "TOP_LEVEL_ACCOUNT_ID": .init(status: 200, body: Data("{\"user_id\":\"top-level-account-id\"}".utf8)),
                "EXTERNAL_ACCOUNT_ID": .init(status: 200, body: Data("{\"user\":{\"user__id\":7654321}}".utf8)),
                "MISSING_ACCOUNT_ID": .init(status: 200, body: Data("{\"user\":{\"user\":{\"id\":null}}}".utf8)),
            ],
            data: [
                "OLD_SESSION": .init(status: 401, body: Data(), delay: 0.3),
                "CURRENT_401": .init(status: 401, body: Data()),
            ]
        )

        let tests: [(String, @MainActor () async throws -> Void)] = [
            ("valid session without typed fields", validSessionWithoutTypedFields),
            ("account endpoint supports string IDs", accountEndpointSupportsStringIDs),
            ("account endpoint supports top-level ID", accountEndpointSupportsTopLevelUserID),
            ("account endpoint supports external ID", accountEndpointSupportsUserExternalID),
            ("missing account ID rejected", missingAccountIDIsRejectedWithoutPersisting),
            ("account ID uses authenticated route", accountIDEndpointUsesAuthenticatedToken),
            ("identity comes from server", identityComesFromServer),
            ("missing API username stays empty", missingAPIUsernameStaysEmpty),
            ("invalid session never publishes", invalidSessionNeverPublishesAuthentication),
            ("unverified session not authenticated", unverifiedSessionIsNotAuthenticated),
            ("failed login then valid login", failedLoginDoesNotPoisonNextAttempt),
            ("late failure from older sign-in", lateFailureFromOlderSignInCannotReplaceNewer),
            ("late success from older sign-in", lateSuccessFromOlderSignInCannotReplaceNewer),
            ("late 401 from older session", late401FromOlderSessionCannotClearNewerSession),
            ("late 401 after same-token re-sign-in", late401AfterSameTokenResignInCannotClearNewSession),
            ("current 401 clears session", current401ClearsSessionAndStorage),
            ("restore rejects invalid stored session", restoreRejectsInvalidStoredSession),
            ("restore accepts valid stored session after validation", restoreAcceptsValidStoredSessionOnlyAfterValidation),
            ("restore keeps unverified stored session", restoreKeepsStoredSessionWhenUnverified),
            ("offline reading uses a prior identity without authentication", offlineReadingRequiresPreviouslyStoredIdentity),
        ]
        for (name, test) in tests {
            do { try await test() }
            catch { expect(false, "\(name) threw an unexpected error") }
        }
        if failures.isEmpty { print("Auth checks passed (\(tests.count) scenarios)") }
        else { print("Auth checks failed: \(failures.count)"); exit(1) }
    }
}
