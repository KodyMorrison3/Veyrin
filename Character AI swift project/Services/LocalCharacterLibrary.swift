import Combine
import Foundation

struct LocalCharacter: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let tagline: String
    let description: String
    let definition: String
    let greeting: String
    let examples: [String]
    let tags: [String]
    let sourcePlatform: String
    let sourceName: String
    let sourceURL: String
    let creatorName: String
    let licence: String
    let importedAt: String
    let origin: String
    let avatarFileName: String?
    let visibility: String?
    let interactionCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, tagline, description, definition, greeting, examples, tags, origin
        case sourcePlatform = "sourcePlatform"
        case sourceName = "sourceName"
        case sourceURL = "sourceURL"
        case creatorName = "creatorName"
        case licence, importedAt, avatarFileName, visibility, interactionCount
    }

    var isGenerated: Bool { sourcePlatform == "synthetic" }

    init(discoverCharacter: DiscoverFeedCharacter, existing: LocalCharacter? = nil) throws {
        guard let id = discoverCharacter.externalID, !id.isEmpty,
              let name = [discoverCharacter.name, discoverCharacter.participantName, discoverCharacter.title]
                .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { !$0.isEmpty }) else {
            throw LocalCharacterLibraryError.invalidCharacter
        }
        self.id = id
        self.name = name
        tagline = discoverCharacter.title.flatMap { $0.isEmpty ? nil : $0 } ?? existing?.tagline ?? ""
        description = discoverCharacter.description.flatMap { $0.isEmpty ? nil : $0 } ?? existing?.description ?? ""
        definition = existing?.definition ?? ""
        greeting = discoverCharacter.greeting.flatMap { $0.isEmpty ? nil : $0 } ?? existing?.greeting ?? ""
        examples = existing?.examples ?? []
        tags = existing?.tags ?? []
        sourcePlatform = existing?.sourcePlatform ?? "character.ai"
        sourceName = existing?.sourceName ?? "Character.AI Discover"
        sourceURL = existing?.sourceURL ?? ""
        creatorName = discoverCharacter.username ?? existing?.creatorName ?? ""
        licence = existing?.licence ?? "Not stated"
        importedAt = existing?.importedAt ?? ISO8601DateFormatter().string(from: Date())
        origin = existing?.origin ?? "Saved from Discover"
        avatarFileName = discoverCharacter.avatarFileName?.isEmpty == false
            ? discoverCharacter.avatarFileName : existing?.avatarFileName
        visibility = discoverCharacter.visibility ?? existing?.visibility
        interactionCount = discoverCharacter.interactionCount ?? existing?.interactionCount
    }

    static func accountExportID(in record: [String: Any]) -> String {
        for key in ["external_id", "externalId", "character_id", "characterId", "id", "uuid"] {
            if let value = record[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
            if let value = record[key] as? NSNumber {
                return value.stringValue
            }
        }
        return ""
    }

    init(accountExportRecord record: [String: Any], existing: LocalCharacter? = nil) throws {
        let id = Self.accountExportID(in: record)
        let name = ["name", "title", "character_name", "characterName"]
            .compactMap { record[$0] as? String }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !id.isEmpty, let name else { throw CharacterAIAccountExportError.invalidExport }

        self.id = id
        self.name = name
        tagline = Self.string(record, keys: ["tagline", "short_description", "shortDescription"]) ?? existing?.tagline ?? ""
        description = Self.string(record, keys: ["description", "long_description", "longDescription"]) ?? existing?.description ?? ""
        definition = Self.string(record, keys: ["definition", "definition_text", "definitionText"]) ?? existing?.definition ?? ""
        greeting = Self.string(record, keys: ["greeting", "greeting_text", "greetingText"]) ?? existing?.greeting ?? ""
        examples = Self.strings(record, keys: ["examples", "example_dialogue", "exampleDialogue"]) ?? existing?.examples ?? []
        tags = Self.strings(record, keys: ["tags", "categories"]) ?? existing?.tags ?? []
        sourcePlatform = "character.ai"
        sourceName = "Character.AI account export"
        sourceURL = Self.string(record, keys: ["source_url", "profile_url", "url"]) ?? existing?.sourceURL ?? ""
        creatorName = Self.string(record, keys: ["creator_name", "creatorName", "username", "user__username"]) ?? existing?.creatorName ?? ""
        licence = "Account export; rights not specified"
        importedAt = ISO8601DateFormatter().string(from: Date())
        origin = "Imported from account export"
        avatarFileName = Self.string(record, keys: ["avatar_file_name", "avatarFileName", "avatar_reference"]) ?? existing?.avatarFileName
        visibility = Self.string(record, keys: ["visibility"]) ?? existing?.visibility
        interactionCount = Self.integer(record, keys: ["participant__num_interactions", "interaction_count", "interactionCount"]) ?? existing?.interactionCount
    }

    private static func string(_ record: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = record[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func strings(_ record: [String: Any], keys: [String]) -> [String]? {
        for key in keys {
            if let values = record[key] as? [String] { return values }
            if let value = record[key] as? String { return [value] }
        }
        return nil
    }

    private static func integer(_ record: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = record[key] as? Int { return value }
            if let value = record[key] as? String, let number = Int(value) { return number }
        }
        return nil
    }

    init(searchResult: CharacterSearchResult, existing: LocalCharacter? = nil) throws {
        try self.init(discoverCharacter: DiscoverFeedCharacter(
            externalID: searchResult.externalID,
            name: searchResult.name,
            participantName: nil,
            interactionCount: searchResult.interactionCount,
            title: searchResult.title,
            description: searchResult.description,
            greeting: nil,
            visibility: nil,
            avatarFileName: searchResult.avatarFileName,
            username: searchResult.creatorUsername,
            shortHash: nil
        ), existing: existing)
    }

    init(record: [String: Any]) throws {
        guard let id = record["archive_id"] as? String, UUID(uuidString: id) != nil,
              let name = record["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalCharacterLibraryError.invalidCharacter
        }
        let source = record["source"] as? [String: Any] ?? [:]
        let metadata = record["source_metadata"] as? [String: Any] ?? [:]
        self.id = id
        self.name = name
        tagline = record["tagline"] as? String ?? ""
        description = record["description"] as? String ?? ""
        definition = record["definition"] as? String ?? ""
        greeting = record["greeting"] as? String ?? ""
        examples = record["examples"] as? [String] ?? []
        tags = record["tags"] as? [String] ?? []
        sourcePlatform = source["source_platform"] as? String ?? "unknown"
        sourceName = source["source_name"] as? String ?? "Unknown source"
        sourceURL = source["source_url"] as? String ?? ""
        creatorName = record["creator_name"] as? String ?? ""
        licence = source["licence"] as? String ?? "Not stated"
        importedAt = record["imported_at"] as? String ?? ""
        origin = metadata["generation_version"] == nil ? "Imported" : "Generated"
        avatarFileName = record["avatar_reference"] as? String
        visibility = record["visibility"] as? String
        interactionCount = metadata["interaction_count"] as? Int
    }

    var searchableText: String {
        ([name, tagline, description, sourceName, sourcePlatform] + tags)
            .joined(separator: " ")
    }

    var characterPrompt: String {
        [
            "You are roleplaying as \(name). Stay in character and respond naturally to the user's latest message.",
            "Character description: \(description)",
            "Character definition: \(definition)",
            "Tags: \(tags.joined(separator: ", "))",
            "Use the example dialogue as guidance, not text to repeat:\n\(examples.joined(separator: "\n\n"))",
            "Keep continuity with the conversation. Do not claim knowledge that the character would not have."
        ].joined(separator: "\n\n")
    }
}

struct LocalChatMessage: Codable, Identifiable, Sendable {
    let id: UUID
    let role: String
    let content: String
    let createdAt: Date

    init(role: String, content: String) {
        id = UUID()
        self.role = role
        self.content = content
        createdAt = Date()
    }
}

struct LocalCharacterConversation: Codable, Identifiable, Sendable {
    let id: UUID
    let characterID: String
    var messages: [LocalChatMessage]
    var updatedAt: Date

    init(character: LocalCharacter) {
        id = UUID()
        characterID = character.id
        messages = character.greeting.isEmpty ? [] : [LocalChatMessage(role: "assistant", content: character.greeting)]
        updatedAt = Date()
    }
}

enum LocalCharacterLibraryError: LocalizedError {
    case invalidArchive
    case invalidCharacter
    case profileUnavailable
    case catalogueUnavailable
    case conversationNotFound
    case conversationUnavailable
    case responseWasEmpty

    var errorDescription: String? {
        switch self {
        case .invalidArchive: "This file is not a supported Veyrin character archive."
        case .invalidCharacter: "A character is missing a stable archive ID or name."
        case .profileUnavailable: "Your Character.AI profile has not loaded yet."
        case .catalogueUnavailable: "Your saved character library could not be read. Its file has been left unchanged. Check the file in Application Support and try again."
        case .conversationNotFound: "This local conversation could not be found."
        case .conversationUnavailable: "This local conversation could not be read. Its saved file has been left unchanged. Restore or remove its file in Application Support to continue."
        case .responseWasEmpty: "Ollama returned an empty reply."
        }
    }
}

@MainActor
final class LocalCharacterLibrary: ObservableObject {
    static let shared = LocalCharacterLibrary()

    @Published private(set) var characters: [LocalCharacter] = []
    @Published private(set) var conversations: [String: LocalCharacterConversation] = [:]
    @Published var errorMessage: String?

    private let folder: URL
    private let catalogueURL: URL
    private let conversationsURL: URL
    private var catalogueIsAvailable = true

    init(supportDirectory: URL? = nil) {
        let support = supportDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Veyrin", isDirectory: true)
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Veyrin", isDirectory: true)
        folder = support
        catalogueURL = support.appendingPathComponent("characters.json")
        conversationsURL = support.appendingPathComponent("conversations", isDirectory: true)
        load()
    }

    func matching(_ query: String, source: String, tag: String) -> [LocalCharacter] {
        characters.filter { character in
            (query.isEmpty || character.searchableText.localizedCaseInsensitiveContains(query)) &&
            (source == "All sources" || character.sourcePlatform.localizedCaseInsensitiveCompare(source) == .orderedSame) &&
            (tag == "All tags" || character.tags.contains { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame })
        }
    }

    var sources: [String] { ["All sources"] + Set(characters.map(\.sourcePlatform)).sorted() }
    var tags: [String] { ["All tags"] + Set(characters.flatMap(\.tags)).sorted() }

    func containsCharacter(_ id: String?) -> Bool {
        guard let id else { return false }
        return characters.contains { $0.id == id }
    }

    func saveFromDiscover(_ discoverCharacter: DiscoverFeedCharacter) throws {
        let existing = characters.first { $0.id == discoverCharacter.externalID }
        let character = try LocalCharacter(discoverCharacter: discoverCharacter, existing: existing)
        try save(character)
    }

    func saveFromDiscover(_ searchResult: CharacterSearchResult) throws {
        let existing = characters.first { $0.id == searchResult.externalID }
        let character = try LocalCharacter(searchResult: searchResult, existing: existing)
        try save(character)
    }

    @discardableResult
    func saveFromDiscover(_ discoverCharacters: [DiscoverFeedCharacter]) throws -> Int {
        guard catalogueIsAvailable else { throw LocalCharacterLibraryError.catalogueUnavailable }
        var merged = Dictionary(uniqueKeysWithValues: characters.map { ($0.id, $0) })
        for discoverCharacter in discoverCharacters {
            let existing = characters.first { $0.id == discoverCharacter.externalID }
            let character = try LocalCharacter(discoverCharacter: discoverCharacter, existing: existing)
            merged[character.id] = character
        }
        let previous = characters
        characters = merged.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        do { try saveCatalogue() }
        catch { characters = previous; throw error }
        errorMessage = nil
        return discoverCharacters.count
    }

    private func save(_ character: LocalCharacter) throws {
        guard catalogueIsAvailable else { throw LocalCharacterLibraryError.catalogueUnavailable }
        let previous = characters
        if let index = characters.firstIndex(where: { $0.id == character.id }) {
            characters[index] = character
        } else {
            characters.append(character)
        }
        characters.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        do { try saveCatalogue() }
        catch { characters = previous; throw error }
        errorMessage = nil
    }

    func importCharacterAIAccountExport(from url: URL) throws -> CharacterAIAccountExportImportResult {
        guard catalogueIsAvailable else { throw LocalCharacterLibraryError.catalogueUnavailable }
        let existing = Dictionary(uniqueKeysWithValues: characters.map { ($0.id, $0) })
        let parsed = try CharacterAIAccountExportImporter.readCharacters(from: url, existing: existing)
        var merged = existing
        for character in parsed.characters { merged[character.id] = character }
        let previous = characters
        characters = merged.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        do { try saveCatalogue() }
        catch { characters = previous; throw error }
        errorMessage = nil
        return parsed.result
    }

    @discardableResult
    func importArchive(from url: URL) throws -> Int {
        guard catalogueIsAvailable else { throw LocalCharacterLibraryError.catalogueUnavailable }
        let data = try Data(contentsOf: url)
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              envelope["format"] as? String == "veyrin.local-character-library",
              let rows = envelope["characters"] as? [[String: Any]] else {
            throw LocalCharacterLibraryError.invalidArchive
        }
        var merged = Dictionary(uniqueKeysWithValues: characters.map { ($0.id, $0) })
        for row in rows {
            let character: LocalCharacter
            if row["archive_id"] != nil {
                character = try LocalCharacter(record: row)
            } else {
                let data = try JSONSerialization.data(withJSONObject: row)
                character = try JSONDecoder().decode(LocalCharacter.self, from: data)
            }
            merged[character.id] = character
        }
        let previous = characters
        characters = merged.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        do { try saveCatalogue() }
        catch { characters = previous; throw error }
        errorMessage = nil
        return rows.count
    }

    func exportArchive(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let envelope: [String: Any] = [
            "format": "veyrin.local-character-library",
            "version": 1,
            "characters": characters.map { character in
                [
                    "id": character.id, "name": character.name, "tagline": character.tagline,
                    "description": character.description, "definition": character.definition,
                    "greeting": character.greeting, "examples": character.examples, "tags": character.tags,
                    "sourcePlatform": character.sourcePlatform, "sourceName": character.sourceName,
                    "sourceURL": character.sourceURL, "creatorName": character.creatorName,
                    "licence": character.licence, "importedAt": character.importedAt, "origin": character.origin,
                    "avatarFileName": character.avatarFileName as Any? ?? NSNull(),
                    "visibility": character.visibility as Any? ?? NSNull(),
                    "interactionCount": character.interactionCount as Any? ?? NSNull()
                ]
            }
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    func conversation(for character: LocalCharacter) throws -> LocalCharacterConversation {
        if let existing = conversations[character.id] { return existing }
        let url = conversationFile(character.id)
        let conversation: LocalCharacterConversation
        do {
            let data = try Data(contentsOf: url)
            let savedConversation = try JSONDecoder().decode(LocalCharacterConversation.self, from: data)
            guard savedConversation.characterID == character.id else {
                throw LocalCharacterLibraryError.conversationUnavailable
            }
            conversation = savedConversation
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            conversation = LocalCharacterConversation(character: character)
        } catch {
            throw LocalCharacterLibraryError.conversationUnavailable
        }
        try saveConversation(conversation)
        conversations[character.id] = conversation
        return conversation
    }

    func append(_ message: LocalChatMessage, characterID: String) throws {
        guard var conversation = conversations[characterID] else { throw LocalCharacterLibraryError.conversationNotFound }
        conversation.messages.append(message)
        conversation.updatedAt = Date()
        try saveConversation(conversation)
        conversations[characterID] = conversation
    }

    private func load() {
        do {
            let data: Data
            do {
                data = try Data(contentsOf: catalogueURL)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return
            }
            characters = try JSONDecoder().decode([LocalCharacter].self, from: data)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            catalogueIsAvailable = false
            errorMessage = LocalCharacterLibraryError.catalogueUnavailable.localizedDescription
        }
    }

    private func saveCatalogue() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(characters).write(to: catalogueURL, options: .atomic)
    }

    private func saveConversation(_ conversation: LocalCharacterConversation) throws {
        try FileManager.default.createDirectory(at: conversationsURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(conversation).write(to: conversationFile(conversation.characterID), options: .atomic)
    }

    private func conversationFile(_ characterID: String) -> URL {
        let filename: String
        if UUID(uuidString: characterID) != nil {
            filename = characterID
        } else {
            filename = Data(characterID.utf8).base64EncodedString()
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "=", with: "")
        }
        return conversationsURL.appendingPathComponent("\(filename).json")
    }
}
