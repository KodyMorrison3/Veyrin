import AppKit
import Combine
import Foundation
import SwiftUI

nonisolated final class EfficiencyProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        let data: Data
        var status = 200
        init(_ body: String, status: Int = 200) { data = Data(body.utf8); self.status = status }
        init(data: Data) { self.data = data }
    }
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var route: @Sendable (URLRequest) -> Reply = { _ in Reply("{}") }
        var held: Set<String> = []
        var pending: [EfficiencyProtocol] = []
        var counts: [String: Int] = [:]
        var active: [String: Int] = [:]
        var peak: [String: Int] = [:]
        var stopped: [String: Int] = [:]
        var observers: [(@Sendable () -> Bool, CheckedContinuation<Void, Never>)] = []
    }
    private static let state = State()
    private var reply = Reply("{}")
    private var finished = false
    private var path = ""

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    static func configure(held: Set<String> = [], route: @escaping @Sendable (URLRequest) -> Reply) {
        state.lock.lock(); defer { state.lock.unlock() }
        precondition(state.pending.isEmpty && state.active.values.allSatisfy { $0 == 0 })
        state.route = route; state.held = Set(held.map(normalize))
        state.counts = [:]; state.active = [:]; state.peak = [:]; state.stopped = [:]
    }
    static func query(_ request: URLRequest, _ name: String) -> String? {
        guard let url = request.url else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
    private static func normalize(_ path: String) -> String { path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    static func count(_ path: String) -> Int {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.counts[normalize(path), default: 0]
    }
    static func peak(_ path: String) -> Int {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.peak[normalize(path), default: 0]
    }
    static func stopped(_ path: String) -> Int {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.stopped[normalize(path), default: 0]
    }
    static func waitFor(_ condition: @escaping @Sendable () -> Bool) async {
        if condition() { return }
        await withCheckedContinuation { continuation in
            state.lock.lock()
            state.observers.append((condition, continuation))
            state.lock.unlock()
            notify()
        }
    }
    private static func notify() {
        state.lock.lock()
        let observers = state.observers
        state.observers = []
        state.lock.unlock()
        for (condition, continuation) in observers {
            if condition() { continuation.resume() }
            else {
                state.lock.lock(); state.observers.append((condition, continuation)); state.lock.unlock()
            }
        }
    }
    static func release(_ path: String, queryValue: String? = nil) {
        state.lock.lock()
        let pending = state.pending.first { load in
            load.path == normalize(path) && (queryValue == nil || query(load.request, "character_ids") == queryValue || query(load.request, "next_token") == queryValue)
        }
        state.lock.unlock()
        precondition(pending != nil, "No held request for \(path)")
        pending?.deliver()
    }
    override func startLoading() {
        path = Self.normalize(request.url?.path ?? "")
        Self.state.lock.lock()
        let route = Self.state.route
        Self.state.lock.unlock()
        reply = route(request)
        Self.state.lock.lock()
        Self.state.counts[path, default: 0] += 1
        Self.state.active[path, default: 0] += 1
        Self.state.peak[path] = max(Self.state.peak[path, default: 0], Self.state.active[path, default: 0])
        let held = Self.state.held.contains(path)
        Self.state.pending.append(self)
        Self.state.lock.unlock()
        Self.notify()
        if !held { deliver() }
    }
    private func deliver() {
        Self.state.lock.lock()
        guard !finished else { Self.state.lock.unlock(); return }
        finished = true
        Self.state.pending.removeAll { $0 === self }
        Self.state.active[path, default: 0] -= 1
        Self.state.lock.unlock()
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Cache-Control": "no-store"]) else {
            preconditionFailure("Invalid fixture URL")
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
        Self.notify()
    }
    override func stopLoading() {
        Self.state.lock.lock()
        if !finished {
            finished = true
            Self.state.pending.removeAll { $0 === self }
            Self.state.active[path, default: 0] -= 1
            Self.state.stopped[path, default: 0] += 1
        }
        Self.state.lock.unlock()
        Self.notify()
    }
}

@MainActor enum EfficiencyChecks {
    nonisolated static func turn(_ id: Int, text: String? = nil) -> String {
        "{\"turn_key\":{\"turn_id\":\"\(id)\",\"chat_id\":\"chat\"},\"author\":{\"author_id\":\"character\",\"name\":\"Character\"},\"candidates\":[{\"candidate_id\":\"c\(id)\",\"raw_content\":\"\(text ?? "Message \(id)")\",\"is_final\":true}],\"primary_candidate_id\":\"c\(id)\",\"is_pinned\":false}"
    }
    nonisolated static func page(_ ids: [Int], next: String? = nil, edited: Bool = false) -> EfficiencyProtocol.Reply {
        let turns = ids.map { turn($0, text: edited ? "Edited \($0)" : nil) }.joined(separator: ",")
        return EfficiencyProtocol.Reply("{\"turns\":[\(turns)],\"meta\":{\"next_token\":\(next.map { "\"\($0)\"" } ?? "null")}}")
    }
    static func transport() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EfficiencyProtocol.self]
        return URLSession(configuration: config)
    }
    static func model(_ auth: AuthStore, _ service: ConversationService) -> ChatViewModel {
        let model = ChatViewModel(authStore: auth, conversationService: service)
        model.character = Character(externalID: "character", title: "Title", name: "Character",
                                    visibility: "VISIBILITY_PUBLIC", copyable: true, greeting: "Hi",
                                    description: "Fixture", avatarFileName: "")
        return model
    }
    static func run() async throws {
        let suite = "EfficiencyChecks-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { preconditionFailure("Missing test defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let auth = RegressionChecks.auth(defaults: defaults)
        let session = transport()
        defer { session.invalidateAndCancel() }
        let client = AuthenticatedHTTPClient(session: session, authStore: auth)
        let service = ConversationService(authenticatedHTTPClient: client)
        try await history(auth, service)
        try await previews(auth, service, session)
        try await images(session)
    }

    static func history(_ auth: AuthStore, _ service: ConversationService) async throws {
        EfficiencyProtocol.configure { request in
            let index = Int(EfficiencyProtocol.query(request, "next_token") ?? "0") ?? 0
            let ids = Array(index * 10..<index * 10 + 10)
            return page((index > 0 ? [index * 10 - 1] : []) + ids + [ids[0]], next: index < 99 ? String(index + 1) : nil)
        }
        let vm = model(auth, service)
        let publications = CheckCounter()
        let observation = vm.$turnStates.dropFirst().sink { _ in publications.value += 1 }
        let start = ContinuousClock.now
        await vm.loadRealTurns(chatID: "chat")
        let elapsed = start.duration(to: .now)
        print("100-page offline history elapsed: \(elapsed) (descriptive only; no timing assertion)")
        precondition(vm.errorMessage == nil && vm.turnStates.map(\.id) == (0..<1000).map(String.init))
        precondition(publications.value == 100 && EfficiencyProtocol.count("/turns/chat/") == 100)
        let first = vm.turnStates[0], last = vm.turnStates[999]
        var visits = 0
        try await service.loadHistoryPages(chatID: "chat", characterID: "character", forceRefresh: true) { turns, _, _ in visits += turns.count }
        precondition(visits == 1000)
        print("PASS 100-page history: 1000 delivered turns instead of 50500 cumulative visits; 100 structural publications, overlap/duplicate first-occurrence order")

        let before = publications.value
        await vm.loadRealTurns(chatID: "chat", forceRefresh: true)
        precondition(publications.value == before)
        await vm.loadRealTurns(chatID: "chat")
        precondition(vm.turnStates[0] === first && vm.turnStates[999] === last && publications.value == before)
        EfficiencyProtocol.configure { _ in page([0, 1, 2], edited: true) }
        await vm.loadRealTurns(chatID: "chat", forceRefresh: true)
        precondition(vm.turnStates.map(\.id) == ["0", "1", "2"] && vm.turnStates[0] === first)
        precondition(vm.turnStates[0].turn.candidates.first?.rawContent == "Edited 0")
        await vm.rewind(fromTurnID: "1", chatID: "chat")
        precondition(vm.turnStates.map(\.id) == ["0", "1"] && service.cachedHistory(chatID: "chat")?.turns.map(\.turnID) == ["0", "1"])
        vm.checkFilteredHistory(chatID: "chat")
        EfficiencyProtocol.configure { _ in page([]) }
        await vm.loadRealTurns(chatID: "chat", forceRefresh: true)
        precondition(vm.turnStates.map(\.id) == ["0", "1"])
        EfficiencyProtocol.configure { _ in page([0]) }
        await vm.loadRealTurns(chatID: "chat", forceRefresh: true)
        EfficiencyProtocol.configure { _ in page([]) }
        await vm.loadRealTurns(chatID: "chat", forceRefresh: true)
        precondition(vm.turnStates.isEmpty)
        observation.cancel()
        print("PASS warm identity/no-op publication, authoritative edits/removals, rewind boundary/cache, filtered-empty retention and confirmation reset")

        EfficiencyProtocol.configure(held: ["/turns/chat/"]) { request in
            EfficiencyProtocol.query(request, "next_token") == nil ? page([0, 1], next: "one") : page([1, 2], next: "two")
        }
        let cancelled = Task { await vm.loadRealTurns(chatID: "chat", forceRefresh: true) }
        await EfficiencyProtocol.waitFor { EfficiencyProtocol.count("/turns/chat/") == 1 }
        EfficiencyProtocol.release("/turns/chat/")
        await EfficiencyProtocol.waitFor { EfficiencyProtocol.count("/turns/chat/") == 2 }
        EfficiencyProtocol.release("/turns/chat/", queryValue: "one")
        await EfficiencyProtocol.waitFor { EfficiencyProtocol.count("/turns/chat/") == 3 }
        cancelled.cancel()
        await cancelled.value
        await EfficiencyProtocol.waitFor { EfficiencyProtocol.stopped("/turns/chat/") == 1 }
        precondition(vm.turnStates.map(\.id) == ["0", "1", "2"])
        precondition(service.cachedHistory(chatID: "chat")?.turns.map(\.turnID) == ["0", "1", "2"])
        precondition(service.cachedHistory(chatID: "chat")?.nextToken == "two")
        print("PASS cancelled pagination checkpoints confirmed incomplete progress")

        EfficiencyProtocol.configure(held: ["/turns/chat/"]) { request in
            EfficiencyProtocol.query(request, "next_token") == nil ? page([0], next: "one") : page([3])
        }
        let obsolete = Task { await vm.loadRealTurns(chatID: "chat", forceRefresh: true) }
        await EfficiencyProtocol.waitFor { EfficiencyProtocol.count("/turns/chat/") == 1 }
        EfficiencyProtocol.release("/turns/chat/")
        await EfficiencyProtocol.waitFor { EfficiencyProtocol.count("/turns/chat/") == 2 }
        service.beginMutation(chatID: "chat")
        await obsolete.value
        await EfficiencyProtocol.waitFor { EfficiencyProtocol.stopped("/turns/chat/") == 1 }
        precondition(!vm.turnStates.contains { $0.id == "3" })
        precondition(service.cachedHistory(chatID: "chat")?.turns.map(\.turnID) == ["0"])

        EfficiencyProtocol.configure { request in
            EfficiencyProtocol.query(request, "next_token") == nil ? page([0], next: "same") : page([1], next: "same")
        }
        await vm.loadRealTurns(chatID: "chat", forceRefresh: true)
        precondition(vm.errorMessage?.contains("repeated cursor") == true)
        print("PASS mutation cancels stale page/cache writes and repeated cursor fails explicitly")

        EfficiencyProtocol.configure { request in
            switch EfficiencyProtocol.query(request, "next_token") {
            case nil: return page([0], next: "one")
            case "one": return page([1], next: "two")
            default: return page([2])
            }
        }
        var partialVisits = 0
        do {
            try await service.loadHistoryPages(chatID: "chat", characterID: "character", forceRefresh: true) { turns, _, complete in
                partialVisits += turns.count
                if partialVisits == 2 {
                    // Cancel after a confirmed page, then resume the same
                    // incomplete checkpoint from two readers.
                    precondition(!complete)
                    throw CancellationError()
                }
            }
        } catch is CancellationError {}
        precondition(service.cachedHistory(chatID: "chat")?.turns.map(\.turnID) == ["0", "1"])
        let concurrent = model(auth, service)
        async let left: Void = vm.loadRealTurns(chatID: "chat")
        async let right: Void = concurrent.loadRealTurns(chatID: "chat")
        _ = await (left, right)
        precondition(vm.turnStates.map(\.id) == ["0", "1", "2"] && concurrent.turnStates.map(\.id) == ["0", "1", "2"])
        precondition(service.cachedHistory(chatID: "chat")?.isComplete == true)
        precondition(EfficiencyProtocol.count("/turns/chat/") == 3)

        let warmState = vm.turnStates[1]
        EfficiencyProtocol.configure { request in
            EfficiencyProtocol.query(request, "next_token") == nil ? page([1, 0], next: "last") : page([0, 2])
        }
        await vm.loadRealTurns(chatID: "chat", forceRefresh: true)
        precondition(vm.turnStates.map(\.id) == ["1", "0", "2"] && vm.turnStates[0] === warmState)
        EfficiencyProtocol.configure { request in
            EfficiencyProtocol.query(request, "next_token") == nil ? page([1, 0], next: "last") : page([0, 1])
        }
        await vm.loadRealTurns(chatID: "chat", forceRefresh: true)
        precondition(vm.turnStates.map(\.id) == ["1", "0"] && vm.turnStates[0] === warmState)
        print("PASS warm multi-page reordering and duplicate-only final page removes obsolete tail without losing identity")

        let huge = String(repeating: "x", count: 9 * 1024 * 1024)
        // An oversized response is deliberately bypassed by the history
        // cache. Pagination still needs its session/mutation lease without it.
        EfficiencyProtocol.configure { request in
            if EfficiencyProtocol.query(request, "next_token") == nil {
                return EfficiencyProtocol.Reply("{\"turns\":[\(turn(0, text: huge))],\"meta\":{\"next_token\":\"last\"}}")
            }
            return page([1])
        }
        await vm.loadRealTurns(chatID: "chat", forceRefresh: true)
        precondition(vm.turnStates.map(\.id) == ["0", "1"] && vm.errorMessage == nil)
        precondition(service.cachedHistory(chatID: "chat") == nil)
        let costTurn = vm.turnStates[0].turn
        var estimate = CachedConversation(characterID: "character", turns: [], nextToken: nil, visitedTokens: [], isComplete: true)
        estimate.append([costTurn])
        let recomputed = CachedConversation(characterID: "character", turns: [costTurn], nextToken: nil, visitedTokens: [], isComplete: true)
        precondition(estimate.cost == recomputed.cost)
        estimate.update(costTurn.settingPinned(true))
        precondition(estimate.cost == recomputed.cost)
        estimate.remove([costTurn.turnID])
        precondition(estimate.cost == 256)
        print("PASS incomplete resume/shared readers, oversized cache bypass, incremental cost append/update/removal")
    }

    nonisolated static func recent() -> EfficiencyProtocol.Reply {
        let chats = (0..<8).map { index in
            "{\"chat_id\":\"recent-\(index)\",\"create_time\":\"2026-10-10T12:00:00Z\",\"creator_id\":\"a\",\"character_id\":\"character-\(index / 2)\",\"state\":\"STATE_ACTIVE\",\"type\":\"TYPE_ONE_ON_ONE\",\"visibility\":\"VISIBILITY_PRIVATE\",\"character_name\":\"Character \(index / 2)\",\"character_avatar_uri\":\"\",\"character_visibility\":\"VISIBILITY_PUBLIC\"}"
        }.joined(separator: ",")
        return EfficiencyProtocol.Reply("{\"chats\":[\(chats)]}")
    }
    nonisolated static func preview(_ character: String) -> EfficiencyProtocol.Reply {
        let index = Int(character.split(separator: "-").last ?? "0") ?? 0
        let chats = (index * 2..<index * 2 + 2).map { chat in
            "{\"chat_id\":\"recent-\(chat)\",\"create_time\":\"2026-10-10T12:00:00Z\",\"creator_id\":\"a\",\"character_id\":\"\(character)\",\"state\":\"STATE_ACTIVE\",\"type\":\"TYPE_ONE_ON_ONE\",\"visibility\":\"VISIBILITY_PRIVATE\",\"preview_turns\":[\(turn(chat))]}"
        }.joined(separator: ",")
        return EfficiencyProtocol.Reply("{\"chats\":[\(chats)]}")
    }
    static func previews(_ auth: AuthStore, _ service: ConversationService, _ session: URLSession) async throws {
        auth.resources.clear()
        EfficiencyProtocol.configure(held: ["/chats/"]) { request in
            request.url?.path.hasPrefix("/chats/recent") == true ? recent() : preview(EfficiencyProtocol.query(request, "character_ids") ?? "")
        }
        let vm = model(auth, service)
        await vm.loadRecentChats()
        precondition(vm.recentChats.count == 8 && EfficiencyProtocol.count("/chats/") == 0)
        let generation = vm.recentPreviewGeneration
        let demanded = Task { await vm.loadRecentPreview(characterID: "character-0", generation: generation) }
        let shared = Task { await vm.loadRecentPreview(characterID: "character-0", generation: generation) }
        await EfficiencyProtocol.waitFor { EfficiencyProtocol.count("/chats/") == 1 }
        demanded.cancel()
        await demanded.value
        EfficiencyProtocol.release("/chats/", queryValue: "character-0")
        await shared.value
        precondition(vm.recentChats[0].lastMessage == "Message 0" && vm.recentChats[1].lastMessage == "Message 1")
        precondition(vm.recentChats.dropFirst(2).allSatisfy { $0.lastMessage == nil })
        await vm.loadRecentPreview(characterID: "character-0", generation: generation)
        precondition(EfficiencyProtocol.count("/chats/") == 1)
        print("PASS immediate ordered base list, zero eager previews, demanded-character-only association, shared cancellation and 30-second cache reuse")

        let requests = (1...3).map { index in
            Task { try await service.loadChatPreviews(characterIDs: ["character-\(index)"]) }
        }
        await EfficiencyProtocol.waitFor { EfficiencyProtocol.count("/chats/") == 4 }
        precondition(EfficiencyProtocol.peak("/chats/") == 3)
        let queued = Task { try await service.loadChatPreviews(characterIDs: ["character-4"]) }
        while auth.resources.pendingCount != 4 { await Task.yield() }
        queued.cancel()
        do { _ = try await queued.value; preconditionFailure("Cancelled queued preview completed") } catch is CancellationError {}
        for index in 1...3 { EfficiencyProtocol.release("/chats/", queryValue: "character-\(index)") }
        for task in requests { _ = try await task.value }
        precondition(EfficiencyProtocol.count("/chats/") == 4 && EfficiencyProtocol.peak("/chats/") == 3)
        print("PASS shared preview limit across callers: peak 3; cancelled queue sends no request")

        auth.resources.clear()
        EfficiencyProtocol.configure { request in
            if request.url?.path.hasPrefix("/chats/recent") == true { return recent() }
            if EfficiencyProtocol.query(request, "character_ids") == "character-1" { return EfficiencyProtocol.Reply("{}", status: 503) }
            return preview("wrong-character")
        }
        await vm.loadRecentChats(forceRefresh: true)
        let refreshed = vm.recentPreviewGeneration
        precondition(refreshed != generation && vm.recentChats.allSatisfy { $0.lastMessage == nil })
        await vm.loadRecentPreview(characterID: "character-0", generation: generation)
        precondition(EfficiencyProtocol.count("/chats/") == 0)
        await vm.loadRecentPreview(characterID: "character-0", generation: refreshed)
        await vm.loadRecentPreview(characterID: "character-1", generation: refreshed)
        precondition(vm.recentChats.allSatisfy { $0.lastMessage == nil } && vm.errorMessage == nil)
        precondition(EfficiencyProtocol.count("/chats/") == 2)
        EfficiencyProtocol.configure(held: ["/chats/"]) { request in
            request.url?.path.hasPrefix("/chats/recent") == true ? recent() : preview(EfficiencyProtocol.query(request, "character_ids") ?? "")
        }
        print("PASS refresh generation, stale-demand suppression, wrong-character exclusion and failed-preview fallback")

        auth.resources.invalidate("previews:character-0")
        let invisible = Task { await vm.loadRecentPreview(characterID: "character-0", generation: refreshed) }
        await EfficiencyProtocol.waitFor { EfficiencyProtocol.count("/chats/") == 1 }
        invisible.cancel()
        await invisible.value
        await EfficiencyProtocol.waitFor { EfficiencyProtocol.stopped("/chats/") == 1 }
        precondition(auth.resources.pendingCount == 0)
        let logout = Task { await vm.loadRecentPreview(characterID: "character-0", generation: refreshed) }
        await EfficiencyProtocol.waitFor { EfficiencyProtocol.count("/chats/") == 2 }
        auth.clearSession()
        await logout.value
        await EfficiencyProtocol.waitFor { EfficiencyProtocol.stopped("/chats/") == 2 }
        precondition(auth.resources.count == 0)
        print("PASS last-demand cancellation and logout cancel preview work without repopulating session caches")
        EfficiencyProtocol.configure { request in
            switch request.url?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
            case "character/v1/get_user_personas": return EfficiencyProtocol.Reply("{\"personas\":[]}")
            case "chat/user": return EfficiencyProtocol.Reply("{\"id\":\"account-b\"}")
            case "chats/recent": return recent()
            default: return preview("character-0")
            }
        }
        try await auth.signIn(sessionToken: "synthetic-account-b", validator: SessionValidator(session: session))
        await vm.loadRecentPreview(characterID: "character-0", generation: refreshed)
        precondition(EfficiencyProtocol.count("/chats/") == 0)
        await vm.loadRecentChats()
        await vm.loadRecentPreview(characterID: "character-0", generation: vm.recentPreviewGeneration)
        precondition(EfficiencyProtocol.count("/chats/") == 1 && vm.recentChats[0].lastMessage == "Message 0")
        print("PASS account B rejects account A row demand, then loads its own base list and previews")
        EfficiencyProtocol.configure(held: ["/turns/chat/"]) { _ in page([99]) }
        let oldHistory = model(auth, service)
        let staleHistory = Task { await oldHistory.loadRealTurns(chatID: "chat", forceRefresh: true) }
        await EfficiencyProtocol.waitFor { EfficiencyProtocol.count("/turns/chat/") == 1 }
        auth.clearSession()
        await staleHistory.value
        await EfficiencyProtocol.waitFor { EfficiencyProtocol.stopped("/turns/chat/") == 1 }
        precondition(oldHistory.turnStates.isEmpty && auth.conversations.count == 0)
        EfficiencyProtocol.configure { request in
            switch request.url?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
            case "character/v1/get_user_personas": return EfficiencyProtocol.Reply("{\"personas\":[]}")
            case "chat/user": return EfficiencyProtocol.Reply("{\"id\":\"account-b\"}")
            default: return EfficiencyProtocol.Reply("{}")
            }
        }
        try await auth.signIn(sessionToken: "synthetic-account-b", validator: SessionValidator(session: session))
        await vm.loadRecentChats(forceRefresh: true)
        // Seed just the two caches the copy response is expected to invalidate.
        auth.resources.insert([ConversationSummary](), for: "recent-chats", ttl: 30, cost: 256)
        auth.resources.insert([ChatPreview](), for: "previews:character-0", ttl: 30, cost: 256)
        print("PASS logout during first history request cannot publish or checkpoint old-account turns")
        EfficiencyProtocol.configure { request in
            switch request.url?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
            case "chat/source/copy": return EfficiencyProtocol.Reply("{\"new_chat_id\":\"copied\"}")
            case "chats/recent": return recent()
            default: return preview("character-0")
            }
        }
        let copied = try await service.startNewConversation(chatID: "source", endTurnID: "0", modelType: "MODEL_TYPE_DEEP_SYNTH")
        precondition(copied == "copied")
        precondition(auth.resources.cached("recent-chats", as: [ConversationSummary].self) == nil)
        precondition(auth.resources.cached("previews:character-0", as: [ChatPreview].self) == nil)
        await vm.loadRecentChats(forceRefresh: true)
        await vm.loadRecentPreview(characterID: "character-0", generation: vm.recentPreviewGeneration)
        precondition(EfficiencyProtocol.count("/chats/recent/") == 1 && EfficiencyProtocol.count("/chats/") == 1)
        print("PASS copied conversation invalidates both list/preview caches and refreshes demanded rows")
        auth.resources.clear()
        EfficiencyProtocol.configure { request in
            request.url?.path.hasPrefix("/chats/recent") == true ? recent() : preview(EfficiencyProtocol.query(request, "character_ids") ?? "")
        }
        await vm.loadRecentChats(forceRefresh: true)
        let hosting = NSHostingView(rootView: SidebarFixtureView(model: vm))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 160), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        while vm.recentChats[0].lastMessage == nil { await Task.yield() }
        let initialRequests = EfficiencyProtocol.count("/chats/")
        precondition(initialRequests > 0 && initialRequests <= 4)
        hosting.layoutSubtreeIfNeeded()
        // Repeat enrichment using the same identity; body/list updates must
        // not turn a successful character preview into another HTTP request.
        await vm.loadRecentPreview(characterID: "character-0", generation: vm.recentPreviewGeneration)
        precondition(EfficiencyProtocol.peak("/chats/") <= 3)
        print("PASS native List row task publishes demanded preview; List lifecycle may prefetch additional rows")
    }

    struct SidebarFixtureView: View {
        @ObservedObject var model: ChatViewModel
        var body: some View {
            List(model.recentChats) { conversation in
                Text(conversation.lastMessage ?? conversation.characterName)
                    .task(id: model.recentPreviewGeneration) {
                        await model.loadRecentPreview(characterID: conversation.characterID,
                                                      generation: model.recentPreviewGeneration)
                    }
            }
        }
    }

    final class ImagePresentation: ObservableObject {
        @Published var pixels = 160
        var rendered: [Int] = []
    }
    struct ImageFixtureView: View {
        @ObservedObject var presentation: ImagePresentation
        let cache: ImageCacheService
        let url: URL
        var body: some View {
            let pixels = presentation.pixels
            CachedRemoteImage(url: url, maxPixelSize: pixels, cacheService: cache) { image in
                image.scaledToFit().onAppear { presentation.rendered.append(pixels) }
            } placeholder: { Color.clear } failure: { Color.red }
                .frame(width: 80, height: 80)
        }
    }

    static func images(_ session: URLSession) async throws {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1800, pixelsHigh: 1800,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let data = bitmap.representation(using: .png, properties: [:]),
              let url = URL(string: "https://offline.invalid/image") else { preconditionFailure("Image fixture unavailable") }
        EfficiencyProtocol.configure(held: ["/image"]) { _ in EfficiencyProtocol.Reply(data: data) }
        let cache = ImageCacheService(session: session)
        let avatar = Task { await cache.fetchImage(for: url) }
        let medium = Task { await cache.fetchImage(for: url, maxPixelSize: 640, pool: .media) }
        let same = Task { await cache.fetchImage(for: url, pool: .media) }
        await EfficiencyProtocol.waitFor { EfficiencyProtocol.count("/image") == 1 }
        // MainActor child tasks have registered their consumers before the
        // held URLSession response is released.
        while cache.pendingDecodeCount != 2 { await Task.yield() }
        EfficiencyProtocol.release("/image")
        let a = await avatar.value, m = await medium.value, s = await same.value
        precondition(a?.size.width == 160 && m?.size.width == 640 && s === a)
        precondition(EfficiencyProtocol.count("/image") == 1)
        precondition(cache.image(for: url) === a && cache.image(for: url, pool: .media) === a)
        precondition(ImageCacheService.avatarCostLimit + ImageCacheService.mediaCostLimit == 40 * 1024 * 1024)
        EfficiencyProtocol.configure { _ in EfficiencyProtocol.Reply(data: data) }
        for index in 0..<8 {
            guard let mediaURL = URL(string: "https://offline.invalid/media-\(index)") else { preconditionFailure("Invalid media URL") }
            let image = await cache.fetchImage(for: mediaURL, maxPixelSize: 1408, pool: .media)
            precondition(image?.size.width == 1408)
        }
        precondition(cache.image(for: url) === a)
        cache.clearDecoded(.media)
        precondition(cache.image(for: url) === a && cache.image(for: url, maxPixelSize: 640, pool: .media) == nil)
        print("PASS 160/640/1408 thumbnail bounds, cross-pool/size shared download, 16+24 MiB targets; avatar survives eight large media loads and media clear")

        EfficiencyProtocol.configure(held: ["/cancel-image"]) { _ in EfficiencyProtocol.Reply(data: data) }
        guard let cancelURL = URL(string: "https://offline.invalid/cancel-image") else { preconditionFailure("Invalid URL") }
        let cancelled = Task { await cache.fetchImage(for: cancelURL) }
        let surviving = Task { await cache.fetchImage(for: cancelURL, maxPixelSize: 640, pool: .media) }
        await EfficiencyProtocol.waitFor { EfficiencyProtocol.count("/cancel-image") == 1 }
        while cache.pendingDecodeCount != 2 { await Task.yield() }
        cancelled.cancel()
        while cache.pendingDecodeCount != 1 { await Task.yield() }
        EfficiencyProtocol.release("/cancel-image")
        let survivor = await surviving.value
        precondition(survivor?.size.width == 640)
        let cancelledImage = await cancelled.value
        precondition(cancelledImage == nil)
        while cache.pendingDownloadCount != 0 { await Task.yield() }

        EfficiencyProtocol.configure(held: ["/cancel-image"]) { _ in EfficiencyProtocol.Reply(data: data) }
        let last = Task { await cache.fetchImage(for: cancelURL) }
        await EfficiencyProtocol.waitFor { EfficiencyProtocol.count("/cancel-image") == 1 }
        last.cancel()
        let lastImage = await last.value
        precondition(lastImage == nil)
        await EfficiencyProtocol.waitFor { EfficiencyProtocol.stopped("/cancel-image") == 1 }
        while cache.pendingDecodeCount != 0 || cache.pendingDownloadCount != 0 { await Task.yield() }
        print("PASS different-resolution consumer cancellation preserves survivor; last consumer cancels download and clears bookkeeping")

        EfficiencyProtocol.configure { _ in EfficiencyProtocol.Reply(data: data) }
        let presentation = ImagePresentation()
        let hosting = NSHostingView(rootView: ImageFixtureView(presentation: presentation, cache: cache, url: url))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        while !presentation.rendered.contains(160) { await Task.yield() }
        presentation.pixels = 640
        while !presentation.rendered.contains(640) { await Task.yield() }
        precondition(cache.image(for: url, maxPixelSize: 640, pool: .media)?.size.width == 640)
        print("PASS native CachedRemoteImage changes resolution at the same URL and renders the new media result")
    }
}
