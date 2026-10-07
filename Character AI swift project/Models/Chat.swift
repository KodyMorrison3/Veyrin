import Foundation

nonisolated struct ChatResponse: Decodable, Sendable {
    let chat: Chat
    let metadata: ChatMetadataContainer?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.chat) {
            chat = try container.decode(Chat.self, forKey: .chat)
            metadata = try container.decodeIfPresent(ChatMetadataContainer.self, forKey: .metadata)
        } else {
            // Preserve the already-supported direct shape without refetching.
            chat = try Chat(from: decoder)
            metadata = nil
        }
    }

    private enum CodingKeys: String, CodingKey { case chat, metadata }
}

nonisolated struct ChatMetadataContainer: Decodable, Sendable {
    let preferredModelType: String?

    enum CodingKeys: String, CodingKey {
        case preferredModelType = "preferred_model_type"
    }
}

nonisolated struct Chat: Codable, Sendable {
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
