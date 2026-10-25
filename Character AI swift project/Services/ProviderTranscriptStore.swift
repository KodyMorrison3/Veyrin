import Combine
import CryptoKit
import Foundation
import OSLog

nonisolated enum ProviderTranscriptError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "This saved conversation could not be read. Its file has been left unchanged. Restore it from a backup before continuing."
    }
}

/// Identity of a resumable provider conversation. `TextChatProvider` already
/// carries the saved configuration ID as its descriptor ID, so a cloud chat is
/// keyed by the configuration, not by its editable name or endpoint.
nonisolated struct ProviderTranscriptKey: Hashable, Sendable {
    let providerID: String
    let kind: ProviderKind
    let model: String
    let characterID: String?

    /// One string for the same conversation, used for file names, sidebar
    /// identity and selection, so all three can never disagree.
    var identity: String {
        [providerID, kind.rawValue, model, characterID ?? "-"].joined(separator: "\u{1F}")
    }
}

/// One row of the conversation sidebar.
nonisolated struct ProviderTranscriptSummary: Identifiable, Equatable, Sendable {
    let key: ProviderTranscriptKey
    let characterName: String?
    /// Nil for transcripts written before providers were recorded.
    var providerName: String? = nil
    let avatarFileName: String?
    let lastMessage: String?
    let updatedAt: Date

    /// Stable across launches, unlike a UUID generated at read time.
    var id: String { key.identity }

    /// The provider is the fallback title: it is what tells a local chat and a
    /// cloud chat apart when neither has a character. Transcripts written before
    /// provider names were stored still get a provider-type label, so existing
    /// rows are not two identical "Provider chat" entries.
    var title: String { characterName ?? providerName ?? key.kind.shortTitle }

    /// One-line preview: Markdown markers and line breaks would otherwise make
    /// every row look different from the message it points at.
    var preview: String? {
        guard let lastMessage else { return nil }
        let flattened = lastMessage
            .replacingOccurrences(of: "*", with: "")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return flattened.isEmpty ? nil : flattened
    }
}

/// One saved provider conversation. The stored key is written alongside the
/// messages so a moved or renamed file can never resurrect another chat.
nonisolated struct ProviderTranscript: Codable, Equatable, Sendable {
    let providerID: String
    let kind: ProviderKind
    let model: String
    let characterID: String?
    var characterName: String?
    /// Written with the transcript so the sidebar can name the provider a chat
    /// belongs to without reading the provider configuration.
    var providerName: String?
    var avatarFileName: String?
    var messages: [ProviderChatMessage]
    var updatedAt: Date

    init(key: ProviderTranscriptKey, messages: [ProviderChatMessage],
         characterName: String? = nil, avatarFileName: String? = nil,
         providerName: String? = nil, updatedAt: Date = Date()) {
        providerID = key.providerID
        kind = key.kind
        model = key.model
        characterID = key.characterID
        self.characterName = characterName
        self.providerName = providerName
        self.avatarFileName = avatarFileName
        self.messages = messages
        self.updatedAt = updatedAt
    }

    func matches(_ key: ProviderTranscriptKey) -> Bool {
        providerID == key.providerID && kind == key.kind && model == key.model && characterID == key.characterID
    }

    var summary: ProviderTranscriptSummary {
        ProviderTranscriptSummary(
            key: ProviderTranscriptKey(providerID: providerID, kind: kind, model: model, characterID: characterID),
            characterName: characterName,
            providerName: providerName,
            avatarFileName: avatarFileName,
            lastMessage: messages.last(where: { $0.role != .system })?.content,
            updatedAt: updatedAt
        )
    }
}

/// Disk-backed provider transcripts, one per provider, model and saved
/// character. Provider APIs are stateless, so the transcript is the whole chat:
/// resuming it and rewriting it after an edit or rewind are the same operation.
///
/// `summaries` powers the conversation sidebar. It is maintained incrementally
/// on save and delete, and read from disk once at launch, so a chat that is
/// receiving messages does not rescan every file per turn.
@MainActor
final class ProviderTranscriptStore: ObservableObject {
    static let shared = ProviderTranscriptStore()

    @Published private(set) var summaries: [ProviderTranscriptSummary] = []

    private let folder: URL
    private let logger = Logger(subsystem: "CharacterAI", category: "ProviderTranscripts")

    init(supportDirectory: URL? = nil) {
        // The verification runner points this at a scratch directory so its
        // fixture chats never appear as saved conversations in Application Support.
        let environmentRoot = ProcessInfo.processInfo.environment["VEYRIN_SUPPORT_DIRECTORY"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let support = supportDirectory
            ?? environmentRoot
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Veyrin", isDirectory: true)
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Veyrin", isDirectory: true)
        folder = support.appendingPathComponent("provider-chats", isDirectory: true)
        summaries = loadSummaries()
    }

    /// Returns the saved messages, or nil when this chat has not been saved yet.
    /// An unreadable file is not an empty conversation. Callers must surface
    /// the failure, and save checks again before replacing an existing file.
    func load(_ key: ProviderTranscriptKey) throws -> [ProviderChatMessage]? {
        try readTranscript(key)?.messages
    }

    func save(_ messages: [ProviderChatMessage], for key: ProviderTranscriptKey,
              characterName: String? = nil, avatarFileName: String? = nil,
              providerName: String? = nil) throws {
        _ = try readTranscript(key)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let transcript = ProviderTranscript(key: key, messages: messages,
                                            characterName: characterName, avatarFileName: avatarFileName,
                                            providerName: providerName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(transcript).write(to: fileURL(key), options: .atomic)
        upsert(transcript.summary, hasUserMessage: messages.contains { $0.role == .user })
    }

    func remove(_ key: ProviderTranscriptKey) throws {
        do { try FileManager.default.removeItem(at: fileURL(key)) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { }
        summaries.removeAll { $0.key == key }
    }

    private func readTranscript(_ key: ProviderTranscriptKey) throws -> ProviderTranscript? {
        do {
            let data = try Data(contentsOf: fileURL(key))
            let transcript = try JSONDecoder().decode(ProviderTranscript.self, from: data)
            guard transcript.matches(key) else {
                throw ProviderTranscriptError.unavailable
            }
            return transcript
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            logger.error("Provider transcript could not be read; it has been left in place")
            throw ProviderTranscriptError.unavailable
        }
    }

    private func loadSummaries() -> [ProviderTranscriptSummary] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return [] }
        let decoder = JSONDecoder()
        var found: [ProviderTranscriptSummary] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let transcript = try? decoder.decode(ProviderTranscript.self, from: data),
                  transcript.messages.contains(where: { $0.role == .user }) else { continue }
            found.append(transcript.summary)
        }
        return found.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func upsert(_ summary: ProviderTranscriptSummary, hasUserMessage: Bool) {
        // A chat with no user message is not worth a sidebar row: it is just a
        // greeting. Removing the row matters after a rewind to that state.
        summaries.removeAll { $0.id == summary.id }
        guard hasUserMessage else { return }
        summaries.append(summary)
        summaries.sort { $0.updatedAt > $1.updatedAt }
    }

    /// Hashed so long model identifiers cannot exceed a file-name limit and a
    /// model or character name never appears on disk as a folder listing.
    private func fileURL(_ key: ProviderTranscriptKey) -> URL {
        let digest = SHA256.hash(data: Data(key.identity.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent("\(name).json")
    }
}
