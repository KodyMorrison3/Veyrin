import Foundation

struct ChatResponse: Decodable {
    let chat: Chat
    let metadata: ChatMetadataContainer?
}

struct ChatMetadataContainer: Decodable {
    let preferredModelType: String?

    enum CodingKeys: String, CodingKey {
        case preferredModelType = "preferred_model_type"
    }
}

struct Chat: Codable {
    let chatID: String
    let creatorID: String
    let visibility: String
    let characterID: String
    let type: String
    let preferredModelType: String?
    let modelPreferenceVersion: String?

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case creatorID = "creator_id"
        case visibility
        case characterID = "character_id"
        case type
        case preferredModelType = "preferred_model_type"
        case modelPreferenceVersion = "model_preference_version"
    }

    init(
        chatID: String,
        creatorID: String,
        visibility: String,
        characterID: String,
        type: String,
        preferredModelType: String? = nil,
        modelPreferenceVersion: String? = nil
    ) {
        self.chatID = chatID
        self.creatorID = creatorID
        self.visibility = visibility
        self.characterID = characterID
        self.type = type
        self.preferredModelType = preferredModelType
        self.modelPreferenceVersion = modelPreferenceVersion
    }
}
