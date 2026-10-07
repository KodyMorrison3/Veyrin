import Foundation

/// Represents a user persona from `GET https://neo.character.ai/character/v1/get_user_personas?force_refresh=0`
/// and persona settings from `GET / POST https://plus.character.ai/chat/user/settings/`
nonisolated struct Persona: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: String
    var externalID: String
    var displayName: String
    var title: String?
    var greeting: String?
    var description: String?
    var definition: String?
    var avatarFileName: String?
    var isDefaultUser: Bool

    var avatarURL: URL? {
        guard let avatarFileName, !avatarFileName.isEmpty else { return nil }
        return CharacterImageURL.makeURL(avatarFileName: avatarFileName)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case externalID = "external_id"
        case displayName = "display_name"
        case title
        case greeting
        case description
        case definition
        case avatarFileName = "avatar_file_name"
        case isDefaultUser = "is_default_user"
    }

    init(
        id: String,
        externalID: String? = nil,
        displayName: String,
        title: String? = nil,
        greeting: String? = nil,
        description: String? = nil,
        definition: String? = nil,
        avatarFileName: String? = nil,
        isDefaultUser: Bool = false
    ) {
        self.id = id
        self.externalID = externalID ?? id
        self.displayName = displayName
        self.title = title
        self.greeting = greeting
        self.description = description
        self.definition = definition
        self.avatarFileName = avatarFileName
        self.isDefaultUser = isDefaultUser
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.externalID = try container.decodeIfPresent(String.self, forKey: .externalID) ?? id
        self.displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.greeting = try container.decodeIfPresent(String.self, forKey: .greeting)
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.definition = try container.decodeIfPresent(String.self, forKey: .definition)
        self.avatarFileName = try container.decodeIfPresent(String.self, forKey: .avatarFileName)
        self.isDefaultUser = try container.decodeIfPresent(Bool.self, forKey: .isDefaultUser) ?? false
    }

    static func defaultUser(username: String = "", avatarFileName: String? = nil) -> Persona {
        let clean = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = clean.isEmpty ? "User" : clean
        return Persona(
            id: "default_user",
            externalID: "default_user",
            displayName: resolved,
            title: resolved,
            greeting: nil,
            description: nil,
            definition: nil,
            avatarFileName: avatarFileName,
            isDefaultUser: true
        )
    }
}

/// Response payload for `GET https://neo.character.ai/character/v1/get_user_personas?force_refresh=0`
nonisolated struct UserPersonasResponse: Decodable, Sendable {
    let personas: [UserPersonaItem]
}

/// A persona item within the Character.AI personas API response
nonisolated struct UserPersonaItem: Decodable, Sendable {
    let id: Int
    let externalID: String
    let title: String
    let greeting: String?
    let description: String?
    let definition: String?
    let avatarFileName: String?
    let visibility: String?
    let copyable: Bool?
    let participantName: String?
    let userUsername: String?
    let isPersona: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case externalID = "external_id"
        case title
        case greeting
        case description
        case definition
        case avatarFileName = "avatar_file_name"
        case visibility
        case copyable
        case participantName = "participant__name"
        case userUsername = "user__username"
        case isPersona = "is_persona"
    }

    func toPersona() -> Persona {
        Persona(
            id: externalID,
            externalID: externalID,
            displayName: (participantName?.isEmpty == false ? participantName! : title),
            title: title,
            greeting: greeting,
            description: description,
            definition: definition,
            avatarFileName: avatarFileName,
            isDefaultUser: false
        )
    }
}

/// Response from `GET https://plus.character.ai/chat/user/settings/?v=2`
nonisolated struct UserSettingsResponse: Decodable, Sendable {
    let personaSettings: PersonaSettingsContainer?
    let personaOverrides: [String: String]?
    let defaultPersonaId: String?

    enum CodingKeys: String, CodingKey {
        case personaSettings
        case personaOverrides
        case defaultPersonaId = "default_persona_id"
    }
}

nonisolated struct PersonaSettingsContainer: Decodable, Sendable {
    let defaultPersonaId: String?
    let characterOverrides: [String: String]?
}

/// Response from `POST https://plus.character.ai/chat/user/update_settings/`
nonisolated struct UpdateSettingsResponse: Decodable, Sendable {
    let success: Bool?
}

/// Request body for `POST https://plus.character.ai/chat/user/update_settings/`
nonisolated struct UpdatePersonaOverridesRequest: Encodable, Sendable {
    let personaOverrides: [String: String]
}
