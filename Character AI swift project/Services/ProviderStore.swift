import Combine
import Foundation

nonisolated struct ProviderSelection: Codable, Equatable, Sendable {
    let kind: ProviderKind
    var configurationID: UUID?
    var model: String = ""
}

@MainActor
final class ProviderStore: ObservableObject {
    static let shared = ProviderStore()
    @Published private(set) var configurations: [ProviderConfiguration] = []
    @Published private(set) var errorMessage: String?
    @Published var rememberLastProvider: Bool {
        didSet {
            defaults.set(rememberLastProvider, forKey: "providers.remember")
            if !rememberLastProvider { defaults.removeObject(forKey: "providers.lastSelection") }
        }
    }
    @Published private(set) var localEndpoint: String
    @Published private(set) var localModel: String
    private let defaults: UserDefaults
    private let credentials: any SessionStorage
    private var configurationReadable = true

    init(defaults: UserDefaults = .standard, credentials: (any SessionStorage)? = nil) {
        self.defaults = defaults
        self.credentials = credentials ?? KeychainStore()
        rememberLastProvider = defaults.bool(forKey: "providers.remember")
        localEndpoint = defaults.string(forKey: "providers.ollamaEndpoint") ?? ProviderEndpoint.defaultOllama
        localModel = defaults.string(forKey: "providers.ollamaModel") ?? ""
        if let data = defaults.data(forKey: "providers.cloudConfigurations") {
            do {
                let decoded = try JSONDecoder().decode([ProviderConfiguration].self, from: data)
                guard Set(decoded.map(\.id)).count == decoded.count else { throw ProviderError.configurationStorage }
                configurations = try decoded.map { try $0.validated() }
            } catch {
                configurationReadable = false
                errorMessage = ProviderError.configurationStorage.localizedDescription
            }
        }
    }

    func saveLocal(endpoint: String, model: String) throws {
        _ = try ProviderEndpoint.local(endpoint)
        localEndpoint = endpoint
        localModel = model
        defaults.set(endpoint, forKey: "providers.ollamaEndpoint")
        defaults.set(model, forKey: "providers.ollamaModel")
    }

    func save(_ value: ProviderConfiguration, newKey: String?) throws {
        guard configurationReadable else { throw ProviderError.configurationStorage }
        let value = try value.validated()
        if let old = configurations.first(where: { $0.id == value.id }),
           old.endpoint != value.endpoint || old.kind != value.kind {
            // Never silently send an existing key to an edited destination.
            guard let newKey, !newKey.isEmpty else { throw ProviderError.missingCredential }
        }
        if let newKey, !newKey.isEmpty {
            guard !newKey.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw ProviderError.missingCredential }
            do { try credentials.save(Data(newKey.utf8), forKey: keyID(value.id)) }
            catch { throw ProviderError.credentialStorage }
        } else {
            _ = try key(for: value.id)
        }
        var updated = configurations.filter { $0.id != value.id }
        updated.append(value)
        let data = try JSONEncoder().encode(updated)
        defaults.set(data, forKey: "providers.cloudConfigurations")
        configurations = updated
        errorMessage = nil
    }

    func key(for id: UUID) throws -> String {
        do {
            guard let data = try credentials.loadData(forKey: keyID(id)),
                  let key = String(data: data, encoding: .utf8), !key.isEmpty else { throw ProviderError.missingCredential }
            return key
        } catch let error as ProviderError { throw error }
        catch { throw ProviderError.credentialStorage }
    }

    func remove(_ id: UUID) throws {
        guard configurationReadable else { throw ProviderError.configurationStorage }
        do { try credentials.delete(forKey: keyID(id)) }
        catch { throw ProviderError.credentialStorage }
        let updated = configurations.filter { $0.id != id }
        defaults.set(try JSONEncoder().encode(updated), forKey: "providers.cloudConfigurations")
        configurations = updated
        if lastSelection?.configurationID == id { defaults.removeObject(forKey: "providers.lastSelection") }
    }

    func provider(for selection: ProviderSelection) throws -> any ChatProvider {
        switch selection.kind {
        case .ollama: return try TextChatProvider(localEndpoint: localEndpoint)
        case .openAI, .openAICompatible:
            guard let configuration = configurations.first(where: { $0.id == selection.configurationID }) else {
                throw ProviderError.invalidConfiguration
            }
            return try TextChatProvider(configuration: configuration, apiKey: key(for: configuration.id))
        case .characterAI: throw ProviderError.invalidConfiguration
        }
    }

    var lastSelection: ProviderSelection? {
        guard rememberLastProvider, let data = defaults.data(forKey: "providers.lastSelection") else { return nil }
        return try? JSONDecoder().decode(ProviderSelection.self, from: data)
    }

    func remember(_ selection: ProviderSelection) {
        guard rememberLastProvider, let data = try? JSONEncoder().encode(selection) else { return }
        defaults.set(data, forKey: "providers.lastSelection")
    }

    private func keyID(_ id: UUID) -> String { "cloud-provider.\(id.uuidString)" }
}
