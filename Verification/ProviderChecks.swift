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

private actor PagedModelsTransport: ProviderHTTPTransport {
    var requests: [URLRequest] = []
    func consume(_ request: URLRequest, receive: @escaping @Sendable (Data) async throws -> Void) async throws {
        requests.append(request)
        let body = requests.count == 1
            ? #"{"data":[{"id":"page-one"}],"has_more":true,"last_id":"page-one"}"#
            : #"{"data":[{"id":"page-two"}],"has_more":false,"last_id":"page-two"}"#
        try await receive(Data(body.utf8))
    }
}

@MainActor
private func runExtendedProviderChecks(transport: any ProviderHTTPTransport) async throws {
    let claudeConfiguration = ProviderConfiguration(name: "Claude fixture", kind: .anthropic,
                                                   endpoint: ProviderEndpoint.defaultAnthropic)
    let responsesConfiguration = ProviderConfiguration(name: "Responses fixture", kind: .openAIResponses,
                                                       endpoint: ProviderEndpoint.defaultOpenAI)
    let claude = try TextChatProvider(configuration: claudeConfiguration, apiKey: "CLAUDE_FIXTURE", transport: transport)
    let responses = try TextChatProvider(configuration: responsesConfiguration, apiKey: "OPENAI_FIXTURE", transport: transport)
    let claudeSSE = """
    event: message_start
    data: {"type":"message_start","message":{"role":"assistant","content":[]}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello 👋"}}

    data: {"type":"ping"}

    data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}

    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}

    data: {"type":"message_stop"}


    """
    let responsesSSE = """
    event: response.created
    data: {"type":"response.created","response":{"status":"in_progress","output":[]}}

    data: {"type":"response.output_item.added","item":{"type":"reasoning"}}

    data: {"type":"response.reasoning_summary_text.delta","delta":"Not a visible reply"}

    data: {"type":"response.output_item.added","item":{"type":"message"}}

    data: {"type":"response.output_text.delta","delta":"Hello 👋"}

    data: {"type":"response.output_text.delta","delta":" world"}

    data: {"type":"response.completed","response":{"status":"completed","output":[{"type":"reasoning"},{"type":"message"}]}}


    """
    let history = [ProviderChatMessage(role: .system, content: "Character instructions"),
                   ProviderChatMessage(role: .assistant, content: "*An opening scene.*\n\nHello, {{user}}!"),
                   ProviderChatMessage(role: .user, content: "Continue")]
    for (provider, fixture) in [(claude, claudeSSE), (responses, responsesSSE)] {
        let kind = provider.descriptor.kind
        let events = ProviderEvents()
        let parser = ProviderStreamParser(kind: kind) { await events.append($0) }
        for byte in fixture.replacingOccurrences(of: "\n", with: "\r\n").utf8 {
            try await parser.consume(Data([byte]))
        }
        try await parser.finish()
        let values = await events.values
        precondition(values == [.text("Hello 👋"), .text(" world"), .finished])
        ProviderStubHTTP.configure(fixture)
        let actualEvents = ProviderEvents()
        try await provider.stream(model: "fixture-model", messages: history) { await actualEvents.append($0) }
        let actual = await actualEvents.values
        precondition(actual == values)
        let request = ProviderStubHTTP.state.withLock { $0.requests[0] }
        let body = ProviderStubHTTP.state.withLock { $0.bodies[0] }
        let wire = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        precondition(request.httpMethod == "POST" && wire["stream"] as? Bool == true)
        if kind == .anthropic {
            precondition(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
            precondition(request.value(forHTTPHeaderField: "x-api-key") == "CLAUDE_FIXTURE")
            precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
            precondition(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
            precondition(wire["system"] as? String == "Character instructions" && wire["max_tokens"] as? Int == 4096)
            let turns = wire["messages"] as! [[String: String]]
            precondition(turns.count == 3 && turns[0]["role"] == "user")
            precondition(turns[1] == ["role": "assistant", "content": history[1].content])
            precondition(turns[2] == ["role": "user", "content": "Continue"])
        } else {
            precondition(request.url?.absoluteString == "https://api.openai.com/v1/responses")
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer OPENAI_FIXTURE")
            precondition(wire["store"] as? Bool == false && wire["messages"] == nil)
            let input = wire["input"] as! [[String: String]]
            precondition(input == history.map { ["role": $0.role.rawValue, "content": $0.content] })
        }
        ProviderStubHTTP.configure(#"{"data":[{"id":"fixture-model"}],"has_more":false}"#)
        let models = try await provider.models()
        precondition(models.map(\.id) == ["fixture-model"])
        for (status, error) in [(401, ProviderError.authentication), (403, .forbidden), (429, .rateLimited)] {
            ProviderStubHTTP.configure("PRIVATE_KEY", status: status)
            try await expectProviderError(error) { _ = try await provider.models() }
        }
        ProviderStubHTTP.configure(hold: true)
        let task = Task { try await provider.stream(model: "fixture-model", messages: history) { _ in } }
        try await providerEventually("Native provider request never started") { ProviderStubHTTP.state.withLock { !$0.requests.isEmpty } }
        task.cancel()
        do { try await task.value; preconditionFailure("Native stream cancellation lost") }
        catch is CancellationError {}
        try await providerEventually("Native HTTP task was not cancelled") { ProviderStubHTTP.state.withLock { $0.cancellations > 0 } }
    }
    let failures: [(ProviderKind, String, ProviderError)] = [
        (.anthropic, #"{"type":"error","error":{"message":"PRIVATE"}}"#, .streamFailed),
        (.anthropic, #"{"type":"content_block_start","content_block":{"type":"tool_use"}}"#, .unsupportedModel),
        (.anthropic, #"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#, .unsupportedModel),
        (.anthropic, #"{"type":"message_stop"}"#, .interrupted),
        (.anthropic, #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"partial"}}"#, .interrupted),
        (.openAIResponses, #"{"type":"response.failed"}"#, .streamFailed),
        (.openAIResponses, #"{"type":"response.incomplete"}"#, .interrupted),
        (.openAIResponses, #"{"type":"response.refusal.delta","delta":"No"}"#, .streamFailed),
        (.openAIResponses, #"{"type":"response.output_item.added","item":{"type":"function_call"}}"#, .unsupportedModel),
        (.openAIResponses, #"{"type":"response.output_text.delta","delta":"partial"}"#, .interrupted),
        (.openAIResponses, #"{"type":"response.completed","response":{"status":"completed","output":[]}}"#, .emptyResponse)
    ]
    for (kind, event, error) in failures {
        let parser = ProviderStreamParser(kind: kind) { _ in }
        try await expectProviderError(error) {
            try await parser.consume(Data("data: \(event)\n\n".utf8))
            try await parser.finish()
        }
    }
    for kind in [ProviderKind.anthropic, .openAIResponses] {
        let parser = ProviderStreamParser(kind: kind) { _ in }
        try await expectProviderError(.invalidResponse) { try await parser.consume(Data("data: broken\n\n".utf8)) }
        try await expectProviderError(.invalidCloudEndpoint) {
            _ = try ProviderEndpoint.cloud("https://other.example.com/v1", kind: kind)
        }
    }
    let pagedTransport = PagedModelsTransport()
    let paged = try TextChatProvider(configuration: claudeConfiguration, apiKey: "FIXTURE", transport: pagedTransport)
    let pagedModels = try await paged.models()
    precondition(pagedModels.map(\.id) == ["page-one", "page-two"])
    let pageRequests = await pagedTransport.requests
    precondition(pageRequests.count == 2)
    let query = URLComponents(url: pageRequests[1].url!, resolvingAgainstBaseURL: false)?.queryItems
    precondition(query?.contains(URLQueryItem(name: "after_id", value: "page-one")) == true)

    let suite = "NativeProviders.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let storage = ProviderTestStorage()
    let store = ProviderStore(defaults: defaults, credentials: storage)
    for configuration in [claudeConfiguration, responsesConfiguration] {
        try store.save(configuration, newKey: "SYNTHETIC_KEY")
        let restored = ProviderStore(defaults: defaults, credentials: storage)
        let selected = ProviderSelection(kind: configuration.kind, configurationID: configuration.id, model: "fixture-model")
        let provider = try restored.provider(for: selected)
        precondition(provider.descriptor.kind == configuration.kind)
        precondition(restored.configurations.contains(configuration))
    }
    print("Claude/Responses request contracts, typed SSE, errors, cancellation, model pagination and configuration persistence passed")
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
    for endpoint in ["http://example.com/v1", "https://service.local/v1", "https://service.local./v1", "https://key@example.com/v1", "https://example.com/v1?key=x", "https://example.com/v1#secret", "http://127.0.0.1:3001/v1?key=x", "http://user@127.0.0.1:3001/v1"] {
        do { _ = try ProviderEndpoint.cloud(endpoint, kind: .openAICompatible); preconditionFailure("Unsafe cloud endpoint accepted") }
        catch is ProviderError {}
    }
    _ = try ProviderEndpoint.cloud("https://api.example.com/v1", kind: .openAICompatible)
    // A self-hosted OpenAI-compatible router is accepted on loopback only, and
    // only for the compatible kind; native API types keep their fixed hosts.
    for endpoint in ["http://127.0.0.1:3001/v1", "http://localhost:3001/v1", "http://[::1]:3001/v1", "https://127.0.0.1:3001/v1"] {
        let base = try ProviderEndpoint.cloud(endpoint, kind: .openAICompatible)
        precondition(base.lastPathComponent == "v1", "Loopback router endpoint must keep its base path")
    }
    for kind in [ProviderKind.openAI, .openAIResponses, .anthropic, .ollama] {
        do { _ = try ProviderEndpoint.cloud("http://127.0.0.1:3001/v1", kind: kind); preconditionFailure("Loopback accepted for \(kind)") }
        catch is ProviderError {}
    }
    let presetPaths = [
        "freellmapi": "http://127.0.0.1:31415/v1/chat/completions",
        "gemini": "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
        "groq": "https://api.groq.com/openai/v1/chat/completions",
        "openrouter": "https://openrouter.ai/api/v1/chat/completions",
        "cloudflare": "https://api.cloudflare.com/client/v4/accounts/YOUR_ACCOUNT_ID/ai/v1/chat/completions"
    ]
    precondition(ProviderPreset.freeCloud.count == presetPaths.count)
    for preset in ProviderPreset.freeCloud {
        let value = try preset.configuration.validated()
        precondition(value.kind == .openAICompatible && value.model.isEmpty && !preset.note.isEmpty)
        let base = try ProviderEndpoint.cloud(preset.endpoint, kind: value.kind)
        precondition(base.appendingPathComponent("chat/completions").absoluteString == presetPaths[preset.id],
                     "Preset \(preset.id) must hit its documented Chat Completions URL")
    }
    try await expectProviderError(.invalidCloudEndpoint) {
        _ = try ProviderEndpoint.cloud("https://other.example.com/v1", kind: .openAI)
    }
    var invalid = configuration
    invalid.model = "model\ninjected"
    try await expectProviderError(.invalidConfiguration) { _ = try invalid.validated() }
    try await expectProviderError(.missingCredential) {
        _ = try TextChatProvider(configuration: configuration, apiKey: "key\r\ninjected")
    }

    // Router health metadata: unusable models are flagged, `auto` leads, and a
    // provider that omits the fields keeps every model selectable.
    ProviderStubHTTP.configure("""
    {"data":[{"id":"gemini-x","available":true,"execution_status":"ready"},
    {"id":"auto","available":true},
    {"id":"embed","available":false,"unavailable_reason":"disabled"},
    {"id":"quota","available":true,"execution_status":"exhausted"},
    {"id":"needs-key","execution_status":"needsKey"},
    {"id":"plain-model"}]}
    """)
    let routed = try await cloud.models()
    precondition(routed.map(\.id) == ["auto", "gemini-x", "plain-model", "embed", "needs-key", "quota"],
                 "Router entries lead, then ready models, then the unusable ones")
    precondition(routed.map(\.isAvailable) == [true, true, true, false, false, false],
                 "Only an explicit report may hide a model")

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

    // Dropping the owner must stop its HTTP work, even without a view callback.
    for _ in 0..<5 {
        ProviderStubHTTP.configure(hold: true)
        var releasedChat: ProviderChatViewModel? = ProviderChatViewModel(provider: local, model: "fixture-model")
        let chatWasReleased = { [weak releasedChat] in releasedChat == nil }
        releasedChat?.send("Synthetic lifecycle check")
        try await providerEventually("Released chat never started HTTP") {
            ProviderStubHTTP.state.withLock { !$0.requests.isEmpty }
        }
        releasedChat = nil
        precondition(chatWasReleased(), "The stream must not retain its view model")
        try await providerEventually("Releasing the chat did not cancel HTTP") {
            ProviderStubHTTP.state.withLock { $0.cancellations > 0 }
        }
    }

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

    // Provider transcripts are client-side only, so edit, regenerate, rewind and
    // fork must leave exactly the turns a resend would carry.
    ProviderStubHTTP.configure(ndjson)
    let editable = ProviderChatViewModel(provider: local, model: "fixture-model")
    for prompt in ["First", "Second"] {
        editable.send(prompt)
        try await providerEventually("Provider reply did not finish") { !editable.isGenerating }
    }
    precondition(editable.messages.map(\.role) == [.user, .assistant, .user, .assistant])
    precondition(editable.messages.allSatisfy { $0.content == "Hello 👋 world" || $0.content == "First" || $0.content == "Second" })

    let firstPromptID = editable.messages[0].id
    precondition(editable.editMessage(firstPromptID, newContent: "  Corrected prompt  "))
    precondition(editable.messages.count == 1, "Editing drops everything that answered the old text")
    precondition(editable.messages[0].content == "Corrected prompt")
    precondition(!editable.editMessage(firstPromptID, newContent: " \n "), "Empty edits must be rejected")
    precondition(editable.messages.count == 1 && editable.messages[0].content == "Corrected prompt")
    precondition(!editable.editMessage(UUID(), newContent: "Unknown"), "Unknown messages cannot be edited")

    editable.send("Third")
    try await providerEventually("Third reply did not finish") { !editable.isGenerating }
    precondition(editable.messages.map(\.role) == [.user, .user, .assistant])
    let thirdReplyID = editable.messages[2].id
    precondition(editable.canRegenerate(thirdReplyID))
    precondition(!editable.canRegenerate(editable.messages[1].id), "Only replies can be regenerated")
    precondition(editable.regenerateMessage(thirdReplyID))
    try await providerEventually("Regenerated reply did not finish") { !editable.isGenerating }
    precondition(editable.messages.count == 3 && editable.messages[2].id != thirdReplyID)
    precondition(editable.messages[2].role == .assistant && editable.messages[1].content == "Third")

    // A greeting has no prompt to re-send.
    editable.newConversation()
    precondition(editable.messages.isEmpty && !editable.canRegenerate(UUID()))

    let rewinding = ProviderChatViewModel(provider: local, model: "fixture-model")
    for prompt in ["One", "Two"] {
        rewinding.send(prompt)
        try await providerEventually("Rewind fixture did not finish") { !rewinding.isGenerating }
    }
    let keptReplyID = rewinding.messages[1].id
    precondition(rewinding.rewind(through: keptReplyID))
    precondition(rewinding.messages.count == 2 && rewinding.messages[1].id == keptReplyID)
    precondition(!rewinding.rewind(through: UUID()), "Unknown messages cannot be rewound")
    rewinding.retry()
    try await providerEventually("Retry after rewind did not finish") { !rewinding.isGenerating }
    // Retry re-runs the kept reply rather than appending past it.
    precondition(rewinding.messages.count == 2 && rewinding.messages.last?.content == "Hello 👋 world")

    let forkSource = rewinding.messages[0]
    precondition(rewinding.fork(through: forkSource.id))
    precondition(rewinding.messages.map(\.id) == [forkSource.id])
    rewinding.retry()
    precondition(!rewinding.isGenerating && rewinding.messages.count == 1,
                 "A fork must not keep the old retry target")

    // Provider chats resume from disk, and edit/rewind/fork rewrite the saved
    // turns instead of leaving a stale copy behind.
    let transcriptRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("veyrin-transcripts-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: transcriptRoot) }
    let transcriptStore = ProviderTranscriptStore(supportDirectory: transcriptRoot)
    ProviderStubHTTP.configure(ndjson)

    let savedChat = ProviderChatViewModel(provider: local, model: "fixture-model", transcripts: transcriptStore)
    precondition(savedChat.messages.isEmpty, "A chat that was never used must not invent history")
    savedChat.send("Saved prompt")
    try await providerEventually("Saved chat did not finish") { !savedChat.isGenerating }
    precondition(savedChat.storageErrorMessage == nil && savedChat.messages.count == 2)

    let resumed = ProviderChatViewModel(provider: local, model: "fixture-model", transcripts: transcriptStore)
    precondition(resumed.messages.map(\.content) == savedChat.messages.map(\.content),
                 "Reopening the same chat resumes its saved turns")
    precondition(ProviderChatViewModel(provider: local, model: "other-model", transcripts: transcriptStore).messages.isEmpty,
                 "A different model is a different conversation")

    precondition(resumed.rewind(through: resumed.messages[0].id))
    let rewound = ProviderChatViewModel(provider: local, model: "fixture-model", transcripts: transcriptStore)
    precondition(rewound.messages.count == 1 && rewound.messages[0].content == "Saved prompt")
    precondition(rewound.editMessage(rewound.messages[0].id, newContent: "Edited prompt"))
    let edited = ProviderChatViewModel(provider: local, model: "fixture-model", transcripts: transcriptStore)
    precondition(edited.messages.count == 1 && edited.messages[0].content == "Edited prompt",
                 "Editing must rewrite the saved transcript")

    edited.newConversation()
    precondition(ProviderChatViewModel(provider: local, model: "fixture-model", transcripts: transcriptStore).messages.isEmpty,
                 "New Chat replaces the saved conversation")

    let generatedCharacter = try LocalCharacter(record: [
        "archive_id": UUID().uuidString, "name": "Generated Guide",
        "source": ["source_platform": "synthetic"],
        "source_metadata": ["generation": ["prompt_version": "fixture"]]
    ])
    precondition(generatedCharacter.origin == "Generated" && generatedCharacter.isGenerated,
                 "Current generation metadata must not label originals as imported")

    let greetingCharacter = try LocalCharacter(accountExportRecord: ["external_id": "saved-greeting",
                                                                   "name": "Guide",
                                                                   "greeting": "Welcome back."])
    let greeted = ProviderChatViewModel(provider: local, model: "fixture-model",
                                        character: greetingCharacter, transcripts: transcriptStore)
    precondition(greeted.messages.map(\.content) == ["Welcome back."])
    greeted.send("Hello")
    try await providerEventually("Greeting chat did not finish") { !greeted.isGenerating }
    let greetedAgain = ProviderChatViewModel(provider: local, model: "fixture-model",
                                            character: greetingCharacter, transcripts: transcriptStore)
    precondition(greetedAgain.messages.count == 3 && greetedAgain.messages[0].content == "Welcome back.",
                 "A resumed chat must not duplicate its greeting")
    greetedAgain.setCharacter(nil)
    precondition(greetedAgain.messages.isEmpty, "Each character keeps its own slot")

    let blockedPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("veyrin-blocked-\(UUID().uuidString)")
    try Data("not a directory".utf8).write(to: blockedPath)
    defer { try? FileManager.default.removeItem(at: blockedPath) }
    let blockedChat = ProviderChatViewModel(provider: local, model: "fixture-model",
                                           transcripts: ProviderTranscriptStore(supportDirectory: blockedPath))
    blockedChat.send("Nowhere to save")
    try await providerEventually("Blocked save chat did not finish") { !blockedChat.isGenerating }
    precondition(blockedChat.storageErrorMessage != nil, "A failed save must be reported, not swallowed")

    // A failed read must never turn into an empty chat that overwrites history.
    let unreadableRoot = transcriptRoot.appendingPathComponent("unreadable")
    let unreadableStore = ProviderTranscriptStore(supportDirectory: unreadableRoot)
    let unreadableKey = ProviderTranscriptKey(providerID: local.descriptor.id, kind: .ollama,
                                             model: "fixture-model", characterID: nil)
    try unreadableStore.save([ProviderChatMessage(role: .user, content: "Preserve me")], for: unreadableKey)
    let unreadableFolder = unreadableRoot.appendingPathComponent("provider-chats")
    let unreadableFile = try FileManager.default.contentsOfDirectory(at: unreadableFolder,
                                                                    includingPropertiesForKeys: nil)[0]
    let corruptBytes = Data("{unfinished transcript".utf8)
    try corruptBytes.write(to: unreadableFile)
    let unreadableChat = ProviderChatViewModel(provider: local, model: "fixture-model", transcripts: unreadableStore)
    precondition(unreadableChat.storageErrorMessage != nil && unreadableChat.messages.isEmpty)
    unreadableChat.send("Must not replace the damaged history")
    unreadableChat.newConversation()
    precondition(!unreadableChat.isGenerating && unreadableChat.messages.isEmpty)
    do {
        try unreadableStore.save([], for: unreadableKey)
        preconditionFailure("A corrupt transcript must not be overwritten")
    } catch is ProviderTranscriptError { }
    let preservedBytes = try Data(contentsOf: unreadableFile)
    precondition(preservedBytes == corruptBytes)

    // A valid JSON transcript under the wrong identity is just as unsafe.
    let mismatched = ProviderTranscript(key: ProviderTranscriptKey(providerID: "another-provider", kind: .ollama,
                                                                  model: "fixture-model", characterID: nil), messages: [])
    let mismatchedBytes = try JSONEncoder().encode(mismatched)
    try mismatchedBytes.write(to: unreadableFile)
    do {
        _ = try unreadableStore.load(unreadableKey)
        preconditionFailure("A mismatched transcript must fail closed")
    } catch is ProviderTranscriptError { }
    do {
        try unreadableStore.save([], for: unreadableKey)
        preconditionFailure("A mismatched transcript must not be overwritten")
    } catch is ProviderTranscriptError { }
    let stillMismatched = try Data(contentsOf: unreadableFile)
    precondition(stillMismatched == mismatchedBytes)

    // Reopened sidebar rows must agree with saves, reject damaged message
    // identities, and pick up repaired files rather than stale summaries.
    let projectionRoot = transcriptRoot.appendingPathComponent("summary-projection")
    let projectionStore = ProviderTranscriptStore(supportDirectory: projectionRoot)
    let projectionKey = ProviderTranscriptKey(providerID: "synthetic", kind: .openAICompatible,
                                              model: "projection-fixture", characterID: "synthetic-character")
    let projectionMessages = [
        ProviderChatMessage(role: .system, content: "Synthetic instruction"),
        ProviderChatMessage(role: .user, content: "Unicode 👋 question"),
        ProviderChatMessage(role: .assistant, content: "**Synthetic** answer\nNext line"),
        ProviderChatMessage(role: .system, content: "Not a sidebar preview")
    ]
    try projectionStore.save(projectionMessages, for: projectionKey, characterName: "Synthetic character",
                             avatarFileName: "synthetic-avatar.png", providerName: "Synthetic provider")
    precondition(ProviderTranscriptStore(supportDirectory: projectionRoot).summaries == projectionStore.summaries)
    let projectionFolder = projectionRoot.appendingPathComponent("provider-chats")
    let projectionFile = try FileManager.default.contentsOfDirectory(at: projectionFolder, includingPropertiesForKeys: nil)[0]
    let originalProjection = try Data(contentsOf: projectionFile)
    var malformedProjection = try JSONSerialization.jsonObject(with: originalProjection) as! [String: Any]
    var malformedMessages = malformedProjection["messages"] as! [[String: Any]]
    malformedMessages[0]["id"] = "not-a-uuid"
    malformedProjection["messages"] = malformedMessages
    try JSONSerialization.data(withJSONObject: malformedProjection).write(to: projectionFile)
    precondition(ProviderTranscriptStore(supportDirectory: projectionRoot).summaries.isEmpty)
    try originalProjection.write(to: projectionFile)
    precondition(ProviderTranscriptStore(supportDirectory: projectionRoot).summaries.count == 1,
                 "Reopening must read repaired files rather than stale summaries")
    try projectionStore.save([ProviderChatMessage(role: .assistant, content: "Greeting only")], for: projectionKey)
    precondition(projectionStore.summaries.isEmpty && ProviderTranscriptStore(supportDirectory: projectionRoot).summaries.isEmpty)
    try projectionStore.remove(projectionKey)
    precondition(ProviderTranscriptStore(supportDirectory: projectionRoot).summaries.isEmpty)

    // A failed deletion must keep both the row and the visible conversation.
    try FileManager.default.removeItem(at: unreadableFile)
    try unreadableStore.save([ProviderChatMessage(role: .user, content: "Keep visible")], for: unreadableKey)
    let deletionChat = ProviderChatViewModel(provider: local, model: "fixture-model", transcripts: unreadableStore)
    // A regular file in place of the parent fails without relying on permissions.
    try FileManager.default.removeItem(at: unreadableFolder)
    try Data("not a directory".utf8).write(to: unreadableFolder)
    deletionChat.newConversation()
    precondition(deletionChat.messages.map(\.content) == ["Keep visible"])
    precondition(deletionChat.storageErrorMessage != nil)
    precondition(unreadableStore.summaries.contains { $0.key == unreadableKey })

    // Sidebar summaries: newest first, Markdown flattened, and only real
    // conversations (a greeting on its own is not a saved chat yet).
    let sidebarKey = ProviderTranscriptKey(providerID: "ollama", kind: .ollama,
                                          model: "sidebar-model", characterID: "saved-greeting")
    try transcriptStore.save([ProviderChatMessage(role: .assistant, content: "Hi"),
                              ProviderChatMessage(role: .user, content: "hello"),
                              ProviderChatMessage(role: .assistant, content: "*smiles*\n\nGood to see you")],
                             for: sidebarKey, characterName: "Guide")
    let sidebarRow = transcriptStore.summaries.first
    precondition(sidebarRow?.title == "Guide" && sidebarRow?.key == sidebarKey)
    precondition(sidebarRow?.preview == "smiles Good to see you",
                 "The sidebar flattens Markdown and line breaks into one line")
    precondition(transcriptStore.summaries.map(\.updatedAt) == transcriptStore.summaries.map(\.updatedAt).sorted(by: >),
                 "Newest conversations lead the sidebar")
    let greetingOnlyKey = ProviderTranscriptKey(providerID: "ollama", kind: .ollama,
                                               model: "sidebar-model", characterID: "greeting-only")
    try transcriptStore.save([ProviderChatMessage(role: .assistant, content: "Welcome.")],
                             for: greetingOnlyKey, characterName: "Guide")
    precondition(!transcriptStore.summaries.contains { $0.key == greetingOnlyKey },
                 "A chat with no user message has no sidebar row")
    try transcriptStore.remove(sidebarKey)
    precondition(!transcriptStore.summaries.contains { $0.key == sidebarKey },
                 "Removing a chat removes its sidebar row")

    // A chat with no character is titled by its provider, so a local chat and a
    // cloud chat are not two identical "Provider chat" rows that open different
    // providers from the same-looking tap.
    let providerTitledKey = ProviderTranscriptKey(providerID: "ollama", kind: .ollama,
                                                 model: "sidebar-model", characterID: nil)
    try transcriptStore.save([ProviderChatMessage(role: .user, content: "hi there")],
                             for: providerTitledKey, providerName: "Ollama")
    precondition(transcriptStore.summaries.first { $0.key == providerTitledKey }?.title == "Ollama",
                 "A chat with no character is titled by its provider")
    let legacyLocalRow = ProviderTranscriptSummary(key: providerTitledKey, characterName: nil,
                                                  providerName: nil, avatarFileName: nil,
                                                  lastMessage: nil, updatedAt: Date())
    precondition(legacyLocalRow.title == "Ollama",
                 "A transcript saved before provider names still says which provider it belongs to")
    let legacyCloudRow = ProviderTranscriptSummary(
        key: ProviderTranscriptKey(providerID: UUID().uuidString, kind: .openAICompatible,
                                   model: "auto", characterID: nil),
        characterName: nil, providerName: nil, avatarFileName: nil,
        lastMessage: nil, updatedAt: Date())
    precondition(legacyCloudRow.title == "Cloud chat" && legacyCloudRow.title != legacyLocalRow.title,
                 "A local chat and a cloud chat never share a title")
    try transcriptStore.remove(providerTitledKey)

    // A deleted character must not redirect its sidebar row to the unrelated
    // no-character slot. The current chat and both saved files stay untouched.
    let missingLibrary = LocalCharacterLibrary(supportDirectory: transcriptRoot.appendingPathComponent("missing-character"))
    let missingCharacterSummary = ProviderTranscriptSummary(
        key: ProviderTranscriptKey(providerID: "ollama", kind: .ollama, model: "fixture-model", characterID: "removed-character"),
        characterName: "Removed fixture", avatarFileName: nil, lastMessage: nil, updatedAt: Date())
    let existingScreen = coordinator.screen
    let existingChat = coordinator.chat
    coordinator.open(missingCharacterSummary, store: store, library: missingLibrary)
    precondition(coordinator.screen == existingScreen && coordinator.chat === existingChat)
    precondition(coordinator.errorMessage?.contains("character is no longer") == true)

    if let supportRoot = ProcessInfo.processInfo.environment["VEYRIN_SUPPORT_DIRECTORY"] {
        let isolatedCharacter = try LocalCharacter(record: ["archive_id": UUID().uuidString, "name": "Isolated fixture"])
        let envelope: [String: Any] = ["format": "veyrin.local-character-library", "characters": [["archive_id": isolatedCharacter.id, "name": isolatedCharacter.name]]]
        let input = transcriptRoot.appendingPathComponent("isolated-character.json")
        try JSONSerialization.data(withJSONObject: envelope).write(to: input)
        let defaultLibrary = LocalCharacterLibrary()
        _ = try defaultLibrary.importArchive(from: input)
        let isolatedURL = URL(fileURLWithPath: supportRoot).appendingPathComponent("characters.json")
        precondition(FileManager.default.fileExists(atPath: isolatedURL.path))
        precondition(LocalCharacterLibrary(supportDirectory: URL(fileURLWithPath: supportRoot)).containsCharacter(isolatedCharacter.id))
    }

    // The Local screen runs its prepare step before asking for models: that step
    // is what starts Ollama on demand, so a screen that skipped it would report
    // the provider as unreachable whenever Ollama was not already running.
    let orderLog = ProviderOrderLog()
    let localConnection = ProviderConnection()
    localConnection.test(prepare: { await orderLog.append("prepare") }, { OrderedProvider(log: orderLog) })
    try await providerEventually("Connection test did not finish") { !localConnection.isLoading }
    let order = await orderLog.values
    precondition(order == ["prepare", "models"], "The provider must be prepared before its models are requested")
    precondition(localConnection.error == nil && localConnection.models.map(\.id) == ["ordered-model"])

    // A second run must clear the previous result rather than merge into it.
    localConnection.test { OrderedProvider(log: ProviderOrderLog()) }
    try await providerEventually("Second connection test did not finish") { !localConnection.isLoading }
    precondition(localConnection.models.map(\.id) == ["ordered-model"] && localConnection.status != nil)

    precondition(!local.descriptor.capabilities.contains(.characters) && !cloud.descriptor.capabilities.contains(.accountHistory))
    precondition(ProviderDescriptor.characterAI.capabilities.contains(.characters))

    // Instantiate the actual native screens in both appearances. This is a layout
    // smoke check, not an interactive or visual approval of the design.
    _ = NSApplication.shared
    let auth = AuthStore(storage: ProviderTestStorage(), restoreSession: false)
    let sidebarLibrary = LocalCharacterLibrary(supportDirectory: transcriptRoot)
    for scheme in [ColorScheme.light, .dark] {
        let views: [AnyView] = [
            AnyView(ProviderSelectionView(coordinator: coordinator, store: store, authStore: auth)),
            AnyView(LocalProviderSetupView(store: store)),
            AnyView(CloudProviderSetupView(store: store)),
            AnyView(ProviderChatView(viewModel: interrupted, accountPersonas: auth.personas, onSwitch: {})),
            // The provider chat picks characters from this library, which adds
            // Start chat and a no-character entry on top of the editing screen.
            AnyView(LocalCharacterLibraryView(onStartChat: { _ in })),
            AnyView(ProviderConversationSidebar(store: transcriptStore, library: sidebarLibrary,
                                                chat: interrupted, errorMessage: nil,
                                                onOpen: { _ in }, onNewChat: {}))
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
    try await runExtendedProviderChecks(transport: transport)
    print("Provider endpoints, credentials, model discovery, NDJSON/SSE framing/errors, HTTP cancellation, selection/restoration, session gates, switching/retry, transcript edit/regenerate/rewind/fork, saved-transcript resume and native layout checks passed")
}

/// Records the order of the steps a connection test performs.
private actor ProviderOrderLog {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

/// A provider that only reports the moment it is asked for models, so a check
/// can prove the prepare step (starting Ollama) happened first.
private nonisolated struct OrderedProvider: ChatProvider {
    let log: ProviderOrderLog
    let descriptor = ProviderDescriptor(id: "ordered", name: "Ordered", kind: .ollama,
                                        capabilities: [.textChat, .modelDiscovery])

    func models() async throws -> [ModelDescriptor] {
        await log.append("models")
        return [ModelDescriptor(id: "ordered-model")]
    }

    func stream(model: String, messages: [ProviderChatMessage],
                receive: @escaping @Sendable (ChatStreamEvent) async throws -> Void) async throws {}
}
