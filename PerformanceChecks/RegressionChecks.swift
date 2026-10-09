import AppKit
import Combine
import Foundation
import SwiftUI

nonisolated final class CheckProtocol: URLProtocol, @unchecked Sendable {
    // URLProtocol callbacks run on Foundation queues; every state access uses this lock.
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var requests: [String: Int] = [:]
        var delay: TimeInterval = 0
        var pageSize = 2
        var pageCount = 2
        var failure: Int?
    }
    private static let state = State()
    private var work: DispatchWorkItem?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    static func reset(delay: TimeInterval = 0, pageSize: Int = 2, pageCount: Int = 2, failure: Int? = nil) {
        state.lock.lock(); defer { state.lock.unlock() }
        state.requests = [:]; state.delay = delay; state.pageSize = pageSize; state.pageCount = pageCount; state.failure = failure
    }
    static func count(_ path: String? = nil) -> Int {
        state.lock.lock(); defer { state.lock.unlock() }
        return path.map { state.requests[$0, default: 0] } ?? state.requests.values.reduce(0, +)
    }
    override func startLoading() {
        let path = request.url!.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        Self.state.lock.lock()
        Self.state.requests[path, default: 0] += 1
        let delay = Self.state.delay, size = Self.state.pageSize, pages = Self.state.pageCount, failure = Self.state.failure
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
            body = "[{\"result\":{\"data\":{\"json\":{\"username\":\"user-\(account)\",\"subscription_type\":\"PLUS\",\"characters\":[]}}}}]"
        case "character/v1/get_character_info":
            body = "{\"character\":{\"external_id\":\"character\",\"name\":\"Character\",\"title\":\"Title\",\"visibility\":\"VISIBILITY_PUBLIC\",\"copyable\":true,\"greeting\":\"Hi\",\"description\":\"Description\",\"avatar_file_name\":\"avatar\"}}"
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
        default: body = "{}"
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: failure ?? 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"application/json", "Cache-Control":"no-store"])!
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
    var data: Data?
    func save(_ data: Data, forKey key: String) throws { self.data = data }
    func loadData(forKey key: String) throws -> Data? { data }
    func delete(forKey key: String) throws { data = nil }
}

@MainActor final class CheckCounter { var value = 0 }

@MainActor enum RegressionChecks {
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

        let userProfileService = UserProfileService(session: transport, authStore: auth)
        _ = try await userProfileService.loadProfile(username: "user-a")
        precondition(CheckProtocol.count("api/trpc/social.publicProfile") == 1)
        _ = try await userProfileService.loadProfile(username: "user-a")
        precondition(CheckProtocol.count("api/trpc/social.publicProfile") == 1)

        _ = try await service.loadConversationFacts(chatID: "chat")
        precondition(CheckProtocol.count("chat/chat/conversation-facts") == 1)
        _ = try await service.loadConversationFacts(chatID: "chat")
        precondition(CheckProtocol.count("chat/chat/conversation-facts") == 1)
        _ = try await service.loadConversationFacts(chatID: "chat", forceRefresh: true)
        precondition(CheckProtocol.count("chat/chat/conversation-facts") == 2)

        print("PASS discover, feed, curated lists, profile, and conversation facts cached reuse & refresh")
    }
}
