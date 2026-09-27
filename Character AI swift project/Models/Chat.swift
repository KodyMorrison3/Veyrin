import Foundation

struct Chat: Codable {
    let chatID: String
    let creatorID: String
    let visibility: String
    let characterID: String
    let type: String

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case creatorID = "creator_id"
        case visibility
        case characterID = "character_id"
        case type
    }
}
