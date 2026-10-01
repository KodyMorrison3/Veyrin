import Foundation

struct CharacterProfile: Decodable, Identifiable {
    let externalID: String
    let name: String?
    let title: String?
    let visibility: String?
    let greeting: String?
    let additionalGreetings: [String]?
    let dynamicGreetingEnabled: Bool?
    let allowDynamicGreeting: Bool?
    let description: String?
    let avatarFileName: String?
    let starterPrompts: [String]?
    let commentsEnabled: Bool?
    let interactionCount: Int?
    let upvotes: Int?

    var id: String { externalID }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        externalID = try container.decode(String.self, forKey: .externalID)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        visibility = try container.decodeIfPresent(String.self, forKey: .visibility)
        greeting = try container.decodeIfPresent(String.self, forKey: .greeting)
        additionalGreetings = try container.decodeIfPresent([String].self, forKey: .additionalGreetings)
        dynamicGreetingEnabled = try container.decodeIfPresent(Bool.self, forKey: .dynamicGreetingEnabled)
        allowDynamicGreeting = try container.decodeIfPresent(Bool.self, forKey: .allowDynamicGreeting)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        avatarFileName = try container.decodeIfPresent(String.self, forKey: .avatarFileName)
        starterPrompts = try? container.decodeIfPresent([String].self, forKey: .starterPrompts)
        commentsEnabled = try container.decodeIfPresent(Bool.self, forKey: .commentsEnabled)
        interactionCount = try container.decodeIfPresent(Int.self, forKey: .interactionCount)
        upvotes = try container.decodeIfPresent(Int.self, forKey: .upvotes)
    }

    enum CodingKeys: String, CodingKey {
        case externalID = "external_id"
        case name
        case title
        case visibility
        case greeting
        case additionalGreetings = "additional_greetings"
        case dynamicGreetingEnabled = "dynamic_greeting_enabled"
        case allowDynamicGreeting = "allow_dynamic_greeting"
        case description
        case avatarFileName = "avatar_file_name"
        case starterPrompts = "starter_prompts"
        case commentsEnabled = "comments_enabled"
        case interactionCount = "participant__num_interactions"
        case upvotes
    }
}

struct CharacterProfileResponse: Decodable {
    let character: CharacterProfile
    let status: String?
}

struct SimilarCharacter: Decodable {
    let externalID: String?
    let name: String?
    let title: String?
    let description: String?
    let avatarFileName: String?

    enum CodingKeys: String, CodingKey {
        case externalID = "external_id"
        case name
        case title
        case description
        case avatarFileName = "avatar_file_name"
    }
}

struct SimilarCharactersResponse: Decodable {
    let characters: [SimilarCharacter]
}
