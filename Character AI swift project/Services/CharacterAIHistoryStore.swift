import CryptoKit
import Foundation

/// A local reading copy, not an authoritative conversation or an offline mutation queue.
nonisolated struct CharacterAIHistorySnapshot: Codable, Sendable {
    let version: Int
    let accountID: String
    let summary: ConversationSummary
    let turns: [Turn]
    let savedAt: Date
    var needsRefresh: Bool
}

@MainActor
final class CharacterAIHistoryStore {
    static let shared = CharacterAIHistoryStore()
    private let folder: URL
    private let maxBytes = 16 * 1024 * 1024

    init(supportDirectory: URL? = nil) {
        let root = supportDirectory
            ?? ProcessInfo.processInfo.environment["VEYRIN_SUPPORT_DIRECTORY"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Veyrin", isDirectory: true)
        folder = root.appendingPathComponent("character-ai-history", isDirectory: true)
    }

    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func accountFolder(_ accountID: String) -> URL {
        folder.appendingPathComponent(digest(accountID), isDirectory: true)
    }

    private func file(_ accountID: String, _ chatID: String) -> URL {
        accountFolder(accountID).appendingPathComponent(digest(chatID) + ".json")
    }

    func load(accountID: String, chatID: String) throws -> CharacterAIHistorySnapshot? {
        let url = file(accountID, chatID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maxBytes else { throw HistoryError.unreadable }
        let snapshot = try JSONDecoder().decode(CharacterAIHistorySnapshot.self, from: Data(contentsOf: url))
        guard snapshot.version == 1, snapshot.accountID == accountID,
              snapshot.summary.chatID == chatID,
              snapshot.turns.allSatisfy({ $0.chatID == chatID }) else { throw HistoryError.unreadable }
        return snapshot
    }

    func list(accountID: String) -> (snapshots: [CharacterAIHistorySnapshot], unreadable: Int) {
        let directory = accountFolder(accountID)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return ([], 0) }
        var snapshots: [CharacterAIHistorySnapshot] = []
        var unreadable = 0
        for url in files where url.pathExtension == "json" {
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= maxBytes else { throw HistoryError.unreadable }
                let snapshot = try JSONDecoder().decode(CharacterAIHistorySnapshot.self, from: Data(contentsOf: url))
                guard snapshot.version == 1, snapshot.accountID == accountID,
                      url.lastPathComponent == digest(snapshot.summary.chatID) + ".json",
                      snapshot.turns.allSatisfy({ $0.chatID == snapshot.summary.chatID }) else { throw HistoryError.unreadable }
                snapshots.append(snapshot)
            } catch { unreadable += 1 }
        }
        return (snapshots.sorted { $0.savedAt > $1.savedAt }, unreadable)
    }

    func save(accountID: String, summary: ConversationSummary, turns: [Turn]) throws {
        guard !accountID.isEmpty, !summary.chatID.isEmpty,
              turns.allSatisfy({ $0.chatID == summary.chatID && !$0.candidates.contains(where: { $0.isFinal == false }) }) else {
            throw HistoryError.unreadable
        }
        // Never replace an unreadable or foreign file with a seemingly empty result.
        _ = try load(accountID: accountID, chatID: summary.chatID)
        let snapshot = CharacterAIHistorySnapshot(version: 1, accountID: accountID, summary: summary,
                                                  turns: turns, savedAt: Date(), needsRefresh: false)
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= maxBytes else { throw HistoryError.tooLarge }
        try FileManager.default.createDirectory(at: accountFolder(accountID), withIntermediateDirectories: true)
        try data.write(to: file(accountID, summary.chatID), options: .atomic)
    }

    /// A failed or unconfirmed server mutation may have changed the remote chat.
    /// Preserve the old copy but make its uncertainty explicit before sending.
    func markNeedsRefresh(accountID: String, chatID: String) throws {
        guard var snapshot = try load(accountID: accountID, chatID: chatID) else { return }
        snapshot.needsRefresh = true
        try JSONEncoder().encode(snapshot).write(to: file(accountID, chatID), options: .atomic)
    }

    enum HistoryError: LocalizedError {
        case unreadable, tooLarge
        var errorDescription: String? {
            switch self {
            case .unreadable: "The saved reading copy could not be read and was left unchanged."
            case .tooLarge: "This conversation is too large to save as an offline reading copy."
            }
        }
    }
}
