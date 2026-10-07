import Foundation

nonisolated struct CachedConversation: Sendable {
    var revision = UUID()
    let characterID: String
    var turns: [Turn]
    var nextToken: String?
    var visitedTokens: Set<String>
    var isComplete: Bool

    var cost: Int {
        turns.reduce(256) { total, turn in
            total + 512 + turn.candidates.reduce(0) { $0 + 256 + $1.rawContent.utf8.count * 4 }
        }
    }
}
