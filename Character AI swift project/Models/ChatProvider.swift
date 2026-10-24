import Foundation

nonisolated enum ProviderKind: String, Codable, CaseIterable, Sendable {
    case characterAI, ollama, openAI, openAICompatible, openAIResponses, anthropic

    var title: String {
        switch self {
        case .characterAI: "Character.AI"
        case .ollama: "Local Models"
        case .openAI: "OpenAI · Chat Completions"
        case .openAIResponses: "OpenAI · Responses"
        case .anthropic: "Claude · Anthropic Messages"
        case .openAICompatible: "OpenAI-compatible"
        }
    }

    /// A label short enough for a sidebar row, used where a chat has no saved
    /// provider name: it is what tells a local chat from a cloud one.
    var shortTitle: String {
        switch self {
        case .characterAI: "Character.AI"
        case .ollama: "Ollama"
        default: "Cloud chat"
        }
    }
}

nonisolated struct ProviderCapabilities: OptionSet, Sendable {
    let rawValue: Int
    static let textChat = Self(rawValue: 1 << 0)
    static let streaming = Self(rawValue: 1 << 1)
    static let modelDiscovery = Self(rawValue: 1 << 2)
    static let characters = Self(rawValue: 1 << 3)
    static let accountHistory = Self(rawValue: 1 << 4)
}

nonisolated struct ProviderDescriptor: Identifiable, Sendable {
    let id: String
    let name: String
    let kind: ProviderKind
    let capabilities: ProviderCapabilities

    static let characterAI = Self(id: "character-ai", name: "Character.AI", kind: .characterAI,
                                 capabilities: [.characters, .accountHistory, .streaming])
}

nonisolated struct ProviderConfiguration: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var kind: ProviderKind
    var endpoint: String
    var model: String = ""

    func validated() throws -> Self {
        guard [.openAI, .openAICompatible, .openAIResponses, .anthropic].contains(kind),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 80, model.count <= 200,
              !model.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw ProviderError.invalidConfiguration }
        _ = try ProviderEndpoint.cloud(endpoint, kind: kind)
        return self
    }
}

/// Free or free-tier endpoints worth testing. They all use the
/// OpenAI-compatible Chat Completions API because that is the only kind that
/// accepts a custom base URL. Free quotas and privacy terms change, so the
/// note is shown next to the endpoint rather than treated as a promise.
nonisolated struct ProviderPreset: Identifiable, Sendable {
    let id: String
    let name: String
    let endpoint: String
    let note: String

    var configuration: ProviderConfiguration {
        ProviderConfiguration(name: name, kind: .openAICompatible, endpoint: endpoint)
    }

    static let freeCloud: [ProviderPreset] = [
        ProviderPreset(id: "freellmapi", name: "FreeLLMAPI · local router",
                       endpoint: "http://127.0.0.1:31415/v1",
                       note: "The FreeLLMAPI desktop app listens on port 31415; a Docker or self-hosted install uses 3001, so edit the port to match. Paste the freellmapi-… unified key from its dashboard. It only ever receives traffic from this Mac."),
        ProviderPreset(id: "gemini", name: "Gemini · free tier",
                       endpoint: "https://generativelanguage.googleapis.com/v1beta/openai/",
                       note: "Free tokens on selected Flash models. Unpaid prompts may be reviewed or used to improve Google’s models."),
        ProviderPreset(id: "groq", name: "Groq · free tier",
                       endpoint: "https://api.groq.com/openai/v1",
                       note: "Fast free tier. Limits vary by account; check the Limits page in the Groq console."),
        ProviderPreset(id: "openrouter", name: "OpenRouter · free models",
                       endpoint: "https://openrouter.ai/api/v1",
                       note: "Pick a model whose ID ends in :free. Around 50 free requests a day until you buy credit."),
        ProviderPreset(id: "cloudflare", name: "Cloudflare Workers AI",
                       endpoint: "https://api.cloudflare.com/client/v4/accounts/YOUR_ACCOUNT_ID/ai/v1",
                       note: "Replace YOUR_ACCOUNT_ID with the ID from the Cloudflare dashboard. 10,000 Neurons a day.")
    ]
}

nonisolated struct ModelDescriptor: Identifiable, Equatable, Sendable {
    let id: String
    /// Routers such as FreeLLMAPI report whether a model can serve a request
    /// right now. Providers that say nothing stay selectable.
    var isAvailable: Bool = true
    var name: String { id }
}

nonisolated enum ChatRole: String, Codable, Sendable {
    case system, user, assistant
}

nonisolated struct ProviderChatMessage: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    let role: ChatRole
    var content: String
}

nonisolated enum ChatStreamEvent: Sendable, Equatable {
    case text(String)
    case finished
}

