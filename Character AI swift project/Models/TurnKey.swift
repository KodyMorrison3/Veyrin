import Foundation

nonisolated struct TurnKey: Codable, Hashable, Sendable {
    let turnId: String
    let chatId: String

    enum CodingKeys: String, CodingKey {
        case turnId = "turn_id"
        case chatId = "chat_id"
    }
}
