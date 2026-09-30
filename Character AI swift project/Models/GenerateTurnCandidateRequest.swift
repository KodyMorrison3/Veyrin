//
//  GenerateTurnCandidateRequest.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 30/09/2026.
//

struct GenerateTurnCandidateRequest: Encodable {
    let chatType: String
    let ttsEnabled: Bool
    let selectedLanguage: String
    let characterID: String
    let userName: String
    let turnKey: GenerateTurnKey
    let previousAnnotations: GenerateTurnAnnotations

    enum CodingKeys: String, CodingKey {
        case chatType = "chat_type"
        case ttsEnabled = "tts_enabled"
        case selectedLanguage = "selected_language"
        case characterID = "character_id"
        case userName = "user_name"
        case turnKey = "turn_key"
        case previousAnnotations = "previous_annotations"
    }
}

struct GenerateTurnKey: Encodable {
    let turnID: String
    let chatID: String

    enum CodingKeys: String, CodingKey {
        case turnID = "turn_id"
        case chatID = "chat_id"
    }
}

struct GenerateTurnAnnotations: Encodable {
    let boring: Int = 0
    let notBoring: Int = 0
    let inaccurate: Int = 0
    let notInaccurate: Int = 0
    let repetitive: Int = 0
    let notRepetitive: Int = 0
    let outOfCharacter: Int = 0
    let notOutOfCharacter: Int = 0
    let badMemory: Int = 0
    let notBadMemory: Int = 0
    let long: Int = 0
    let notLong: Int = 0
    let endsChatEarly: Int = 0
    let notEndsChatEarly: Int = 0
    let funny: Int = 0
    let notFunny: Int = 0
    let interesting: Int = 0
    let notInteresting: Int = 0
    let helpful: Int = 0
    let notHelpful: Int = 0

    enum CodingKeys: String, CodingKey {
        case boring
        case notBoring = "not_boring"
        case inaccurate
        case notInaccurate = "not_inaccurate"
        case repetitive
        case notRepetitive = "not_repetitive"
        case outOfCharacter = "out_of_character"
        case notOutOfCharacter = "not_out_of_character"
        case badMemory = "bad_memory"
        case notBadMemory = "not_bad_memory"
        case long
        case notLong = "not_long"
        case endsChatEarly = "ends_chat_early"
        case notEndsChatEarly = "not_ends_chat_early"
        case funny
        case notFunny = "not_funny"
        case interesting
        case notInteresting = "not_interesting"
        case helpful
        case notHelpful = "not_helpful"
    }
}
