import Combine
import Foundation

/// Stable identity and observation boundary for one conversation turn.
@MainActor
final class TurnState: ObservableObject, Identifiable {
    @Published private(set) var turn: Turn

    var id: String { turn.turnID }

    init(_ turn: Turn) {
        self.turn = turn
    }

    func update(_ turn: Turn) {
        self.turn = turn
    }
}
