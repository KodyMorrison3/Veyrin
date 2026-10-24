import AppKit
import Combine
import Foundation
import SwiftUI
import ZipArchive

nonisolated final class OllamaCheckProtocol: URLProtocol, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var unavailableRequests = 0
        var requests = 0
    }
    private static let state = State()

    static func reset(unavailableRequests: Int = 0) {
        state.lock.lock(); defer { state.lock.unlock() }
        state.unavailableRequests = unavailableRequests
        state.requests = 0
    }

    static var requestCount: Int {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.requests
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.port == 11434 }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.state.lock.lock()
        Self.state.requests += 1
        let unavailable = Self.state.unavailableRequests > 0
        if unavailable { Self.state.unavailableRequests -= 1 }
        Self.state.lock.unlock()
        if unavailable {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"] )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"models":[{"name":"test-model"}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

nonisolated final class CheckProtocol: URLProtocol, @unchecked Sendable {
    // URLProtocol callbacks run on Foundation queues; every state access uses this lock.
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var requests: [String: Int] = [:]
        var delay: TimeInterval = 0
        var pageSize = 2
        var pageCount = 2
        var failure: Int?
        var searchRefusal = false
        var lastSearchCookie: String?
        var lastSearchOrigin: String?
        var lastSearchAuthorization: String?
    }
    private static let state = State()
    private var work: DispatchWorkItem?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    static func reset(
        delay: TimeInterval = 0,
        pageSize: Int = 2,
        pageCount: Int = 2,
        failure: Int? = nil,
        searchRefusal: Bool = false
    ) {
        state.lock.lock(); defer { state.lock.unlock() }
        state.requests = [:]; state.delay = delay; state.pageSize = pageSize; state.pageCount = pageCount
        state.failure = failure; state.searchRefusal = searchRefusal
        state.lastSearchCookie = nil; state.lastSearchOrigin = nil
        state.lastSearchAuthorization = nil
    }
    static func count(_ path: String? = nil) -> Int {
        state.lock.lock(); defer { state.lock.unlock() }
        return path.map { state.requests[$0, default: 0] } ?? state.requests.values.reduce(0, +)
    }
    static var lastSearchCookie: String? {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.lastSearchCookie
    }
    static var lastSearchOrigin: String? {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.lastSearchOrigin
    }
    static var lastSearchAuthorization: String? {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.lastSearchAuthorization
    }
    override func startLoading() {
        let path = request.url!.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        Self.state.lock.lock()
        Self.state.requests[path, default: 0] += 1
        let delay = Self.state.delay, size = Self.state.pageSize, pages = Self.state.pageCount
        let failure = Self.state.failure, searchRefusal = Self.state.searchRefusal
        if path == "api/trpc/search.search" {
            Self.state.lastSearchCookie = request.value(forHTTPHeaderField: "Cookie")
            Self.state.lastSearchOrigin = request.value(forHTTPHeaderField: "Origin")
            Self.state.lastSearchAuthorization = request.value(forHTTPHeaderField: "Authorization")
        }
        Self.state.lock.unlock()
        let account = request.value(forHTTPHeaderField: "Authorization")?.contains("account-b") == true ? "b" : "a"
        let body: String
        switch path {
        case "character/v1/get_user_personas":
            body = "{\"personas\":[{\"id\":1,\"external_id\":\"persona-\(account)\",\"title\":\"Persona \(account)\",\"definition\":\"Private \(account)\",\"user__username\":\"user-\(account)\"}]}"
        case "chat/user/settings":
            body = "{\"personaSettings\":{\"defaultPersonaId\":\"persona-\(account)\",\"characterOverrides\":{\"character\":\"persona-\(account)\"}}}"
        case "chat/user": body = "{\"id\":\"account-\(account)\"}"
        case "api/trpc/social.publicProfile":
            let profileCharacters = account == "a"
                ? "[{\"external_id\":\"own-character\",\"name\":\"My Character\",\"title\":\"My title\",\"description\":\"Owned profile character\",\"greeting\":\"Welcome back\",\"visibility\":\"PUBLIC\",\"avatar_file_name\":\"my/avatar.webp\",\"user__username\":\"user-a\"}]"
                : "[]"
            body = "[{\"result\":{\"data\":{\"json\":{\"username\":\"user-\(account)\",\"subscription_type\":\"PLUS\",\"characters\":\(profileCharacters)}}}}]"
        case "character/v1/get_character_info":
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(buffer, count: count)
                }
            }
            let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let id = record?["external_id"] as? String ?? "character"
            body = "{\"character\":{\"external_id\":\"\(id)\",\"name\":\"Character\",\"title\":\"Title\",\"visibility\":\"VISIBILITY_PUBLIC\",\"copyable\":true,\"greeting\":\"Hi\",\"description\":\"Description\",\"avatar_file_name\":\"avatar\"}}"
        case "chat/chat":
            body = "{\"chat_id\":\"chat\",\"creator_id\":\"account-\(account)\",\"character_id\":\"character\",\"visibility\":\"VISIBILITY_PRIVATE\",\"type\":\"TYPE_ONE_ON_ONE\"}"
        case "turns/chat":
            let cursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "next_token" }?.value
            let page = cursor.flatMap(Int.init) ?? 0
            let next = page + 1 < pages ? "\"\(page + 1)\"" : "null"
            var turns = (page * size..<min((page + 1) * size, pages * size)).map { i in
                "{\"turn_key\":{\"turn_id\":\"\(i)\",\"chat_id\":\"chat\"},\"state\":\"STATE_OK\",\"author\":{\"author_id\":\"character\",\"name\":\"Character\"},\"candidates\":[{\"candidate_id\":\"c\(i)\",\"raw_content\":\"Message \(i)\",\"is_final\":true}],\"primary_candidate_id\":\"c\(i)\",\"is_pinned\":false}"
            }
            if page > 0, let duplicate = turns.first { turns.insert(duplicate, at: 0) }
            body = "{\"turns\":[\(turns.joined(separator: ","))],\"meta\":{\"next_token\":\(next)}}"
        case "chats", "chats/recent": body = "{\"chats\":[]}"
        case "get-available-models": body = "{\"available_models\":[\"MODEL_TYPE_DEEP_SYNTH\"],\"configs\":{}}"
        case "api/feed/recommended": body = "{\"contents\":[],\"next_cursor\":null}"
        case "scene/v1/scenes/curated": body = "{\"scenes\":[],\"has_next\":false}"
        case "recommendation/v1/curated_character_lists": body = "{\"curated_character_lists\":{}}"
        case "api/feed/social_feed": body = "{\"uuid\":\"feed\",\"title\":\"Feed\",\"chips\":[],\"contents\":[],\"next_cursor\":null}"
        case "chat/chat/conversation-facts": body = "{\"conversation_facts\":{}}"
        case "api/trpc/search.search":
            body = searchRefusal
                ? "[{\"error\":{\"json\":{\"message\":\"Unauthorized\",\"code\":401}}}]"
                : "[{\"result\":{\"data\":{\"json\":{\"characters\":[]}}}}]"
        default: body = "{}"
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let status = searchRefusal && self.request.url?.path.contains("search.search") == true
                ? 500
                : (failure ?? 200)
            let response = HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"application/json", "Cache-Control":"no-store"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(body.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
        work = item
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: item)
    }
    override func stopLoading() { work?.cancel(); work = nil }
}

