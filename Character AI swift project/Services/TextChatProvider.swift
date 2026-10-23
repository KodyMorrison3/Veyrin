import Foundation

nonisolated struct TextChatProvider: ChatProvider {
    let descriptor: ProviderDescriptor
    let baseURL: URL
    private let apiKey: String?
    private let transport: any ProviderHTTPTransport

    init(localEndpoint: String, transport: any ProviderHTTPTransport = ProviderHTTPClient()) throws {
        baseURL = try ProviderEndpoint.local(localEndpoint)
        descriptor = ProviderDescriptor(id: "ollama", name: "Ollama", kind: .ollama,
                                        capabilities: [.textChat, .streaming, .modelDiscovery])
        apiKey = nil
        self.transport = transport
    }

    init(configuration: ProviderConfiguration, apiKey: String,
         transport: any ProviderHTTPTransport = ProviderHTTPClient()) throws {
        let configuration = try configuration.validated()
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !apiKey.contains(where: { $0.isNewline || $0.isWhitespace }) else { throw ProviderError.missingCredential }
        baseURL = try ProviderEndpoint.cloud(configuration.endpoint, kind: configuration.kind)
        descriptor = ProviderDescriptor(id: configuration.id.uuidString, name: configuration.name,
                                        kind: configuration.kind, capabilities: [.textChat, .streaming, .modelDiscovery])
        self.apiKey = apiKey
        self.transport = transport
    }

    func models() async throws -> [ModelDescriptor] {
        var request = request(path: descriptor.kind == .ollama ? "api/tags" : "models")
        request.timeoutInterval = descriptor.kind == .ollama ? 5 : 20
        let data = try await transport.data(request)
        return try await Self.decodeModels(data, local: descriptor.kind == .ollama)
    }

    @concurrent private static func decodeModels(_ data: Data, local: Bool) async throws -> [ModelDescriptor] {
        do {
            let names: [String]
            if local {
                names = try JSONDecoder().decode(LocalModels.self, from: data).models.map(\.name)
            } else {
                names = try JSONDecoder().decode(CloudModels.self, from: data).data.map(\.id)
            }
            return Set(names.filter { !$0.isEmpty && $0.count <= 200 }).sorted().map { ModelDescriptor(id: $0) }
        } catch { throw ProviderError.invalidResponse }
    }

    func stream(model: String, messages: [ProviderChatMessage],
                receive: @escaping @Sendable (ChatStreamEvent) async throws -> Void) async throws {
        guard !model.isEmpty, model.count <= 200 else { throw ProviderError.missingModel }
        guard !messages.isEmpty, messages.count <= 200,
              messages.reduce(0, { $0 + $1.content.utf8.count }) <= 2 * 1024 * 1024 else {
            throw ProviderError.responseTooLarge
        }
        let local = descriptor.kind == .ollama
        var request = request(path: local ? "api/chat" : "chat/completions")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(local ? "application/x-ndjson" : "text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try await Self.encode(model: model, messages: messages)
        let parser = ProviderStreamParser(local: local, receive: receive)
        try await transport.consume(request) { try await parser.consume($0) }
        try await parser.finish()
    }

    private func request(path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = descriptor.kind == .ollama ? 180 : 60
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return request
    }

    @concurrent private static func encode(model: String, messages: [ProviderChatMessage]) async throws -> Data {
        try JSONEncoder().encode(ChatRequest(model: model, messages: messages.map {
            WireMessage(role: $0.role.rawValue, content: $0.content)
        }, stream: true))
    }

    private struct LocalModels: Decodable { let models: [LocalModel] }
    private struct LocalModel: Decodable { let name: String }
    private struct CloudModels: Decodable { let data: [CloudModel] }
    private struct CloudModel: Decodable { let id: String }
    private struct WireMessage: Encodable { let role: String; let content: String }
    private struct ChatRequest: Encodable { let model: String; let messages: [WireMessage]; let stream: Bool }
}

/// Bytes are framed before UTF-8 decoding so split Unicode and CRLF boundaries
/// cannot corrupt text. EOF is never silently treated as successful generation.
actor ProviderStreamParser {
    private let local: Bool
    private let receive: @Sendable (ChatStreamEvent) async throws -> Void
    private var line = Data()
    private var eventData: [String] = []
    private var eventBytes = 0
    private var skipLF = false
    private var finished = false
    private var sawText = false
    private var bytes = 0

    init(local: Bool, receive: @escaping @Sendable (ChatStreamEvent) async throws -> Void) {
        self.local = local
        self.receive = receive
    }

    func consume(_ data: Data) async throws {
        bytes += data.count
        guard bytes <= 4 * 1024 * 1024 else { throw ProviderError.responseTooLarge }
        for byte in data {
            try Task.checkCancellation()
            if skipLF { skipLF = false; if byte == 10 { continue } }
            if byte == 10 || byte == 13 {
                guard let text = String(data: line, encoding: .utf8) else { throw ProviderError.invalidResponse }
                line.removeAll(keepingCapacity: true)
                if byte == 13 { skipLF = true }
                try await processLine(text)
            } else {
                guard line.count < 256 * 1024 else { throw ProviderError.responseTooLarge }
                line.append(byte)
            }
        }
    }

    func finish() async throws {
        if local && !line.isEmpty {
            guard let text = String(data: line, encoding: .utf8) else { throw ProviderError.invalidResponse }
            try await processLine(text)
        }
        guard finished else { throw ProviderError.interrupted }
        guard sawText else { throw ProviderError.emptyResponse }
    }

    private func processLine(_ text: String) async throws {
        guard !finished else { return }
        if local {
            guard !text.isEmpty else { return }
            let value: LocalChunk
            do { value = try JSONDecoder().decode(LocalChunk.self, from: Data(text.utf8)) }
            catch { throw ProviderError.invalidResponse }
            if value.error != nil { throw ProviderError.streamFailed }
            if value.message?.tool_calls != nil { throw ProviderError.unsupportedModel }
            if let content = value.message?.content, !content.isEmpty {
                sawText = true
                try await receive(.text(content))
            }
            if value.done == true { try await complete() }
        } else if text.isEmpty {
            guard !eventData.isEmpty else { return }
            let event = eventData.joined(separator: "\n")
            eventData.removeAll(keepingCapacity: true)
            eventBytes = 0
            if event == "[DONE]" { try await complete(); return }
            let value: CloudChunk
            do { value = try JSONDecoder().decode(CloudChunk.self, from: Data(event.utf8)) }
            catch { throw ProviderError.invalidResponse }
            if value.error != nil { throw ProviderError.streamFailed }
            guard let choices = value.choices else { throw ProviderError.invalidResponse }
            for choice in choices where choice.index == 0 {
                if choice.delta?.tool_calls != nil || choice.delta?.function_call != nil {
                    throw ProviderError.unsupportedModel
                }
                if let content = choice.delta?.content, !content.isEmpty {
                    sawText = true
                    try await receive(.text(content))
                }
                if let refusal = choice.delta?.refusal, !refusal.isEmpty { throw ProviderError.streamFailed }
                if let reason = choice.finish_reason {
                    guard reason == "stop" || reason == "length" else { throw ProviderError.unsupportedModel }
                    // Wait for the stream terminator; a broken connection after
                    // a finish_reason is still distinguishable from normal EOF.
                }
            }
        } else if text.hasPrefix("data:") {
            var value = String(text.dropFirst(5))
            if value.hasPrefix(" ") { value.removeFirst() }
            eventBytes += value.utf8.count
            guard eventBytes <= 256 * 1024 else { throw ProviderError.responseTooLarge }
            eventData.append(value)
        }
    }

    private func complete() async throws {
        finished = true
        try await receive(.finished)
    }

    private struct LocalChunk: Decodable {
        struct Message: Decodable { let content: String?; let tool_calls: AnyCodable? }
        let message: Message?
        let done: Bool?
        let error: String?
    }
    private struct CloudChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                let content: String?
                let refusal: String?
                let tool_calls: AnyCodable?
                let function_call: AnyCodable?
            }
            let index: Int
            let delta: Delta?
            let finish_reason: String?
        }
        let choices: [Choice]?
        let error: AnyCodable?
    }
}
