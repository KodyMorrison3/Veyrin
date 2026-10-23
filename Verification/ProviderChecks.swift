import AppKit
import Foundation
import SwiftUI
import Synchronization

// No live endpoints or Keychain items are used by these checks.
nonisolated final class ProviderStubHTTP: URLProtocol, @unchecked Sendable {
    struct State {
        var status = 200
        var body = Data()
        var hold = false
        var fail = false
        var requests: [URLRequest] = []
        var bodies: [Data] = []
        var cancellations = 0
    }
    static let state = Mutex(State())

    static func configure(_ body: String = "", status: Int = 200, hold: Bool = false, fail: Bool = false) {
        state.withLock { $0 = State(status: status, body: Data(body.utf8), hold: hold, fail: fail) }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
        }
        let reply = Self.state.withLock { value in
            value.requests.append(request)
            value.bodies.append(body)
            return (value.status, value.body, value.hold, value.fail)
        }
        if reply.3 {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.0, httpVersion: "HTTP/1.1",
                                            headerFields: ["Content-Type": "application/x-ndjson"]) else {
            preconditionFailure("Fixture URL is missing")
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.1.isEmpty { client?.urlProtocol(self, didLoad: reply.1) }
        if !reply.2 { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { Self.state.withLock { $0.cancellations += 1 } }
}

private final class ProviderTestStorage: SessionStorage {
    var values: [String: Data] = [:]
    var fail = false
    func save(_ data: Data, forKey key: String) throws {
        if fail { throw KeychainError.invalidData }
        values[key] = data
    }
    func loadData(forKey key: String) throws -> Data? {
        if fail { throw KeychainError.invalidData }
        return values[key]
    }
    func delete(forKey key: String) throws {
        if fail { throw KeychainError.invalidData }
        values.removeValue(forKey: key)
    }
}

private actor ProviderEvents {
    var values: [ChatStreamEvent] = []
    func append(_ value: ChatStreamEvent) { values.append(value) }
}

private actor ProviderGate {
    var entered = false
    var completed = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
    func finish() { completed = true }
}

// Deliberately ignores cancellation at the gate. Late publication must still be rejected.
nonisolated private struct GatedProvider: ChatProvider {
    let descriptor = ProviderDescriptor(id: "fixture", name: "Fixture", kind: .ollama,
                                        capabilities: [.textChat, .streaming, .modelDiscovery])
    let gate: ProviderGate
    var discoveryError: ProviderError?
    func models() async throws -> [ModelDescriptor] {
        await gate.wait()
        if let discoveryError { throw discoveryError }
        return [ModelDescriptor(id: "fixture-model")]
    }
    func stream(model: String, messages: [ProviderChatMessage],
                receive: @escaping @Sendable (ChatStreamEvent) async throws -> Void) async throws {
        try await receive(.text("Partial"))
        await gate.wait()
        do {
            try await receive(.text(" late"))
            try await receive(.finished)
            await gate.finish()
        } catch {
            await gate.finish()
            throw error
        }
    }
}

@MainActor
private func providerEventually(_ name: String, _ condition: () async -> Bool) async throws {
    for _ in 0..<400 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    preconditionFailure(name)
}

@MainActor
private func expectProviderError(_ expected: ProviderError, _ operation: () async throws -> Void) async throws {
    do { try await operation(); preconditionFailure("Expected \(expected)") }
    catch let error as ProviderError { precondition(error == expected, "Expected \(expected), got \(error)") }
}

@MainActor
func runProviderChecks() async throws {
    let transport = ProviderHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderStubHTTP.self]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return configuration
    }
    let local = try TextChatProvider(localEndpoint: ProviderEndpoint.defaultOllama, transport: transport)
    let configuration = ProviderConfiguration(name: "Synthetic cloud", kind: .openAI,
                                              endpoint: ProviderEndpoint.defaultOpenAI, model: "text-fixture")
    let cloud = try TextChatProvider(configuration: configuration, apiKey: "SYNTHETIC_KEY", transport: transport)
    let messages = [ProviderChatMessage(role: .user, content: "Synthetic prompt")]

    for endpoint in ["http://example.com:11434", "http://127.0.0.1:11434/path", "http://user@localhost:11434", "http://localhost:11434?key=x"] {
        do { _ = try ProviderEndpoint.local(endpoint); preconditionFailure("Unsafe local endpoint accepted") }
        catch is ProviderError {}
    }
    _ = try ProviderEndpoint.local("http://[::1]:11434")
    for endpoint in ["http://example.com/v1", "https://localhost/v1", "https://127.0.0.1/v1", "https://service.local/v1", "https://service.local./v1", "https://key@example.com/v1", "https://example.com/v1?key=x", "https://example.com/v1#secret"] {
        do { _ = try ProviderEndpoint.cloud(endpoint, kind: .openAICompatible); preconditionFailure("Unsafe cloud endpoint accepted") }
        catch is ProviderError {}
    }
    _ = try ProviderEndpoint.cloud("https://api.example.com/v1", kind: .openAICompatible)
    try await expectProviderError(.invalidCloudEndpoint) {
        _ = try ProviderEndpoint.cloud("https://other.example.com/v1", kind: .openAI)
    }
    var invalid = configuration
    invalid.model = "model\ninjected"
    try await expectProviderError(.invalidConfiguration) { _ = try invalid.validated() }
    try await expectProviderError(.missingCredential) {
        _ = try TextChatProvider(configuration: configuration, apiKey: "key\r\ninjected")
    }

    ProviderStubHTTP.configure("{\"models\":[]}")
    let empty = try await local.models()
    precondition(empty.isEmpty, "Reachable Ollama with no models is not a connection failure")
    ProviderStubHTTP.configure("{\"models\":[{\"name\":\"z\"},{\"name\":\"a\"},{\"name\":\"a\"}]}")
    let models = try await local.models()
    precondition(models.map(\.id) == ["a", "z"])
    let localRequest = ProviderStubHTTP.state.withLock { $0.requests.first }
    precondition(localRequest?.url?.path == "/api/tags")
    precondition(localRequest?.value(forHTTPHeaderField: "Authorization") == nil)
    ProviderStubHTTP.configure(fail: true)
    try await expectProviderError(.unavailable) { _ = try await local.models() }
    ProviderStubHTTP.configure("not JSON")
    try await expectProviderError(.invalidResponse) { _ = try await local.models() }

    ProviderStubHTTP.configure("{\"data\":[{\"id\":\"text-fixture\"}]}")
    let cloudModels = try await cloud.models()
    precondition(cloudModels.map(\.id) == ["text-fixture"])
    let cloudRequest = ProviderStubHTTP.state.withLock { $0.requests.first }
    precondition(cloudRequest?.url?.absoluteString == "https://api.openai.com/v1/models")
    precondition(cloudRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer SYNTHETIC_KEY")
    for (status, error) in [(401, ProviderError.authentication), (403, .forbidden), (404, .missingModel), (429, .rateLimited), (500, .rejected(500)), (302, .rejected(302))] {
        ProviderStubHTTP.configure("{\"error\":\"SYNTHETIC_KEY Synthetic prompt\"}", status: status)
        try await expectProviderError(error) { _ = try await cloud.models() }
        precondition(!error.localizedDescription.contains("SYNTHETIC_KEY") && !error.localizedDescription.contains("Synthetic prompt"))
    }

    let ndjson = "{\"message\":{\"content\":\"Hello 👋\"},\"done\":false}\r\n{\"message\":{\"content\":\" world\"},\"done\":true}\n"
    let sse = ": heartbeat\r\ndata: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\"}}]}\r\n\r\ndata: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hello 👋\"},\"finish_reason\":null}]}\r\n\r\ndata: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\" world\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
    for (isLocal, fixture) in [(true, ndjson), (false, sse)] {
        let events = ProviderEvents()
        let parser = ProviderStreamParser(local: isLocal) { await events.append($0) }
        // Every UTF-8 and CRLF boundary gets split, including the emoji.
        for byte in fixture.utf8 { try await parser.consume(Data([byte])) }
        try await parser.finish()
        let values = await events.values
        precondition(values == [.text("Hello 👋"), .text(" world"), .finished])
        ProviderStubHTTP.configure(fixture)
        let httpEvents = ProviderEvents()
        try await (isLocal ? local : cloud).stream(model: "text-fixture", messages: messages) { await httpEvents.append($0) }
        let streamed = await httpEvents.values
        precondition(streamed == values)
        let request = ProviderStubHTTP.state.withLock { $0.requests.first }
        precondition(request?.httpMethod == "POST")
        precondition(request?.url?.path == (isLocal ? "/api/chat" : "/v1/chat/completions"))
        let body = ProviderStubHTTP.state.withLock { $0.bodies.first ?? Data() }
        let wire = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        precondition(wire?["stream"] as? Bool == true && wire?["model"] as? String == "text-fixture")
        let wireMessages = wire?["messages"] as? [[String: String]]
        precondition(wireMessages == [["role": "user", "content": "Synthetic prompt"]])
    }
    let malformedCases: [(Bool, String, ProviderError)] = [
        (true, "{\"message\":{\"content\":\"partial\"}}\n", .interrupted),
        (true, "{\"error\":\"private failure\"}\n", .streamFailed),
        (true, "broken\n", .invalidResponse),
        (true, "{\"done\":true}\n", .emptyResponse),
        (false, "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"partial\"}}]}\n\n", .interrupted),
        (false, "data: {\"error\":{\"message\":\"private failure\"}}\n\n", .streamFailed),
        (false, "data: broken\n\n", .invalidResponse),
        (false, "data: [DONE]\n\n", .emptyResponse),
        (false, "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[]}}]}\n\n", .unsupportedModel),
        (false, "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n", .unsupportedModel)
    ]
    for (isLocal, fixture, error) in malformedCases {
        let parser = ProviderStreamParser(local: isLocal) { _ in }
        try await expectProviderError(error) {
            try await parser.consume(Data(fixture.utf8))
            try await parser.finish()
        }
    }
    let oversized = ProviderStreamParser(local: true) { _ in }
    try await expectProviderError(.responseTooLarge) { try await oversized.consume(Data(repeating: 65, count: 256 * 1024 + 1)) }

    ProviderStubHTTP.configure(hold: true)
    let cancelled = Task { try await cloud.models() }
    try await providerEventually("Request never started") { ProviderStubHTTP.state.withLock { !$0.requests.isEmpty } }
    cancelled.cancel()
    do { _ = try await cancelled.value; preconditionFailure("HTTP cancellation swallowed") }
    catch is CancellationError {}
    try await providerEventually("URLSession task was not cancelled") { ProviderStubHTTP.state.withLock { $0.cancellations > 0 } }

    ProviderStubHTTP.configure("{\"message\":{\"content\":\"Partial HTTP\"},\"done\":false}\n", hold: true)
    let networkChat = ProviderChatViewModel(provider: local, model: "fixture-model")
    networkChat.send("Cancellation prompt")
    try await providerEventually("HTTP generation did not stream") { networkChat.streamingText == "Partial HTTP" }
    networkChat.cancel()
    precondition(networkChat.messages.last?.content == "Partial HTTP" && !networkChat.isGenerating)
    try await providerEventually("HTTP generation was not cancelled") { ProviderStubHTTP.state.withLock { $0.cancellations > 0 } }

    let suite = "ProviderChecks.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { preconditionFailure("Preferences fixture unavailable") }
    defer { defaults.removePersistentDomain(forName: suite) }
    let storage = ProviderTestStorage()
    let store = ProviderStore(defaults: defaults, credentials: storage)
    let selection = ProviderSelection(kind: .ollama, model: "fixture-model")
    precondition(!store.rememberLastProvider && store.lastSelection == nil)
    store.remember(selection)
    precondition(store.lastSelection == nil)
    store.rememberLastProvider = true
    store.remember(selection)
    precondition(ProviderStore(defaults: defaults, credentials: storage).lastSelection == selection)
    try store.save(configuration, newKey: "SYNTHETIC_KEY")
    let savedKey = try store.key(for: configuration.id)
    precondition(savedKey == "SYNTHETIC_KEY")
    let persisted = defaults.data(forKey: "providers.cloudConfigurations") ?? Data()
    precondition(!String(decoding: persisted, as: UTF8.self).contains("SYNTHETIC_KEY"))
    store.rememberLastProvider = false
    precondition(store.lastSelection == nil && defaults.data(forKey: "providers.lastSelection") == nil)
    let retainedKey = try store.key(for: configuration.id)
    precondition(retainedKey == "SYNTHETIC_KEY", "Remember preference must not remove credentials")
    var changed = configuration
    changed.kind = .openAICompatible
    changed.endpoint = "https://api.example.com/v1"
    try await expectProviderError(.missingCredential) { try store.save(changed, newKey: nil) }
    precondition(store.configurations.first?.endpoint == ProviderEndpoint.defaultOpenAI)
    storage.fail = true
    try await expectProviderError(.credentialStorage) { _ = try store.key(for: configuration.id) }
    storage.fail = false
    try store.remove(configuration.id)
    precondition(store.configurations.isEmpty && storage.values.isEmpty)
    defaults.set(Data("broken".utf8), forKey: "providers.cloudConfigurations")
    let corrupted = ProviderStore(defaults: defaults, credentials: storage)
    try await expectProviderError(.configurationStorage) { try corrupted.save(configuration, newKey: "SYNTHETIC_KEY") }
    precondition(defaults.data(forKey: "providers.cloudConfigurations") == Data("broken".utf8))
    defaults.removeObject(forKey: "providers.cloudConfigurations")

    let coordinator = ProviderCoordinator()
    coordinator.launch(store: store)
    precondition(coordinator.screen == .selector, "Default launch must show provider selector")
    coordinator.show(.characterAI)
    coordinator.authenticationChanged(authenticated: true, store: store)
    precondition(coordinator.screen == .characterAI)
    coordinator.authenticationChanged(authenticated: false, store: store)
    precondition(coordinator.screen == .selector)
    store.rememberLastProvider = true
    store.remember(ProviderSelection(kind: .characterAI))
    let restoredCharacter = ProviderCoordinator()
    restoredCharacter.launch(store: store)
    precondition(restoredCharacter.screen == .characterAI, "Saved Character.AI choice enters the existing authentication gate")

    // Existing session validation still owns acceptance/rejection; the router never fabricates auth.
    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [ProviderStubHTTP.self]
    let session = URLSession(configuration: sessionConfiguration)
    defer { session.invalidateAndCancel() }
    let validator = SessionValidator(session: session)
    for (body, status, expectedAuth) in [("{\"personas\":[],\"user_id\":\"fixture-account\"}", 200, true), ("", 401, false)] {
        let authStorage = ProviderTestStorage()
        authStorage.values["authSession"] = try JSONEncoder().encode(AuthSession(sessionToken: "SYNTHETIC_SESSION", userID: "fixture-account", username: ""))
        let auth = AuthStore(storage: authStorage)
        ProviderStubHTTP.configure(body, status: status)
        await auth.restoreStoredSession(validator: validator)
        precondition(auth.isAuthenticated == expectedAuth && !auth.isRestoringSession)
        if !expectedAuth { precondition(authStorage.values["authSession"] == nil) }
    }
    let missing = AuthStore(storage: ProviderTestStorage())
    await missing.restoreStoredSession(validator: validator)
    precondition(!missing.isAuthenticated && !missing.isRestoringSession)

    store.remember(selection)
    let restoreGate = ProviderGate()
    let restore = ProviderCoordinator()
    restore.launch(store: store) { _ in GatedProvider(gate: restoreGate) }
    try await providerEventually("Restore never requested models") { await restoreGate.entered }
    await restoreGate.release()
    try await providerEventually("Remembered local choice did not restore") { restore.screen == .textChat }
    precondition(restore.chat?.model == "fixture-model")
    let failedGate = ProviderGate()
    let failedRestore = ProviderCoordinator()
    failedRestore.launch(store: store) { _ in GatedProvider(gate: failedGate, discoveryError: .unavailable) }
    try await providerEventually("Failed restore never started") { await failedGate.entered }
    await failedGate.release()
    try await providerEventually("Failed restore remained loading") { !failedRestore.isRestoring }
    precondition(failedRestore.screen == .selector && failedRestore.errorMessage != nil)
    store.remember(ProviderSelection(kind: .ollama, model: "removed-model"))
    let missingGate = ProviderGate()
    let missingRestore = ProviderCoordinator()
    missingRestore.launch(store: store) { _ in GatedProvider(gate: missingGate) }
    try await providerEventually("Missing-model restore never started") { await missingGate.entered }
    await missingGate.release()
    try await providerEventually("Missing-model restore remained loading") { !missingRestore.isRestoring }
    precondition(missingRestore.screen == .selector && missingRestore.errorMessage == ProviderError.missingModel.localizedDescription)
    store.remember(selection)

    let connectionGate = ProviderGate()
    let connection = ProviderConnection()
    connection.test { GatedProvider(gate: connectionGate) }
    try await providerEventually("Discovery never started") { await connectionGate.entered }
    connection.reset()
    await connectionGate.release()
    for _ in 0..<10 { await Task.yield() }
    precondition(connection.models.isEmpty && !connection.isLoading && connection.status == nil)

    let obsoleteGate = ProviderGate()
    let obsolete = ProviderCoordinator()
    obsolete.launch(store: store) { _ in GatedProvider(gate: obsoleteGate) }
    try await providerEventually("Obsolete restore never started") { await obsoleteGate.entered }
    obsolete.show(.cloud)
    await obsoleteGate.release()
    for _ in 0..<10 { await Task.yield() }
    precondition(obsolete.screen == .cloud && obsolete.chat == nil)

    let generationGate = ProviderGate()
    coordinator.start(provider: GatedProvider(gate: generationGate), selection: selection, store: store)
    guard let oldChat = coordinator.chat else { preconditionFailure("Chat not created") }
    oldChat.send("First prompt")
    try await providerEventually("Generation never started") { await generationGate.entered }
    coordinator.show(.selector)
    precondition(!oldChat.isGenerating && oldChat.wasInterrupted)
    precondition(oldChat.messages.last?.content == "Partial", "Cancellation must flush pending text")
    await generationGate.release()
    try await providerEventually("Cancelled producer did not finish") { await generationGate.completed }
    precondition(oldChat.messages.last?.content == "Partial" && coordinator.chat == nil)
    oldChat.newConversation()
    precondition(oldChat.messages.isEmpty && !oldChat.wasInterrupted)

    ProviderStubHTTP.configure("{\"message\":{\"content\":\"Kept partial\"}}\n{\"error\":\"private detail\"}\n")
    let interrupted = ProviderChatViewModel(provider: local, model: "fixture-model")
    interrupted.send("Prompt")
    try await providerEventually("Stream failure did not finish") { !interrupted.isGenerating }
    precondition(interrupted.wasInterrupted && interrupted.messages.last?.content == "Kept partial" && interrupted.errorMessage != nil)
    ProviderStubHTTP.configure(ndjson)
    interrupted.retry()
    try await providerEventually("Retry did not finish") { !interrupted.isGenerating }
    precondition(interrupted.messages.count == 2 && interrupted.messages.last?.content == "Hello 👋 world")
    precondition(!interrupted.wasInterrupted && interrupted.errorMessage == nil)
    precondition(!local.descriptor.capabilities.contains(.characters) && !cloud.descriptor.capabilities.contains(.accountHistory))
    precondition(ProviderDescriptor.characterAI.capabilities.contains(.characters))

    // Instantiate the actual native screens in both appearances. This is a layout
    // smoke check, not an interactive or visual approval of the design.
    _ = NSApplication.shared
    let auth = AuthStore(storage: ProviderTestStorage(), restoreSession: false)
    for scheme in [ColorScheme.light, .dark] {
        let views: [AnyView] = [
            AnyView(ProviderSelectionView(coordinator: coordinator, store: store, authStore: auth)),
            AnyView(LocalProviderSetupView(store: store)),
            AnyView(CloudProviderSetupView(store: store)),
            AnyView(ProviderChatView(viewModel: interrupted, accountPersonas: auth.personas, onSwitch: {}))
        ]
        for view in views {
            for size in [NSSize(width: 600, height: 560), NSSize(width: 1100, height: 800)] {
                let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                precondition(host.fittingSize.width.isFinite && host.fittingSize.height.isFinite)
            }
        }
    }
    print("Provider endpoints, credentials, model discovery, NDJSON/SSE framing/errors, HTTP cancellation, selection/restoration, session gates, switching/retry and native layout checks passed")
}