/// Character.AI retains its character/turn/WebSocket services. Only providers
/// offering ordinary text chat conform here; their capabilities are not universal.
nonisolated protocol ChatProvider: Sendable {
    var descriptor: ProviderDescriptor { get }
    func models() async throws -> [ModelDescriptor]
    func stream(model: String, messages: [ProviderChatMessage],
                receive: @escaping @Sendable (ChatStreamEvent) async throws -> Void) async throws
}

nonisolated enum ProviderEndpoint {
    static let defaultOllama = "http://127.0.0.1:11434"
    static let defaultOpenAI = "https://api.openai.com/v1"
    static let defaultAnthropic = "https://api.anthropic.com/v1"

    static func local(_ text: String) throws -> URL {
        let url = try base(text)
        let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) ?? ""
        guard ["http", "https"].contains(url.scheme),
              ["localhost", "127.0.0.1", "::1"].contains(host),
              url.path.isEmpty || url.path == "/" else { throw ProviderError.invalidLocalEndpoint }
        return url
    }

    static func cloud(_ text: String, kind: ProviderKind) throws -> URL {
        let url = try base(text)
        // A self-hosted OpenAI-compatible router on this Mac is a legitimate
        // cloud configuration, and its key never leaves the loopback interface.
        // Every other kind keeps its fixed official HTTPS endpoint below.
        if kind == .openAICompatible, isLoopbackHost(url) { return url }
        guard url.scheme == "https", let host = url.host?.lowercased(),
              !host.hasSuffix("."), host.contains("."), !host.hasSuffix(".local"), !host.hasSuffix(".localhost"),
              !host.hasSuffix(".internal"), !host.contains(":"),
              host.contains(where: \.isLetter) else { throw ProviderError.invalidCloudEndpoint }
        if [.openAI, .openAIResponses, .anthropic].contains(kind) {
            let expected = kind == .anthropic ? defaultAnthropic : defaultOpenAI
            guard url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == expected else {
                throw ProviderError.invalidCloudEndpoint
            }
        } else if kind != .openAICompatible { throw ProviderError.invalidConfiguration }
        return url
    }

    /// Matches `local(_:)`: only the addresses that reach this Mac itself.
    private static func isLoopbackHost(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme) else { return false }
        let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) ?? ""
        return ["localhost", "127.0.0.1", "::1"].contains(host)
    }

    private static func base(_ text: String) throws -> URL {
        guard text == text.trimmingCharacters(in: .whitespacesAndNewlines),
              let components = URLComponents(string: text), let url = components.url,
              url.host != nil, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              !text.contains(where: { $0.isWhitespace || $0.isNewline }),
              url.port.map({ 1...65535 ~= $0 }) ?? true else { throw ProviderError.invalidEndpoint }
        return url
    }
}

nonisolated enum ProviderError: LocalizedError, Equatable {
    case invalidEndpoint, invalidLocalEndpoint, invalidCloudEndpoint, invalidConfiguration
    case missingCredential, credentialStorage, configurationStorage
    case unavailable, authentication, forbidden, rateLimited, missingModel, unsupportedModel
    case rejected(Int), invalidResponse, interrupted, streamFailed, responseTooLarge, emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Enter a URL without a username, password, query or fragment."
        case .invalidLocalEndpoint: "Use an HTTP or HTTPS Ollama address on this Mac (localhost, 127.0.0.1 or ::1), without a path."
        case .invalidCloudEndpoint: "Use a public HTTPS API base URL, or a loopback address such as http://127.0.0.1:3001/v1 for a local OpenAI-compatible router. Native OpenAI and Claude configurations use their fixed official endpoints."
        case .invalidConfiguration: "Enter a provider name and a valid model identifier."
        case .missingCredential: "Add an API key in Providers settings before connecting."
        case .credentialStorage: "The API key could not be read or saved in Keychain. Try again."
        case .configurationStorage: "Saved provider settings could not be read. They have not been overwritten."
        case .unavailable: "Cannot connect to this provider. Check the endpoint and connection; for local models, make sure Ollama is running."
        case .authentication: "The provider rejected the API key. Update it in Providers settings."
        case .forbidden: "This account is not allowed to use that resource or model."
        case .rateLimited: "The provider reports a usage or rate limit. Check your account before retrying."
        case .missingModel: "The selected model is unavailable. Refresh the model list or choose another model."
        case .unsupportedModel: "This model requested tools or another response format that Veyrin’s text adapter does not support. Choose a text chat model."
        case .rejected(let status): "The provider rejected the request (HTTP \(status)). Check its model and API compatibility."
        case .invalidResponse: "The provider returned an unsupported response. Check the API type and endpoint."
        case .interrupted: "The response ended before completion. Partial text is kept; retry when ready."
        case .streamFailed: "The provider reported a generation error. Partial text is kept; check the model and try again."
        case .responseTooLarge: "This response exceeds Veyrin’s text limit. Start a new conversation or ask for a shorter reply."
        case .emptyResponse: "The provider returned no text. Choose a text chat model or try another message."
        }
    }
}
