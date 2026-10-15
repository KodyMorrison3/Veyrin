import Foundation
import Synchronization

nonisolated final class StubHTTP: URLProtocol, @unchecked Sendable {
    // URLProtocol requires mutable NSObject inheritance. All shared test state
    // is protected by a Mutex; each instance is managed by URLSession.
    struct State {
        var counts: [String: Int] = [:]
        var active = 0
        var maximumActive = 0
        var cancellations = 0
        var status = 200
        var directChat = false
        var missingPins = false
        var emptyTurns = false
        var copyRequestBody: String?
    }
    static let state = Mutex(State())
    private let stopped = Mutex(false)

    private static func bodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let snapshot = Self.state.withLock { state in
            state.counts[url.path, default: 0] += 1
            state.active += 1
            state.maximumActive = max(state.maximumActive, state.active)
            return (state.status, state.directChat, state.missingPins)
        }
        let chat = "{\"chat_id\":\"chat\",\"creator_id\":\"user\",\"visibility\":\"VISIBILITY_PRIVATE\",\"character_id\":\"character\",\"type\":\"TYPE_ONE_ON_ONE\"}"
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let query = Dictionary(components.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { first, _ in first })
        if url.path.hasSuffix("/copy"), let requestBody = Self.bodyData(request),
           let text = String(data: requestBody, encoding: .utf8) {
            Self.state.withLock { $0.copyRequestBody = text }
        }
        let body: String
        if url.path.hasSuffix("/copy") {
            body = "{\"new_chat_id\":\"copied-chat\"}"
        } else if url.path == "/character/v1/get_character_info" {
            body = "{\"character\":{\"external_id\":\"character\",\"title\":\"\",\"name\":\"Character\",\"visibility\":\"PUBLIC\",\"copyable\":true,\"greeting\":\"Hi\",\"description\":\"\",\"avatar_file_name\":\"avatar\"}}"
        } else if url.path.hasPrefix("/turns/") && Self.state.withLock({ $0.emptyTurns }) {
            body = "{\"turns\":[],\"meta\":{}}"
        } else if url.path.hasPrefix("/turns/") {
            let pin = snapshot.2 && query["pinned_only"] == nil ? "" : ",\"is_pinned\":false"
            body = "{\"turns\":[{\"turn_key\":{\"turn_id\":\"turn\",\"chat_id\":\"chat\"},\"state\":\"STATE_OK\",\"author\":{\"author_id\":\"character\",\"name\":\"Character\"},\"candidates\":[],\"primary_candidate_id\":\"candidate\"\(pin)}],\"meta\":{}}"
        } else if url.path == "/chats" {
            let characterID = query["character_ids"]!
            body = "{\"chats\":[{\"chat_id\":\"\(characterID)\",\"create_time\":\"today\",\"creator_id\":\"user\",\"character_id\":\"\(characterID)\",\"state\":\"STATE_ACTIVE\",\"type\":\"TYPE_ONE_ON_ONE\",\"visibility\":\"VISIBILITY_PRIVATE\"}]}"
        } else if url.path.contains("autocomplete") {
            body = "{\"search_autocomplete\":[\"\(query["query_prefix"]!)\"]}"
        } else { body = snapshot.1 ? chat : "{\"chat\":\(chat)}" }
        DispatchQueue.global().asyncAfter(deadline: .now() + (url.path.contains("autocomplete") ? 0.25 : 0.02)) { [self] in
            let deliver = stopped.withLock { value in
                guard !value else { return false }
                value = true
                return true
            }
            guard deliver else { return }
            Self.state.withLock { $0.active -= 1 }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: snapshot.0, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {
        let first = stopped.withLock { value in let first = !value; value = true; return first }
        if first { Self.state.withLock { $0.cancellations += 1; $0.active -= 1 } }
    }
}

@MainActor
func runHTTPChecks() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubHTTP.self]
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    // Other suites may have populated the shared stub counters; this suite's
    // assertions are absolute, so start from a clean slate.
    StubHTTP.state.withLock { state in
        state.counts = [:]
        state.active = 0
        state.maximumActive = 0
        state.cancellations = 0
        state.status = 200
        state.directChat = false
        state.missingPins = false
        state.emptyTurns = false
        state.copyRequestBody = nil
    }
    let auth = AuthStore(session: AuthSession(sessionToken: "synthetic", userID: "user", username: "name"))
    let service = ConversationService(authenticatedHTTPClient: AuthenticatedHTTPClient(session: session, authStore: auth))
    let first = try await service.loadChat(chatID: "chat")
    precondition(first.chatID == "chat")
    let copiedID = try await service.startNewConversation(
        chatID: "chat",
        endTurnID: "turn",
        modelType: "MODEL_TYPE_PIPSQUEAK_3"
    )
    precondition(copiedID == "copied-chat")
    let copyBody = StubHTTP.state.withLock { $0.copyRequestBody }
    precondition(copyBody?.contains("\"preferred_model_type\":\"MODEL_TYPE_PIPSQUEAK_3\"") == true,
                 "From-here copy keeps the user's explicitly selected model: \(String(describing: copyBody))")
    StubHTTP.state.withLock { $0.directChat = true }
    let direct = try await service.loadChat(chatID: "chat", forceRefresh: true)
    precondition(direct.chatID == "chat")
    precondition(StubHTTP.state.withLock { $0.counts["/chat/chat"] } == 2)
    StubHTTP.state.withLock { $0.status = 403 }
    do { _ = try await service.loadChat(chatID: "chat", forceRefresh: true); preconditionFailure("HTTP error swallowed") } catch {}
    precondition(StubHTTP.state.withLock { $0.counts["/chat/chat"] } == 3, "Blind retry remains")
    StubHTTP.state.withLock { $0.status = 200 }

    let vm = ChatViewModel(authStore: auth, conversationService: service)
    vm.character = Character(externalID: "character", title: "", name: "Character", visibility: "PUBLIC", copyable: true, greeting: "Hi", description: "", avatarFileName: "avatar")
    await vm.loadRealTurns(chatID: "chat")
    precondition(vm.hasTurns && vm.lastTurn?.turnID == "turn")
    precondition(StubHTTP.state.withLock { $0.counts["/turns/chat"] } == 1)
    StubHTTP.state.withLock { $0.missingPins = true }
    // Fresh load required to observe the conditional pin request; the warm
    // history cache is guarded separately by CacheChecks.
    service.invalidateHistory(chatID: "chat")
    await vm.loadRealTurns(chatID: "chat")
    precondition(StubHTTP.state.withLock { $0.counts["/turns/chat"] } == 3)

    StubHTTP.state.withLock { $0.maximumActive = 0 }
    let previews = try await service.loadChatPreviews(characterIDs: ["a", "b", "c", "d", "e"])
    precondition(previews.map(\.characterID) == ["a", "b", "c", "d", "e"])
    let peak = StubHTTP.state.withLock { $0.maximumActive }
    precondition(peak > 1 && peak <= 3)

    let search = DiscoverViewModel(service: DiscoverService(session: session, fixedToken: "synthetic"), searchService: CharacterSearchService(session: session, fixedToken: "synthetic"))
    search.searchQuery = "first"
    for _ in 0..<400 {
        if StubHTTP.state.withLock({ $0.counts.contains(where: { $0.key.contains("autocomplete") && $0.value >= 1 }) }) {
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    search.searchQuery = "second"
    for _ in 0..<500 {
        if search.suggestions == ["second"] && StubHTTP.state.withLock({ $0.cancellations }) >= 1 {
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    precondition(search.suggestions == ["second"])
    precondition(StubHTTP.state.withLock { $0.cancellations } >= 1)
    search.searchQuery = "x"
    precondition(search.suggestions.isEmpty && !search.isSearchingSuggestions)
    search.clearSearch()
    precondition(!search.hasActiveSearch)
    search.cancelSearch()
    vm.disconnect()
    print("Single-fetch chat shapes/errors, conditional pins, ordered bounded previews and search cancellation passed")
}
