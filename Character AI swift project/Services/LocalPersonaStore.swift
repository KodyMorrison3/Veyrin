import Combine
import Foundation

/// Personas imported for use with local and cloud providers. Character.AI
/// personas remain account-scoped; this catalogue is user-owned, works offline,
/// and can be exported from the Personas settings pane.
@MainActor
final class LocalPersonaStore: ObservableObject {
    static let shared = LocalPersonaStore()

    @Published private(set) var personas: [Persona] = []
    @Published var errorMessage: String?

    private let folder: URL
    private let catalogueURL: URL
    private let imageCache: ImageCacheService
    private var storageIsAvailable = true

    init(supportDirectory: URL? = nil, imageCache: ImageCacheService = .shared) {
        self.imageCache = imageCache
        let support = supportDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Veyrin", isDirectory: true)
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Veyrin", isDirectory: true)
        folder = support
        catalogueURL = support.appendingPathComponent("local-personas.json")
        load()
    }

    @discardableResult
    func importPersonas(from url: URL) async throws -> [Persona] {
        guard storageIsAvailable else { throw LocalPersonaStoreError.storageUnavailable }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        // Image decoding happens off the main actor; a whole library can be slow.
        let parsed = try await PersonaTransfer.parseAll(data: data, filename: url.lastPathComponent)
        var merged = Dictionary(personas.map { ($0.externalID, $0) }, uniquingKeysWith: { _, last in last })
        for persona in parsed {
            var updated = persona
            // Re-importing an updated prompt without a picture must not wipe
            // the picture already stored for that persona.
            if updated.avatarData == nil, updated.avatarFileName == nil,
               let existing = merged[persona.externalID] {
                updated.avatarData = existing.avatarData
                updated.avatarFileName = existing.avatarFileName
            }
            merged[persona.externalID] = updated
        }
        let next = merged.values.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        try await write(next)
        personas = next
        errorMessage = nil
        return parsed
    }

    func delete(_ persona: Persona) async throws {
        guard storageIsAvailable else { throw LocalPersonaStoreError.storageUnavailable }
        let next = personas.filter { $0.externalID != persona.externalID }
        try await write(next)
        personas = next
        errorMessage = nil
    }

    func export(_ persona: Persona, to url: URL) async throws {
        let persona = try await portableCopy(of: persona)
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        switch url.pathExtension.lowercased() {
        case "md", "markdown", "txt":
            try Data(persona.portableMarkdown.utf8).write(to: url, options: .atomic)
        default:
            try persona.portableJSON().write(to: url, options: .atomic)
        }
    }

    func exportAll(to url: URL) async throws {
        let snapshot = personas
        var copies = snapshot
        // Account pictures are separate downloads; fetch them together rather
        // than waiting for one persona after another.
        try await withThrowingTaskGroup(of: (Int, Persona).self) { group in
            for (index, persona) in snapshot.enumerated() {
                group.addTask { (index, try await self.portableCopy(of: persona)) }
            }
            for try await (index, persona) in group { copies[index] = persona }
        }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        if url.pathExtension.lowercased() == "md" || url.pathExtension.lowercased() == "markdown" {
            let text = copies.map(\.portableMarkdown).joined(separator: "\n\n---\n\n")
            try Data(text.utf8).write(to: url, options: .atomic)
        } else {
            try LocalPersonaArchive.encode(copies).write(to: url, options: .atomic)
        }
    }

    private func portableCopy(of persona: Persona) async throws -> Persona {
        try Task.checkCancellation()
        guard persona.avatarData == nil, persona.avatarFileName?.isEmpty == false else { return persona }
        guard let url = persona.avatarURL,
              let image = await imageCache.fetchImage(for: url) else {
            throw PersonaTransferError.avatarUnavailable
        }
        try Task.checkCancellation()
        var copy = persona
        copy.avatarData = try PersonaTransfer.avatarPNG(from: image)
        return copy
    }

