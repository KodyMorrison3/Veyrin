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
        var names: [ModelDescriptor] = []
        var cursor: String?
        var seenCursors = Set<String>()
        for _ in 0..<20 {
            var request = request(path: descriptor.kind == .ollama ? "api/tags" : "models")
            if descriptor.kind == .anthropic {
                guard let url = request.url,
                      var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                    throw ProviderError.invalidEndpoint
                }
                components.queryItems = [URLQueryItem(name: "limit", value: "100")]
                    + (cursor.map { [URLQueryItem(name: "after_id", value: $0)] } ?? [])
                request.url = components.url
            }
            request.timeoutInterval = descriptor.kind == .ollama ? 5 : 20
            let data = try await transport.data(request)
            names += try await Self.decodeModels(data, local: descriptor.kind == .ollama)
            guard names.count <= 2000 else { throw ProviderError.responseTooLarge }
            if descriptor.kind != .anthropic { return names }
            let page: CloudModels
            do { page = try JSONDecoder().decode(CloudModels.self, from: data) }
            catch { throw ProviderError.invalidResponse }
            if page.has_more != true {
                return Self.ordered(names)
            }
            guard let next = page.last_id, !next.isEmpty, seenCursors.insert(next).inserted else {
                throw ProviderError.invalidResponse
            }
            cursor = next
        }
        throw ProviderError.responseTooLarge
    }

    @concurrent private static func decodeModels(_ data: Data, local: Bool) async throws -> [ModelDescriptor] {
        do {
            if local {
                let names = try JSONDecoder().decode(LocalModels.self, from: data).models.map(\.name)
                return ordered(names.map { ModelDescriptor(id: $0) })
            }
            let entries = try JSONDecoder().decode(CloudModels.self, from: data).data
            let models = entries.compactMap { entry -> ModelDescriptor? in
                guard !entry.id.isEmpty, entry.id.count <= 200 else { return nil }
                return ModelDescriptor(id: entry.id, isAvailable: entry.isReady)
            }
            return ordered(models)
        } catch { throw ProviderError.invalidResponse }
    }

    /// Deduplicates and sorts router entries first, so a provider that offers an
    /// `auto` model leads with the selection that fails over by itself. Models a
    /// router reports as unusable stay listed but sort last and carry the flag.
    private static func ordered(_ models: [ModelDescriptor]) -> [ModelDescriptor] {
        var unique: [String: ModelDescriptor] = [:]
        for model in models where unique[model.id] == nil { unique[model.id] = model }
        func rank(_ id: String) -> Int {
            if id == "auto" { return 0 }
            if id.hasPrefix("auto:") { return 1 }
            return 2
        }
        return unique.values.sorted { lhs, rhs in
            guard lhs.id != rhs.id else { return false }
            if lhs.isAvailable != rhs.isAvailable { return lhs.isAvailable }
            let lhsRank = rank(lhs.id), rhsRank = rank(rhs.id)
            return lhsRank == rhsRank ? lhs.id < rhs.id : lhsRank < rhsRank
        }
    }

    func stream(model: String, messages: [ProviderChatMessage],
                receive: @escaping @Sendable (ChatStreamEvent) async throws -> Void) async throws {
        guard !model.isEmpty, model.count <= 200 else { throw ProviderError.missingModel }
        guard !messages.isEmpty, messages.count <= 200,
              messages.reduce(0, { $0 + $1.content.utf8.count }) <= 2 * 1024 * 1024 else {
            throw ProviderError.responseTooLarge
        }
        let kind = descriptor.kind
        let local = kind == .ollama
        let path = switch kind {
        case .ollama: "api/chat"
        case .anthropic: "messages"
        case .openAIResponses: "responses"
        default: "chat/completions"
        }
        var request = request(path: path)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(local ? "application/x-ndjson" : "text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try await Self.encode(model: model, messages: messages, kind: kind)
        let parser = ProviderStreamParser(kind: kind, receive: receive)
        try await transport.consume(request) { try await parser.consume($0) }
        try await parser.finish()
    }

    private func request(path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = descriptor.kind == .ollama ? 180 : 60
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey {
            if descriptor.kind == .anthropic {
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            } else {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        }
        return request
    }

    @concurrent private static func encode(model: String, messages: [ProviderChatMessage], kind: ProviderKind) async throws -> Data {
        let wire = messages.map { WireMessage(role: $0.role.rawValue, content: $0.content) }
        if kind == .openAIResponses {
            return try JSONEncoder().encode(ResponsesRequest(model: model, input: wire))
        }
        if kind == .anthropic {
            let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
            var turns = wire.filter { $0.role != "system" }
            // Anthropic conversations start with a user turn. Preserve a saved
            // character's greeting as assistant history rather than system text.
            if turns.first?.role == "assistant" {
                turns.insert(WireMessage(role: "user", content: "Begin with the supplied character opening message."), at: 0)
            }
            return try JSONEncoder().encode(AnthropicRequest(model: model, messages: turns,
                                                             system: system.isEmpty ? nil : system))
        }
        return try JSONEncoder().encode(ChatRequest(model: model, messages: wire, stream: true))
    }

    private struct LocalModels: Decodable { let models: [LocalModel] }
    private struct LocalModel: Decodable { let name: String }
    private struct CloudModels: Decodable {
        let data: [CloudModel]
        let has_more: Bool?
        let last_id: String?
    }
    private struct CloudModel: Decodable {
        let id: String
        let available: Bool?
        let execution_status: String?

        /// Silently assuming "ready" keeps ordinary providers (which omit these
        /// fields) unchanged; only an explicit report hides a model.
        var isReady: Bool {
            guard available != false else { return false }
            guard let execution_status else { return true }
            return execution_status.caseInsensitiveCompare("ready") == .orderedSame
        }
    }
    private struct WireMessage: Encodable { let role: String; let content: String }
    private struct ChatRequest: Encodable { let model: String; let messages: [WireMessage]; let stream: Bool }
    private struct ResponsesRequest: Encodable {
        let model: String
        let input: [WireMessage]
        let stream = true
        let store = false
    }
    private struct AnthropicRequest: Encodable {
        let model: String
        let messages: [WireMessage]
        let system: String?
        let max_tokens = 4096
        let stream = true
    }
}

/// Bytes are framed before UTF-8 decoding so split Unicode and CRLF boundaries
/// cannot corrupt text. EOF is never silently treated as successful generation.
actor ProviderStreamParser {
    private let kind: ProviderKind
    private var local: Bool { kind == .ollama }
    private var anthropicStopped = false
    private let receive: @Sendable (ChatStreamEvent) async throws -> Void
    private var line = Data()
    private var eventData: [String] = []
    private var eventBytes = 0
    private var skipLF = false
    private var finished = false
    private var sawText = false
    private var bytes = 0

    init(local: Bool, receive: @escaping @Sendable (ChatStreamEvent) async throws -> Void) {
        self.kind = local ? .ollama : .openAI
        self.receive = receive
    }

    init(kind: ProviderKind, receive: @escaping @Sendable (ChatStreamEvent) async throws -> Void) {
        self.kind = kind
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
            if kind == .anthropic || kind == .openAIResponses {
                try await processNativeEvent(event)
                return
            }
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

    private func processNativeEvent(_ event: String) async throws {
        let value: NativeEvent
        do { value = try JSONDecoder().decode(NativeEvent.self, from: Data(event.utf8)) }
        catch { throw ProviderError.invalidResponse }
        if value.type == "error" { throw ProviderError.streamFailed }
        if kind == .anthropic {
            switch value.type {
            case "content_block_start":
                guard let block = value.content_block else { throw ProviderError.invalidResponse }
                guard ["text", "thinking", "redacted_thinking"].contains(block.type) else { throw ProviderError.unsupportedModel }
                if block.type == "text", let text = block.text { try await emitText(text) }
            case "content_block_delta":
                guard let delta = value.delta else { throw ProviderError.invalidResponse }
                if delta.type == "text_delta" {
                    guard let text = delta.text else { throw ProviderError.invalidResponse }
                    try await emitText(text)
                } else if !["thinking_delta", "signature_delta", "citations_delta"].contains(delta.type) {
                    throw ProviderError.unsupportedModel
                }
            case "message_delta":
                guard let reason = value.delta?.stop_reason else { throw ProviderError.invalidResponse }
                guard ["end_turn", "max_tokens", "stop_sequence"].contains(reason) else { throw ProviderError.unsupportedModel }
                anthropicStopped = true
            case "message_stop":
                guard anthropicStopped else { throw ProviderError.interrupted }
                try await complete()
            default: break // Lifecycle, usage and ping events are not reply text.
            }
        } else {
            switch value.type {
            case "response.output_text.delta":
                guard let text = value.textDelta else { throw ProviderError.invalidResponse }
                try await emitText(text)
            case "response.output_item.added", "response.output_item.done":
                guard let item = value.item else { throw ProviderError.invalidResponse }
                guard ["message", "reasoning"].contains(item.type) else { throw ProviderError.unsupportedModel }
            case "response.refusal.delta", "response.refusal.done", "response.failed":
                throw ProviderError.streamFailed
            case "response.incomplete": throw ProviderError.interrupted
            case "response.completed":
                guard let response = value.response, response.status == "completed" else { throw ProviderError.invalidResponse }
                guard response.output.allSatisfy({ ["message", "reasoning"].contains($0.type) }) else {
                    throw ProviderError.unsupportedModel
                }
                try await complete()
            default: break // Reasoning/lifecycle metadata is not visible text.
            }
        }
    }

    private func emitText(_ text: String) async throws {
        if !text.isEmpty { sawText = true; try await receive(.text(text)) }
    }

    private struct NativeEvent: Decodable {
        struct Block: Decodable { let type: String; let text: String? }
        struct Delta: Decodable { let type: String?; let text: String?; let stop_reason: String? }
        struct Response: Decodable { let status: String; let output: [Block] }
        let type: String
        let content_block: Block?
        let item: Block?
        let response: Response?
        let delta: Delta?
        let textDelta: String?

        enum CodingKeys: String, CodingKey { case type, content_block, item, response, delta }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            content_block = try container.decodeIfPresent(Block.self, forKey: .content_block)
            item = try container.decodeIfPresent(Block.self, forKey: .item)
            response = try container.decodeIfPresent(Response.self, forKey: .response)
            if type == "response.output_text.delta" {
                textDelta = try container.decode(String.self, forKey: .delta)
                delta = nil
            } else {
                textDelta = nil
                delta = type.hasPrefix("response.") ? nil : try container.decodeIfPresent(Delta.self, forKey: .delta)
            }
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
