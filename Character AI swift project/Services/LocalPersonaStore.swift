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
    private var storageIsAvailable = true

    init(supportDirectory: URL? = nil) {
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
    func importPersonas(from url: URL) throws -> [Persona] {
        guard storageIsAvailable else { throw LocalPersonaStoreError.storageUnavailable }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let parsed = try PersonaTransfer.parseAll(data: data, filename: url.lastPathComponent)
        var merged = Dictionary(personas.map { ($0.externalID, $0) }, uniquingKeysWith: { _, last in last })
        for persona in parsed { merged[persona.externalID] = persona }
        let next = merged.values.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        try write(next)
        personas = next
        errorMessage = nil
        return parsed
    }

    func delete(_ persona: Persona) throws {
        guard storageIsAvailable else { throw LocalPersonaStoreError.storageUnavailable }
        let next = personas.filter { $0.externalID != persona.externalID }
        try write(next)
        personas = next
        errorMessage = nil
    }

    func export(_ persona: Persona, to url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        switch url.pathExtension.lowercased() {
        case "md", "markdown", "txt":
            try Data(persona.portableMarkdown.utf8).write(to: url, options: .atomic)
        default:
            try persona.portableJSON().write(to: url, options: .atomic)
        }
    }

    func exportAll(to url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        if url.pathExtension.lowercased() == "md" || url.pathExtension.lowercased() == "markdown" {
            let text = personas.map(\.portableMarkdown).joined(separator: "\n\n---\n\n")
            try Data(text.utf8).write(to: url, options: .atomic)
        } else {
            try LocalPersonaArchive.encode(personas).write(to: url, options: .atomic)
        }
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

    private func write(_ values: [Persona]) throws {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(values).write(to: catalogueURL, options: .atomic)
        } catch {
            throw LocalPersonaStoreError.storageUnavailable
        }
    }
}

nonisolated enum LocalPersonaStoreError: LocalizedError, Equatable {
    case storageUnavailable

    var errorDescription: String? {
        "Imported personas could not be read or saved. The existing persona file has not been overwritten."
    }
}
