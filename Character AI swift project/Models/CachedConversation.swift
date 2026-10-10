import Foundation

nonisolated struct CachedConversation: Sendable {
    var revision = UUID()
    let characterID: String
    private(set) var turns: [Turn]
    var nextToken: String?
    var visitedTokens: Set<String>
    var isComplete: Bool
    private(set) var cost: Int

    init(characterID: String, turns: [Turn], nextToken: String?, visitedTokens: Set<String>, isComplete: Bool) {
        self.characterID = characterID
        self.turns = turns
        self.nextToken = nextToken
        self.visitedTokens = visitedTokens
        self.isComplete = isComplete
        cost = turns.reduce(256) { $0 + Self.cost($1) }
    }

    private static func cost(_ turn: Turn) -> Int {
        512 + turn.candidates.reduce(0) { $0 + 256 + $1.rawContent.utf8.count * 4 }
    }

    mutating func append(_ additions: [Turn]) {
        turns.append(contentsOf: additions)
        cost += additions.reduce(0) { $0 + Self.cost($1) }
    }

    mutating func update(_ turn: Turn) {
        if let index = turns.firstIndex(where: { $0.turnID == turn.turnID && $0.chatID == turn.chatID }) {
            cost += Self.cost(turn) - Self.cost(turns[index])
            turns[index] = turn
        } else { append([turn]) }
    }

    mutating func remove(_ ids: Set<String>) {
        turns.removeAll { turn in
            guard ids.contains(turn.turnID) else { return false }
            cost -= Self.cost(turn)
            return true
        }
    }
}