    private func load() {
        do {
            let data: Data
            do {
                data = try Data(contentsOf: catalogueURL)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return
            }
            personas = try JSONDecoder().decode([Persona].self, from: data)
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        } catch {
            storageIsAvailable = false
            errorMessage = LocalPersonaStoreError.storageUnavailable.localizedDescription
        }
    }

    private func write(_ values: [Persona]) async throws {
        do {
            // Embedded pictures make this a multi-megabyte encode; keep it off
            // the UI thread, where persona deletion and import would hitch.
            try await Self.persist(values, to: catalogueURL)
        } catch {
            throw LocalPersonaStoreError.storageUnavailable
        }
    }

    @concurrent private static func persist(_ values: [Persona], to url: URL) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(values)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// Only references are remembered: account persona contents remain in their
/// account-owned store, and deleted/unavailable personas never fall back to
/// another identity. Local and cloud character chats share this mapping.
nonisolated struct RoleplayPersonaReference: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable { case local, account }
    let source: Source
    let personaID: String
    var accountID: String?

    @MainActor func resolve(local: LocalPersonaStore, account: PersonaStore?) -> Persona? {
        switch source {
        case .local:
            return local.personas.first { $0.externalID == personaID }
        case .account:
            guard let accountID, account?.ownerID == accountID else { return nil }
            return account?.personas.first { $0.externalID == personaID }
        }
    }
}

@MainActor
final class RoleplayPersonaSelections: ObservableObject {
    static let shared = RoleplayPersonaSelections()
    private static let key = "providers.characterPersonas"
    @Published private(set) var selections: [String: RoleplayPersonaReference] = [:]
    private(set) var isReadable = true
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key) {
            do {
                let values = try JSONDecoder().decode([String: RoleplayPersonaReference].self, from: data)
                guard values.allSatisfy({ !$0.key.isEmpty && !$0.value.personaID.isEmpty
                    && ($0.value.source == .local || $0.value.accountID?.isEmpty == false) }) else {
                    throw LocalPersonaStoreError.selectionStorageUnavailable
                }
                selections = values
            } catch { isReadable = false }
        }
    }

    func select(_ reference: RoleplayPersonaReference?, for characterID: String) throws {
        guard isReadable, !characterID.isEmpty else { throw LocalPersonaStoreError.selectionStorageUnavailable }
        var next = selections
        next[characterID] = reference
        let data = try JSONEncoder().encode(next)
        defaults.set(data, forKey: Self.key)
        selections = next
    }
}

/// A chat's current selection is resolved on every request, so deletion,
/// re-import and account changes cannot leave stale persona text attached.
@MainActor
final class RoleplayPersonaContext: ObservableObject {
    let local: LocalPersonaStore
    let account: PersonaStore
    let saved: RoleplayPersonaSelections
    @Published private(set) var characterID: String?
    @Published private var transient: RoleplayPersonaReference?
    @Published private(set) var errorMessage: String?

    init(characterID: String? = nil, local: LocalPersonaStore = .shared,
         account: PersonaStore, saved: RoleplayPersonaSelections = .shared) {
        self.characterID = characterID
        self.local = local
        self.account = account
        self.saved = saved
    }

    var reference: RoleplayPersonaReference? {
        if let characterID { return saved.selections[characterID] }
        return transient
    }
    var persona: Persona? { reference?.resolve(local: local, account: account) }
    var unavailable: Bool { reference != nil && persona == nil }

    func setCharacter(_ id: String?) { characterID = id }

    func select(_ reference: RoleplayPersonaReference?) {
        do {
            if let characterID { try saved.select(reference, for: characterID) }
            else { transient = reference }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
}

nonisolated enum LocalPersonaStoreError: LocalizedError, Equatable {
    case storageUnavailable
    case selectionStorageUnavailable

    var errorDescription: String? {
        switch self {
        case .storageUnavailable:
            "Imported personas could not be read or saved. The existing persona file has not been overwritten."
        case .selectionStorageUnavailable:
            "Saved character persona selections could not be read or saved. Existing preferences have not been overwritten."
        }
    }
}