@MainActor final class CheckStorage: SessionStorage {
    var values: [String: Data] = [:]
    func save(_ data: Data, forKey key: String) throws { values[key] = data }
    func loadData(forKey key: String) throws -> Data? { values[key] }
    func delete(forKey key: String) throws { values[key] = nil }
}

@MainActor final class CheckCounter { var value = 0 }

@MainActor enum RegressionChecks {
    private static func zipFile(_ entries: [(String, String)], at url: URL) throws {
        let writer = ZipArchiveWriter<ZipMemoryStorage<[UInt8]>>()
        for (name, contents) in entries {
            try writer.writeFile(filename: name, contents: Array(contents.utf8))
        }
        try Data(writer.finalizeBuffer()).write(to: url)
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CheckProtocol.self]
        return URLSession(configuration: config)
    }
    static func auth(defaults: UserDefaults) -> AuthStore {
        AuthStore(storage: CheckStorage(), session: AuthSession(sessionToken: "synthetic-account-a", userID: "account-a", username: "user-a"), personas: PersonaStore(defaults: defaults))
    }
    static func run() async throws {
        let suite = "PerformanceChecks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("unrelated", forKey: "preferences.audit-unrelated")
        defaults.set(Data("old private data".utf8), forKey: "preferences.personas.list")
        let transport = session()
        let auth = auth(defaults: defaults)
        let client = AuthenticatedHTTPClient(session: transport, authStore: auth)
        CheckProtocol.reset()
        await auth.personas.fetchRemotePersonas(authenticatedClient: client, currentCharacterID: "character")
        precondition(auth.personas.personas.first?.externalID == "persona-a")
        let firstCount = CheckProtocol.count()
        await auth.personas.fetchRemotePersonas(authenticatedClient: client)
        precondition(CheckProtocol.count() == firstCount)
        let restored = PersonaStore(defaults: defaults)
        precondition(restored.personas.isEmpty)
        restored.setAccount("account-a")
        precondition(restored.personas.first?.externalID == "persona-a")
        restored.setAccount("account-b")
        precondition(restored.personas.isEmpty && restored.characterOverrides.isEmpty)
        auth.clearSession()
        precondition(auth.personas.personas.isEmpty && auth.personas.characterOverrides.isEmpty)
        precondition(defaults.string(forKey: "preferences.audit-unrelated") == "unrelated")
        precondition(defaults.object(forKey: "preferences.personas.list") == nil)
        print("PASS persona cache hit, logout, owner-tagged relaunch, A/B isolation, legacy cleanup, unrelated preferences")

        try await auth.signIn(sessionToken: "synthetic-account-a", validator: SessionValidator(session: transport))
        CheckProtocol.reset(delay: 0.15)
        let delayed = Task { await auth.personas.fetchRemotePersonas(authenticatedClient: client) }
        try await Task.sleep(for: .milliseconds(25))
        auth.clearSession()
        await delayed.value
        precondition(auth.personas.personas.isEmpty && !auth.personas.isLoadingPersonas)
        try await auth.signIn(sessionToken: "synthetic-account-a", validator: SessionValidator(session: transport))
        CheckProtocol.reset(delay: 0.15)
        let switched = Task { await auth.personas.fetchRemotePersonas(authenticatedClient: client) }
        try await Task.sleep(for: .milliseconds(25))
        try await auth.signIn(sessionToken: "synthetic-account-b", validator: SessionValidator(session: transport))
        await switched.value
        precondition(auth.personas.personas.isEmpty)
        CheckProtocol.reset()
        await auth.personas.fetchRemotePersonas(authenticatedClient: client)
        precondition(auth.personas.personas.first?.externalID == "persona-b")
        print("PASS delayed persona reads cannot repopulate logout or account B")

        CheckProtocol.reset(delay: 0.15)
        let signIn = Task { try await auth.signIn(sessionToken: "synthetic-account-a", validator: SessionValidator(session: transport)) }
        try await Task.sleep(for: .milliseconds(25))
        auth.clearSession()
        do { try await signIn.value; preconditionFailure("Obsolete sign-in succeeded") }
        catch is CancellationError {}
        precondition(auth.session == nil)
        print("PASS delayed sign-in cannot undo logout")

        try await auth.signIn(sessionToken: "synthetic-account-a", validator: SessionValidator(session: transport))
        CheckProtocol.reset()
        let service = ConversationService(authenticatedHTTPClient: client)
        _ = try await service.loadHistory(chatID: "chat", characterID: "character")
        precondition(CheckProtocol.count("turns/chat") == 1)
        _ = try await service.loadHistory(chatID: "chat", characterID: "character")
        precondition(CheckProtocol.count("turns/chat") == 1)
        _ = try await service.loadHistory(chatID: "chat", characterID: "character", forceRefresh: true)
        precondition(CheckProtocol.count("turns/chat") == 2)
        print("PASS history warm hit and forced lower-page refresh")

        var clock = Date()
        let cache = ResourceCache(countLimit: 2, costLimit: 10, now: { clock })
        cache.insert(1, for: "one", ttl: 10, cost: 4)
        precondition(cache.cached("one", as: Int.self, requireFresh: true) == 1)
        clock.addTimeInterval(11)
        precondition(cache.cached("one", as: Int.self, requireFresh: true) == nil)
        precondition(cache.cached("one", as: Int.self) == 1)
        cache.invalidate("one")
        precondition(cache.count == 0)
        let loads = CheckCounter()
        async let one: Int = cache.value(for: "shared", ttl: 10, cost: { _ in 1 }) { loads.value += 1; try await Task.sleep(for: .milliseconds(20)); return 7 }
        async let two: Int = cache.value(for: "shared", ttl: 10, cost: { _ in 1 }) { loads.value += 1; return 9 }
        let values = try await (one, two)
        precondition(values.0 == values.1 && loads.value == 1)
        print("PASS cache freshness/stale distinction, invalidation, concurrent deduplication")

        // Discovery, feed, curated lists, and profile caching checks
        CheckProtocol.reset()
        let discoverService = DiscoverService(session: transport, authStore: auth)
        _ = try await discoverService.loadRecommendedFeed(cursor: nil)
        precondition(CheckProtocol.count("api/feed/recommended") == 1)
        _ = try await discoverService.loadRecommendedFeed(cursor: nil)
        precondition(CheckProtocol.count("api/feed/recommended") == 1)
        _ = try await discoverService.loadRecommendedFeed(cursor: nil, forceRefresh: true)
        precondition(CheckProtocol.count("api/feed/recommended") == 2)

        _ = try await discoverService.loadCuratedScenes(cursor: nil)
        precondition(CheckProtocol.count("scene/v1/scenes/curated") == 1)
        _ = try await discoverService.loadCuratedScenes(cursor: nil)
        precondition(CheckProtocol.count("scene/v1/scenes/curated") == 1)

        let feedService = FeedService(session: transport, authStore: auth)
        _ = try await feedService.loadSocialFeed()
        precondition(CheckProtocol.count("api/feed/social_feed") == 1)
        _ = try await feedService.loadSocialFeed()
        precondition(CheckProtocol.count("api/feed/social_feed") == 1)
        _ = try await feedService.loadSocialFeed(forceRefresh: true)
        precondition(CheckProtocol.count("api/feed/social_feed") == 2)

        let popularTrendingService = PopularTrendingService(session: transport, authStore: auth)
        _ = try await popularTrendingService.loadCuratedLists()
        precondition(CheckProtocol.count("recommendation/v1/curated_character_lists") == 1)
        _ = try await popularTrendingService.loadCuratedLists()
        precondition(CheckProtocol.count("recommendation/v1/curated_character_lists") == 1)

        // Character search web-session cookie: input normalization, Keychain
        // storage, cookie/header scope and the two refusal states.
        precondition((try? WebSessionCookie.normalizedHeader(
            from: "  Cookie: web-next-auth=abc; other=1 \n"
        )) == "web-next-auth=abc; other=1")
        precondition((try? WebSessionCookie.normalizedHeader(from: "abc.def=="))
            == "web-next-auth=abc.def==")
        precondition((try? WebSessionCookie.normalizedHeader(
            from: "web-next-auth.session-token=legacy"
        )) == "web-next-auth=legacy", "Legacy guessed cookie names are repaired")
        do {
            _ = try WebSessionCookie.normalizedHeader(from: "   ")
            preconditionFailure("An empty cookie was accepted")
        } catch WebSessionCookieError.empty {}
        do {
            _ = try WebSessionCookie.normalizedHeader(from: "web-next-auth=a\r\nX-Test: b")
            preconditionFailure("A cookie with a line break was accepted")
        } catch WebSessionCookieError.malformed {}

        let cookieStorage = CheckStorage()
        let cookieAuth = AuthStore(
            storage: cookieStorage,
            session: nil,
            personas: PersonaStore(defaults: defaults),
            restoreSession: false
        )
        try cookieAuth.saveWebSessionCookie("web-next-auth=abc")
        precondition(cookieAuth.hasWebSessionCookie)
        precondition(cookieAuth.webSessionCookie() == "web-next-auth=abc")
        try cookieAuth.clearWebSessionCookie()
        precondition(!cookieAuth.hasWebSessionCookie && cookieStorage.values.isEmpty)
        try cookieAuth.saveWebSessionCookie("web-next-auth=abc")
        precondition(cookieAuth.hasWebSessionCookie)
        cookieAuth.clearSession()
        precondition(!cookieAuth.hasWebSessionCookie && cookieStorage.values.isEmpty,
                     "Signing out must remove the account's search cookie")

        CheckProtocol.reset()
        let searchWithCookie = CharacterSearchService(
            session: transport,
            fixedToken: "synthetic",
            webSessionCookie: "web-next-auth=abc"
        )
        let cookieResults = try await searchWithCookie.searchCharacters(query: "hello")
        precondition(cookieResults.isEmpty)
        precondition(CheckProtocol.count("api/trpc/search.search") == 1)
        precondition(CheckProtocol.lastSearchCookie == "web-next-auth=abc")
        precondition(CheckProtocol.lastSearchOrigin == "https://character.ai")
        precondition(CheckProtocol.lastSearchAuthorization == nil,
                     "The web cookie request must not also present the native Token header")

        CheckProtocol.reset()
        let searchWithoutCookie = CharacterSearchService(session: transport, fixedToken: "synthetic")
        let noCookieResults = try await searchWithoutCookie.searchCharacters(query: "hello")
        precondition(noCookieResults.isEmpty)
        precondition(CheckProtocol.lastSearchCookie == nil)
        precondition(CheckProtocol.lastSearchOrigin == nil)
        precondition(CheckProtocol.lastSearchAuthorization == "Token synthetic")

        CheckProtocol.reset(searchRefusal: true)
        do {
            _ = try await searchWithoutCookie.searchCharacters(query: "hello")
            preconditionFailure("A refused search without a cookie did not report the missing credential")
        } catch SearchError.resultsRequireWebSession {}
        do {
            _ = try await searchWithCookie.searchCharacters(query: "hello")
            preconditionFailure("A refused saved cookie did not report rejection")
        } catch SearchError.webSessionRejected {}
        print("PASS search cookie validation, scoped Cookie/Origin headers, Keychain round-trip and both refusal states")

        let userProfileService = UserProfileService(session: transport, authStore: auth)
        let profile = try await userProfileService.loadProfile(username: "user-a")
        precondition(profile.publicCharacters.map(\.externalID) == ["own-character"])
        precondition(CheckProtocol.count("api/trpc/social.publicProfile") == 1)
        _ = try await userProfileService.loadProfile(username: "user-a")
        precondition(CheckProtocol.count("api/trpc/social.publicProfile") == 1)
        let ownCharactersRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Veyrin-own-characters-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: ownCharactersRoot) }
        let ownCharacterLibrary = LocalCharacterLibrary(supportDirectory: ownCharactersRoot)
        let ownCharacterViewModel = UserProfileViewModel(service: userProfileService, username: "user-a", library: ownCharacterLibrary,
                                                        characterService: CharacterService(httpClient: client))
        await ownCharacterViewModel.load()
        let savedOwnCharacterCount = try await ownCharacterViewModel.savePublicCharactersToLibrary()
        precondition(savedOwnCharacterCount == 1)
        precondition(ownCharacterLibrary.characters.map(\.id) == ["own-character"])
        precondition(ownCharacterLibrary.characters.first?.sourceName == "Character.AI Discover")
        precondition(ownCharacterLibrary.characters.first?.greeting == "Hi", "Save all must use the full profile greeting, not summary text")

        let accountExportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Veyrin-account-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: accountExportRoot) }
        let exportFolder = accountExportRoot.appendingPathComponent("account/data", isDirectory: true)
        try FileManager.default.createDirectory(at: exportFolder, withIntermediateDirectories: true)
        let exportFile = exportFolder.appendingPathComponent("character.json")
        let exportedCharacters: [[String: Any]] = [
            ["id": "owned-export-id", "name": "Exported Character", "title": "An export title",
             "description": "Exported account description", "greeting": "Hello from export",
             "creator_name": "user-a", "tags": ["personal", "export"]],
            ["id": "metadata-only-id", "title": "Metadata only"]
        ]
        try JSONSerialization.data(withJSONObject: exportedCharacters).write(to: exportFile)
        let accountExportLibrary = LocalCharacterLibrary(supportDirectory: accountExportRoot.appendingPathComponent("library", isDirectory: true))
        let exportResult = try accountExportLibrary.importCharacterAIAccountExport(from: accountExportRoot)
        precondition(exportResult.importedCount == 2 && exportResult.skippedCount == 0)
        precondition(exportResult.missingDefinitionCount == 2)
        let importedOwnCharacter = accountExportLibrary.characters.first { $0.id == "owned-export-id" }
        precondition(importedOwnCharacter?.sourceName == "Character.AI account export")
        precondition(importedOwnCharacter?.definition.isEmpty == true)
        precondition(importedOwnCharacter?.greeting == "Hello from export")
        precondition(importedOwnCharacter?.licence == "Account export; rights not specified")
        let invalidExport = accountExportRoot.appendingPathComponent("not-an-export.json")
        try Data("{bad json".utf8).write(to: invalidExport)
        do {
            _ = try accountExportLibrary.importCharacterAIAccountExport(from: invalidExport)
            preconditionFailure("Malformed account export unexpectedly imported")
        } catch {}
        precondition(accountExportLibrary.characters.count == 2)

        let accountZip = accountExportRoot.appendingPathComponent("character-ai-export.zip")
        try zipFile([
            ("data/user.json", "{}"),
            ("data/character.json", String(data: try Data(contentsOf: exportFile), encoding: .utf8)!)
        ], at: accountZip)
        let zipResult = try accountExportLibrary.importCharacterAIAccountExport(from: accountZip)
        precondition(zipResult.importedCount == 2)
        precondition(accountExportLibrary.characters.count == 2)

        let missingCharacterZip = accountExportRoot.appendingPathComponent("missing-character.zip")
        try zipFile([("data/message.json", "[]")], at: missingCharacterZip)
        do {
            _ = try accountExportLibrary.importCharacterAIAccountExport(from: missingCharacterZip)
            preconditionFailure("An export without a character JSON file unexpectedly imported")
        } catch CharacterAIAccountExportError.characterFileNotFound {}
        precondition(accountExportLibrary.characters.count == 2)

        let ambiguousCharacterZip = accountExportRoot.appendingPathComponent("ambiguous-characters.zip")
        try zipFile([
            ("data/character.json", "[]"),
            ("data/characters.json", "[]")
        ], at: ambiguousCharacterZip)
        do {
            _ = try accountExportLibrary.importCharacterAIAccountExport(from: ambiguousCharacterZip)
            preconditionFailure("An export with multiple character JSON files unexpectedly imported")
        } catch CharacterAIAccountExportError.ambiguousCharacterFiles {}
        precondition(accountExportLibrary.characters.count == 2)

        let invalidZip = accountExportRoot.appendingPathComponent("invalid.zip")
        try Data("not a zip".utf8).write(to: invalidZip)
        do {
            _ = try accountExportLibrary.importCharacterAIAccountExport(from: invalidZip)
            preconditionFailure("A malformed ZIP unexpectedly imported")
        } catch CharacterAIAccountExportError.invalidZip {}
        precondition(accountExportLibrary.characters.count == 2)
        print("PASS account export imports JSON and ZIP inputs, rejects missing, ambiguous, and malformed ZIPs without changing the library")

        _ = try await service.loadConversationFacts(chatID: "chat")
        precondition(CheckProtocol.count("chat/chat/conversation-facts") == 1)
        _ = try await service.loadConversationFacts(chatID: "chat")
        precondition(CheckProtocol.count("chat/chat/conversation-facts") == 1)
        _ = try await service.loadConversationFacts(chatID: "chat", forceRefresh: true)
        precondition(CheckProtocol.count("chat/chat/conversation-facts") == 2)

        let ollamaConfiguration = URLSessionConfiguration.ephemeral
        ollamaConfiguration.protocolClasses = [OllamaCheckProtocol.self]
        let ollamaSession = URLSession(configuration: ollamaConfiguration)
        var didLaunchOllama = false
        OllamaCheckProtocol.reset(unavailableRequests: 2)
        let ollamaService = try LocalOllamaService(session: ollamaSession) { didLaunchOllama = true }
        let availableModels = try await ollamaService.models()
        precondition(didLaunchOllama && availableModels == ["test-model"])
        precondition(OllamaCheckProtocol.requestCount == 3)
        OllamaCheckProtocol.reset()
        didLaunchOllama = false
        let runningOllamaService = try LocalOllamaService(session: ollamaSession) { didLaunchOllama = true }
        _ = try await runningOllamaService.models()
        precondition(!didLaunchOllama && OllamaCheckProtocol.requestCount == 1)
        OllamaCheckProtocol.reset(unavailableRequests: 1)
        let disabledOllamaService = try LocalOllamaService(
            session: ollamaSession,
            startsApplicationWhenUnavailable: false
        ) { didLaunchOllama = true }
        do {
            _ = try await disabledOllamaService.models()
            preconditionFailure("Disabled automatic startup unexpectedly succeeded")
        } catch LocalOllamaError.unavailable {}
        precondition(!didLaunchOllama && OllamaCheckProtocol.requestCount == 1)
        let lifecycle = LocalOllamaLifecycle.shared
        var didStopOllama = false
        lifecycle.recordLaunch { didStopOllama = true }
        lifecycle.applicationWillTerminate()
        precondition(didStopOllama)
        didStopOllama = false
        lifecycle.applicationWillTerminate()
        precondition(!didStopOllama)
        lifecycle.recordLaunch { didStopOllama = true }
        lifecycle.applicationWillTerminate()
        precondition(didStopOllama)
        ollamaSession.invalidateAndCancel()
        print("PASS Ollama launch preference, existing-instance preservation, and Veyrin quit cleanup")

        let savedCharacter = try LocalCharacter(discoverCharacter: DiscoverFeedCharacter(
            externalID: "character-id", name: "Mara Ellison", participantName: nil,
            interactionCount: 321, title: "Harbour keeper", description: "Keeps the old lighthouse running.",
            greeting: "The lamp is back on.", visibility: "PUBLIC", avatarFileName: "uploaded/avatar.webp",
            username: "mara", shortHash: nil
        ))
        precondition(savedCharacter.id == "character-id")
        precondition(savedCharacter.avatarFileName == "uploaded/avatar.webp")
        precondition(savedCharacter.interactionCount == 321 && savedCharacter.visibility == "PUBLIC")
        precondition(savedCharacter.greeting == "The lamp is back on.")
        let updatedCharacter = try LocalCharacter(discoverCharacter: DiscoverFeedCharacter(
            externalID: "character-id", name: "Mara Ellison", participantName: nil,
            interactionCount: nil, title: nil, description: nil, greeting: nil,
            visibility: nil, avatarFileName: nil, username: nil, shortHash: nil
        ), existing: savedCharacter)
        precondition(updatedCharacter.avatarFileName == savedCharacter.avatarFileName)
        precondition(updatedCharacter.description == savedCharacter.description)
        precondition(updatedCharacter.greeting == savedCharacter.greeting)
        precondition(LocalCharacterConversation(character: savedCharacter).characterID == "character-id")

        let libraryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Veyrin-library-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: libraryRoot) }

        let duplicateCharacter = try LocalCharacter(discoverCharacter: DiscoverFeedCharacter(
            externalID: "duplicate-id", name: "Last duplicate", participantName: nil,
            interactionCount: nil, title: nil, description: nil, greeting: nil,
            visibility: nil, avatarFileName: nil, username: nil, shortHash: nil
        ))
        let duplicateRecords = [
            try LocalCharacter(discoverCharacter: DiscoverFeedCharacter(
                externalID: "duplicate-id", name: "First duplicate", participantName: nil,
                interactionCount: nil, title: nil, description: nil, greeting: nil,
                visibility: nil, avatarFileName: nil, username: nil, shortHash: nil
            )),
            duplicateCharacter
        ]
        func libraryWithDuplicateIDs(_ name: String) throws -> LocalCharacterLibrary {
            let root = libraryRoot.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(duplicateRecords)
                .write(to: root.appendingPathComponent("characters.json"))
            let library = LocalCharacterLibrary(supportDirectory: root)
            precondition(library.characters.count == 2)
            return library
        }

        let duplicateSaveLibrary = try libraryWithDuplicateIDs("duplicate-save")
        _ = try duplicateSaveLibrary.saveFromDiscover([DiscoverFeedCharacter(
            externalID: "new-character", name: "New character", participantName: nil,
            interactionCount: nil, title: nil, description: nil, greeting: nil,
            visibility: nil, avatarFileName: nil, username: nil, shortHash: nil
        )])
        precondition(duplicateSaveLibrary.characters.filter { $0.id == "duplicate-id" }.count == 1)
        precondition(duplicateSaveLibrary.characters.first { $0.id == "duplicate-id" }?.name == "Last duplicate")

        let duplicateAccountLibrary = try libraryWithDuplicateIDs("duplicate-account-import")
        let duplicateAccountFolder = libraryRoot.appendingPathComponent("account-export", isDirectory: true)
        try FileManager.default.createDirectory(at: duplicateAccountFolder, withIntermediateDirectories: true)
        let duplicateAccountFile = duplicateAccountFolder.appendingPathComponent("character.json")
        let duplicateAccountData = try JSONSerialization.data(withJSONObject: [["id": "account-import", "name": "Account import"]])
        try duplicateAccountData.write(to: duplicateAccountFile)
        _ = try duplicateAccountLibrary.importCharacterAIAccountExport(from: duplicateAccountFile)
        precondition(duplicateAccountLibrary.characters.filter { $0.id == "duplicate-id" }.count == 1)
        precondition(duplicateAccountLibrary.characters.first { $0.id == "duplicate-id" }?.name == "Last duplicate")

        let duplicateArchiveLibrary = try libraryWithDuplicateIDs("duplicate-archive-import")
        let duplicateArchiveFile = libraryRoot.appendingPathComponent("duplicate-archive.json")
        let duplicateArchiveData = try JSONSerialization.data(withJSONObject: [
            "format": "veyrin.local-character-library",
            "version": 1,
            "characters": [["archive_id": UUID().uuidString, "name": "Archive import"]]
        ])
        try duplicateArchiveData.write(to: duplicateArchiveFile)
        _ = try duplicateArchiveLibrary.importArchive(from: duplicateArchiveFile)
        precondition(duplicateArchiveLibrary.characters.filter { $0.id == "duplicate-id" }.count == 1)
        precondition(duplicateArchiveLibrary.characters.first { $0.id == "duplicate-id" }?.name == "Last duplicate")
        print("PASS duplicate catalogue IDs keep the last entry during save and both import paths")

        // About and greeting are the only fields My Library edits. The rest of
        // an imported character, including its source metadata, must survive.
        let editRoot = libraryRoot.appendingPathComponent("edit", isDirectory: true)
        let editLibrary = LocalCharacterLibrary(supportDirectory: editRoot)
        let editID = UUID().uuidString
        try editLibrary.saveFromDiscover(DiscoverFeedCharacter(
            externalID: editID, name: "Editable Character", participantName: nil,
            interactionCount: 12, title: "Tagline kept", description: "Original about",
            greeting: "Original greeting", visibility: "VISIBILITY_PUBLIC",
            avatarFileName: "avatar.png", username: "creator", shortHash: nil
        ))
        let editedCharacter = try editLibrary.updateDetails(for: editID, about: "  Edited about \n",
                                                            greeting: "Edited greeting")
        precondition(editedCharacter.description == "Edited about" && editedCharacter.greeting == "Edited greeting",
                     "An edit trims surrounding whitespace")
        precondition(editedCharacter.name == "Editable Character" && editedCharacter.tagline == "Tagline kept"
                     && editedCharacter.creatorName == "creator" && editedCharacter.avatarFileName == "avatar.png"
                     && editedCharacter.interactionCount == 12 && editedCharacter.visibility == "VISIBILITY_PUBLIC",
                     "Editing About and the greeting must keep the imported metadata")
        let reloadedEditLibrary = LocalCharacterLibrary(supportDirectory: editRoot)
        precondition(reloadedEditLibrary.characters.first?.description == "Edited about"
                     && reloadedEditLibrary.characters.first?.greeting == "Edited greeting",
                     "A saved edit survives a relaunch")
        do {
            try editLibrary.updateDetails(for: "missing-character", about: "", greeting: "")
            preconditionFailure("Editing a character that is not in the library must fail")
        } catch LocalCharacterLibraryError.invalidCharacter {}
        print("PASS About and greeting edits persist, keep imported metadata and fail safely")

        func removalCharacter(_ id: String, _ name: String) -> DiscoverFeedCharacter {
            DiscoverFeedCharacter(
                externalID: id, name: name, participantName: nil,
                interactionCount: nil, title: nil, description: nil, greeting: "Hello",
                visibility: nil, avatarFileName: nil, username: nil, shortHash: nil
            )
        }
        let removalRoot = libraryRoot.appendingPathComponent("removal", isDirectory: true)
        let removalLibrary = LocalCharacterLibrary(supportDirectory: removalRoot)
        let keptID = UUID().uuidString
        let unbookmarkedID = UUID().uuidString
        try removalLibrary.saveFromDiscover(removalCharacter(keptID, "Kept Character"))
        try removalLibrary.saveFromDiscover(removalCharacter(unbookmarkedID, "Unbookmarked Character"))
        _ = try removalLibrary.conversation(for: LocalCharacter(discoverCharacter: removalCharacter(keptID, "Kept Character")))
        _ = try removalLibrary.conversation(for: LocalCharacter(discoverCharacter: removalCharacter(unbookmarkedID, "Unbookmarked Character")))
        let removalConversations = removalRoot.appendingPathComponent("conversations", isDirectory: true)
        try removalLibrary.remove(unbookmarkedID)
        precondition(!removalLibrary.containsCharacter(unbookmarkedID))
        precondition(removalLibrary.containsCharacter(keptID))
        precondition(FileManager.default.fileExists(atPath: removalConversations.appendingPathComponent("\(unbookmarkedID).json").path),
                     "Unbookmarking must keep the local conversation for a later re-save")
        let reloadedRemovalLibrary = LocalCharacterLibrary(supportDirectory: removalRoot)
        precondition(!reloadedRemovalLibrary.containsCharacter(unbookmarkedID))
        precondition(reloadedRemovalLibrary.containsCharacter(keptID))
        try reloadedRemovalLibrary.remove(keptID, deletingConversation: true)
        precondition(!reloadedRemovalLibrary.containsCharacter(keptID))
        precondition(!FileManager.default.fileExists(atPath: removalConversations.appendingPathComponent("\(keptID).json").path),
                     "Removing from My Library must delete that character's local conversation")
        print("PASS unbookmarking removes only the bookmark and explicit library removal clears local chat history")

        let brokenCatalogueRoot = libraryRoot.appendingPathComponent("broken-catalogue", isDirectory: true)
        try FileManager.default.createDirectory(at: brokenCatalogueRoot, withIntermediateDirectories: true)
        let catalogueURL = brokenCatalogueRoot.appendingPathComponent("characters.json")
        let brokenCatalogue = Data("{not valid JSON".utf8)
        try brokenCatalogue.write(to: catalogueURL)
        let brokenCatalogueLibrary = LocalCharacterLibrary(supportDirectory: brokenCatalogueRoot)
        precondition(brokenCatalogueLibrary.characters.isEmpty)
        precondition(brokenCatalogueLibrary.errorMessage != nil)
        do {
            try brokenCatalogueLibrary.saveFromDiscover(DiscoverFeedCharacter(
                externalID: "another-character", name: "Another Character", participantName: nil,
                interactionCount: nil, title: nil, description: nil, greeting: nil,
                visibility: nil, avatarFileName: nil, username: nil, shortHash: nil
            ))
            preconditionFailure("A broken catalogue unexpectedly accepted a save")
        } catch LocalCharacterLibraryError.catalogueUnavailable {}
        let catalogueAfterFailedSave = try Data(contentsOf: catalogueURL)
        precondition(catalogueAfterFailedSave == brokenCatalogue)
        do {
            try brokenCatalogueLibrary.remove("another-character")
            preconditionFailure("A broken catalogue unexpectedly accepted a removal")
        } catch LocalCharacterLibraryError.catalogueUnavailable {}
        let catalogueAfterFailedRemoval = try Data(contentsOf: catalogueURL)
        precondition(catalogueAfterFailedRemoval == brokenCatalogue)
        do {
            try brokenCatalogueLibrary.updateDetails(for: "another-character", about: "x", greeting: "y")
            preconditionFailure("A broken catalogue unexpectedly accepted an edit")
        } catch LocalCharacterLibraryError.catalogueUnavailable {}
        let catalogueAfterFailedEdit = try Data(contentsOf: catalogueURL)
        precondition(catalogueAfterFailedEdit == brokenCatalogue)

        let conversationRoot = libraryRoot.appendingPathComponent("broken-conversation", isDirectory: true)
        let conversationLibrary = LocalCharacterLibrary(supportDirectory: conversationRoot)
        let conversationID = UUID().uuidString
        let conversationCharacter = try LocalCharacter(discoverCharacter: DiscoverFeedCharacter(
            externalID: conversationID, name: "Conversation Check", participantName: nil,
            interactionCount: nil, title: nil, description: nil, greeting: "Hello",
            visibility: nil, avatarFileName: nil, username: nil, shortHash: nil
        ))
        try conversationLibrary.saveFromDiscover(DiscoverFeedCharacter(
            externalID: conversationID, name: "Conversation Check", participantName: nil,
            interactionCount: nil, title: nil, description: nil, greeting: "Hello",
            visibility: nil, avatarFileName: nil, username: nil, shortHash: nil
        ))
        let conversationDirectory = conversationRoot.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: conversationDirectory, withIntermediateDirectories: true)
        let conversationURL = conversationDirectory.appendingPathComponent("\(conversationID).json")
        let brokenConversation = Data("{not valid JSON".utf8)
        try brokenConversation.write(to: conversationURL)
        do {
            _ = try conversationLibrary.conversation(for: conversationCharacter)
            preconditionFailure("A broken conversation unexpectedly loaded")
        } catch LocalCharacterLibraryError.conversationUnavailable {}
        let conversationAfterFailedLoad = try Data(contentsOf: conversationURL)
        precondition(conversationAfterFailedLoad == brokenConversation)

        let freshID = UUID().uuidString
        let freshCharacter = try LocalCharacter(discoverCharacter: DiscoverFeedCharacter(
            externalID: freshID, name: "Fresh Conversation", participantName: nil,
            interactionCount: nil, title: nil, description: nil, greeting: "First greeting",
            visibility: nil, avatarFileName: nil, username: nil, shortHash: nil
        ))
        let freshConversation = try conversationLibrary.conversation(for: freshCharacter)
        precondition(freshConversation.messages.map(\.content) == ["First greeting"])
        let mismatchedConversation = LocalCharacterConversation(character: freshCharacter)
        let mismatchedData = try JSONEncoder().encode(mismatchedConversation)
        let mismatchedURL = conversationDirectory.appendingPathComponent("\(conversationID).json")
        try mismatchedData.write(to: mismatchedURL)
        do {
            _ = try conversationLibrary.conversation(for: conversationCharacter)
            preconditionFailure("A conversation saved for another character unexpectedly loaded")
        } catch LocalCharacterLibraryError.conversationUnavailable {}
        let mismatchedFileAfterLoad = try Data(contentsOf: mismatchedURL)
        precondition(mismatchedFileAfterLoad == mismatchedData)
        precondition(FileManager.default.fileExists(atPath: conversationDirectory.appendingPathComponent("\(freshID).json").path))
        print("PASS malformed local catalogue and conversations remain untouched and block replacement")
        print("PASS missing local conversation still creates a greeting conversation")
        print("PASS Discover character details and avatar carry into local-library records")
        print("PASS discover, feed, curated lists, profile, and conversation facts cached reuse & refresh")
    }
}
