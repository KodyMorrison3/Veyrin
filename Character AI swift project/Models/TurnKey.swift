import Foundation

struct TurnKey: Codable {
    let turnId: String
    let chatId: String

    enum CodingKeys: String, CodingKey {
        case turnId = "turn_id"
        case chatId = "chat_id"
    }
}
