import Foundation

/// Response from `GET https://neo.character.ai/chat/{chatID}/conversation-facts/`
nonisolated struct ConversationFactsResponse: Decodable, Sendable {
    let conversationFacts: [String: EntityConversationFacts]?
    let conversationFactOverrides: [String: EntityFactOverrides]?

    enum CodingKeys: String, CodingKey {
        case conversationFacts = "conversation_facts"
        case conversationFactOverrides = "conversation_fact_overrides"
    }
}

/// Extracted facts for a particular entity (character, user, or other mentioned participants)
nonisolated struct EntityConversationFacts: Decodable, Sendable {
    let facts: [ConversationFact]
}

/// A specific attribute or memo fact identified by Character.AI memory system
nonisolated struct ConversationFact: Decodable, Identifiable, Hashable, Sendable {
    let category: String
    let value: String

    var id: String { "\(category):\(value)" }
}

/// Fact overrides for an entity
nonisolated struct EntityFactOverrides: Decodable, Sendable {
    let overrides: [String: FactOverrideDetail]?
}

nonisolated struct FactOverrideDetail: Decodable, Sendable {
    let operation: String?
    let value: String?
}

/// Response from `GET https://neo.character.ai/character/v1/character_voted/{characterID}/voted`
nonisolated struct CharacterVotedResponse: Decodable, Sendable {
    let status: String
    let voted: Bool
}
