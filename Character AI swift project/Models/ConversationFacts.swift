import Foundation

/// Response from `GET https://neo.character.ai/chat/{chatID}/conversation-facts/`
struct ConversationFactsResponse: Decodable {
    let conversationFacts: [String: EntityConversationFacts]?
    let conversationFactOverrides: [String: EntityFactOverrides]?

    enum CodingKeys: String, CodingKey {
        case conversationFacts = "conversation_facts"
        case conversationFactOverrides = "conversation_fact_overrides"
    }
}

/// Extracted facts for a particular entity (character, user, or other mentioned participants)
struct EntityConversationFacts: Decodable {
    let facts: [ConversationFact]
}

/// A specific attribute or memo fact identified by Character.AI memory system
struct ConversationFact: Decodable, Identifiable, Hashable {
    let category: String
    let value: String

    var id: String { "\(category):\(value)" }
}

/// Fact overrides for an entity
struct EntityFactOverrides: Decodable {
    let overrides: [String: FactOverrideDetail]?
}

struct FactOverrideDetail: Decodable {
    let operation: String?
    let value: String?
}

/// Response from `GET https://neo.character.ai/character/v1/character_voted/{characterID}/voted`
struct CharacterVotedResponse: Decodable {
    let status: String
    let voted: Bool
}
