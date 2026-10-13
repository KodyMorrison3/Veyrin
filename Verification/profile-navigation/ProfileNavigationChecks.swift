import Combine
import Foundation

// Deterministic fixture network. Each scenario builds a URLSession whose only protocol
// class is this one, so no live Character.AI traffic is made and nothing is registered
// globally. Requests are keyed by character ID ("profile:<id>" or "similar:<id>").
nonisolated final class ProfileFixtureProtocol: URLProtocol, @unchecked Sendable {
    struct Route: Sendable {
        let status: Int
        let delay: TimeInterval
        let body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var log: [String] = []
    nonisolated(unsafe) private static var routes: [String: Route] = [:]

    static func configure(_ newRoutes: [String: Route]) {
        lock.lock()
        defer { lock.unlock() }
        routes = newRoutes
        log = []
    }

    static func events() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    private static func record(_ event: String) {
        lock.lock()
        defer { lock.unlock() }
        log.append(event)
    }

    private static func route(for key: String) -> Route {
        lock.lock()
        defer { lock.unlock() }
        return routes[key] ?? Route(status: 404, delay: 0, body: Data("{}".utf8))
    }

    private static func keyFor(_ request: URLRequest) -> String {
        let path = request.url?.path ?? ""
        if let range = path.range(of: "/recommendation/v1/character/similar/") {
            return "similar:" + String(path[range.upperBound...])
        }
        let body = bodyData(of: request)
        let id = body
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }?["external_id"]
            ?? "unknown"
        return "profile:" + id
    }

    private static func bodyData(of request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private var pending: DispatchWorkItem?
    private var requestKey = "unknown"
    private let stateLock = NSLock()
    private var finished = false

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "neo.character.ai"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        let key = Self.keyFor(request)
        let route = Self.route(for: key)
        requestKey = key
        Self.record("started:\(key)")
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: route.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        let work = DispatchWorkItem { [self] in
            stateLock.lock()
            finished = true
            stateLock.unlock()
            Self.record("completed:\(key)")
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: route.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        pending = work
        DispatchQueue.global().asyncAfter(deadline: .now() + route.delay, execute: work)
    }

    override func stopLoading() {
        stateLock.lock()
        let alreadyFinished = finished
        stateLock.unlock()
        guard !alreadyFinished else { return }
        pending?.cancel()
        Self.record("cancelled:\(requestKey)")
    }
}

private func profileJSON(_ id: String, _ name: String) -> Data {
    Data(#"{"character":{"external_id":"\#(id)","name":"\#(name)","title":"\#(name) title"},"status":"OK"}"#.utf8)
}

private let fixtureRoutes: [String: ProfileFixtureProtocol.Route] = {
    let similarOfA = #"{"characters":[{"external_id":"B","name":"Bravo","title":"Bravo title","description":"Bravo description","avatar_file_name":"b.webp"},{"external_id":"C","name":"Charlie","title":"Charlie title"},{"name":"Unlinked"}]}"#
    let noSimilar = Data(#"{"characters":[]}"#.utf8)
    return [
        "profile:A": .init(status: 200, delay: 0.01, body: profileJSON("A", "Alpha")),
        "profile:B": .init(status: 200, delay: 0.01, body: profileJSON("B", "Bravo")),
        "profile:C": .init(status: 200, delay: 0.01, body: profileJSON("C", "Charlie")),
        // X is deliberately slow so it is still in flight when it is replaced.
        "profile:X": .init(status: 200, delay: 0.5, body: profileJSON("X", "Xavier")),
        "profile:Y": .init(status: 200, delay: 0.01, body: profileJSON("Y", "Yolanda")),
        "similar:A": .init(status: 200, delay: 0.01, body: Data(similarOfA.utf8)),
        "similar:B": .init(status: 200, delay: 0.01, body: noSimilar),
        "similar:C": .init(status: 200, delay: 0.01, body: noSimilar),
        "similar:X": .init(status: 200, delay: 0.01, body: noSimilar),
        "similar:Y": .init(status: 200, delay: 0.01, body: noSimilar),
    ]
}()

/// Drives CharacterProfileNavigation and CharacterViewModel the way ContentView and
/// CharacterProfileView do: every change of the shown character cancels the previous
/// load (CharacterProfileView's .task(id:)), and dismissal cancels the current one.
@MainActor
final class ProfileFlow {
    private let viewModel: CharacterViewModel
    private var navigation = CharacterProfileNavigation()
    private var loadTasks: [Task<Void, Never>] = []
    private var cancellables = Set<AnyCancellable>()
    private(set) var profileHistory: [String] = []

    init(authStore: AuthStore) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProfileFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        viewModel = CharacterViewModel(service: CharacterService(
            httpClient: AuthenticatedHTTPClient(session: session, authStore: authStore)
        ))
        viewModel.$profileState
            .sink { [weak self] state in
                self?.profileHistory.append(Self.describe(state))
            }
            .store(in: &cancellables)
    }

    var currentCharacterID: String? { navigation.currentCharacterID }
    var canGoBack: Bool { navigation.canGoBack }
    var profileState: CharacterViewModel.LoadState<CharacterProfile> { viewModel.profileState }
    var similarState: CharacterViewModel.LoadState<[SimilarCharacter]> { viewModel.similarState }

    func show(_ characterID: String) {
        navigation.show(characterID)
        sync()
    }

    func openSimilar(_ characterID: String) {
        navigation.openSimilar(characterID)
        sync()
    }

    func back() {
        navigation.back()
        sync()
    }

    func dismiss() {
        navigation.dismiss()
        sync()
    }

    /// Waits for every load started so far, including cancelled ones, so any late publish has happened.
    func settle() async {
        for task in loadTasks {
            await task.value
        }
    }

    private func sync() {
        loadTasks.last?.cancel()
        guard let characterID = navigation.currentCharacterID else { return }
        loadTasks.append(Task { await viewModel.load(externalID: characterID) })
    }

    private static func describe(_ state: CharacterViewModel.LoadState<CharacterProfile>) -> String {
        switch state {
        case .idle: return "idle"
        case .loading: return "loading"
        case .loaded(let profile): return "loaded:\(profile.externalID)"
        case .failed: return "failed"
        }
    }
}

@MainActor
private func makeFlow() -> ProfileFlow {
    ProfileFixtureProtocol.configure(fixtureRoutes)
    // A fresh AuthStore owns a fresh ResourceCache, so no scenario can hit another scenario's cache.
    let authStore = AuthStore(session: AuthSession(sessionToken: "synthetic", userID: "user", username: "name"))
    return ProfileFlow(authStore: authStore)
}

@MainActor
private func expectLoaded(_ flow: ProfileFlow, _ id: String, _ name: String, line: Int = #line) {
    guard case .loaded(let profile) = flow.profileState else {
        preconditionFailure("line \(line): profile \(id) not loaded: \(flow.profileState)")
    }
    precondition(profile.externalID == id && profile.name == name,
                 "line \(line): expected \(id)/\(name), got \(profile.externalID)/\(profile.name ?? "nil")")
}

@MainActor
private func checkSelectionChainAndBack() async {
    let flow = makeFlow()

    flow.show("A")
    await flow.settle()
    expectLoaded(flow, "A", "Alpha")
    guard case .loaded(let similar) = flow.similarState else {
        preconditionFailure("similar characters for A did not load: \(flow.similarState)")
    }
    precondition(similar.map(\.profileID) == ["B", "C", nil], "similar IDs: \(similar.map(\.profileID))")

    flow.openSimilar("B")
    await flow.settle()
    precondition(flow.currentCharacterID == "B")
    expectLoaded(flow, "B", "Bravo")
    print("PASS selecting similar B from A shows B")

    flow.openSimilar("C")
    await flow.settle()
    precondition(flow.currentCharacterID == "C")
    expectLoaded(flow, "C", "Charlie")
    print("PASS selecting similar C from B shows C")

    flow.back()
    await flow.settle()
    precondition(flow.currentCharacterID == "B" && flow.canGoBack)
    expectLoaded(flow, "B", "Bravo")
    print("PASS Back from C returns to B")

    flow.back()
    await flow.settle()
    precondition(flow.currentCharacterID == "A" && !flow.canGoBack)
    expectLoaded(flow, "A", "Alpha")
    print("PASS Back from B returns to A")

    precondition(!flow.profileHistory.contains("failed"), "unexpected failure: \(flow.profileHistory)")
}

@MainActor
private func checkDismissClearsStack() async {
    let flow = makeFlow()
    flow.show("A")
    await flow.settle()
    flow.openSimilar("B")
    await flow.settle()
    flow.openSimilar("C")
    await flow.settle()
    precondition(flow.canGoBack)

    flow.dismiss()
    await flow.settle()
    precondition(flow.currentCharacterID == nil && !flow.canGoBack, "dismiss left navigation state")

    flow.show("A")
    await flow.settle()
    precondition(!flow.canGoBack, "back stack survived dismissal")
    print("PASS dismissal clears the back stack")
}

@MainActor
private func checkEntryWithoutIDIsNotInteractive() throws {
    let decoded = try JSONDecoder().decode(
        SimilarCharactersResponse.self,
        from: Data(#"{"characters":[{"external_id":"B"},{"name":"NoID"},{"external_id":"   "},{"external_id":""}]}"#.utf8)
    )
    precondition(decoded.characters.map(\.profileID) == ["B", nil, nil, nil],
                 "profileIDs: \(decoded.characters.map(\.profileID))")
    print("PASS similar entries without a usable external_id have no profile target")
}

@MainActor
private func checkRapidReplacementDoesNotPublishStale() async throws {
    let flow = makeFlow()

    flow.show("X")
    try await Task.sleep(for: .milliseconds(50))
    flow.openSimilar("Y")

    // Wait until the cancellation has reached the network layer, bounded to 2 s.
    var waited = 0
    while !ProfileFixtureProtocol.events().contains("cancelled:profile:X") && waited < 200 {
        try await Task.sleep(for: .milliseconds(10))
        waited += 1
    }
    await flow.settle()

    let events = ProfileFixtureProtocol.events()
    precondition(events.contains("started:profile:X"), "X never reached the network layer: \(events)")
    precondition(events.contains("cancelled:profile:X"), "X was not cancelled in flight: \(events)")
    precondition(!events.contains("completed:profile:X"), "X completed despite replacement: \(events)")
    precondition(events.contains("completed:profile:Y"), "Y did not complete: \(events)")
    precondition(!flow.profileHistory.contains("loaded:X"), "stale X published: \(flow.profileHistory)")
    precondition(!flow.profileHistory.contains("failed"), "cancellation published a failure: \(flow.profileHistory)")
    let loaded = flow.profileHistory.filter { $0.hasPrefix("loaded:") }
    precondition(loaded == ["loaded:Y"], "loaded profiles: \(loaded)")
    expectLoaded(flow, "Y", "Yolanda")
    precondition(flow.currentCharacterID == "Y" && flow.canGoBack)
    print("PASS rapid replacement: X was in flight, cancelled, never published; Y is the only loaded profile")
}

@main
struct ProfileNavigationChecks {
    @MainActor static func main() async throws {
        await checkSelectionChainAndBack()
        await checkDismissClearsStack()
        try checkEntryWithoutIDIsNotInteractive()
        try await checkRapidReplacementDoesNotPublishStale()
        print("Profile navigation checks passed")
    }
}
