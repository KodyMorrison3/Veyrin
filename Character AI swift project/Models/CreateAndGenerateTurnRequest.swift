//
//  CreateAndGenerateTurnRequest.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 26/09/2026.
//

import Foundation

struct CreateAndGenerateTurnRequest: Encodable {
    let chatType: String
    let numCandidates: Int
    let ttsEnabled: Bool
    let selectedLanguage: String
    let characterID: String
    let userName: String
    let turn: NewTurn
    let previousAnnotations: [String: AnyCodable]
    let generateComparison: Bool

    enum CodingKeys: String, CodingKey {
        case chatType = "chat_type"
        case numCandidates = "num_candidates"
        case ttsEnabled = "tts_enabled"
        case selectedLanguage = "selected_language"
        case characterID = "character_id"
        case userName = "user_name"
        case turn
        case previousAnnotations = "previous_annotations"
        case generateComparison = "generate_comparison"
    }
}

struct NewTurn: Encodable {
    let turnKey: NewTurnKey
    let author: NewTurnAuthor
    let candidates: [NewCandidate]
    let primaryCandidateID: String

    enum CodingKeys: String, CodingKey {
        case turnKey = "turn_key"
        case author
        case candidates
        case primaryCandidateID = "primary_candidate_id"
    }
}

struct NewTurnKey: Encodable {
    let turnID: String
    let chatID: String

    enum CodingKeys: String, CodingKey {
        case turnID = "turn_id"
        case chatID = "chat_id"
    }
}

struct NewTurnAuthor: Encodable {
    let authorID: String
    let isHuman: Bool
    let name: String

    enum CodingKeys: String, CodingKey {
        case authorID = "author_id"
        case isHuman = "is_human"
        case name
    }
}

struct NewCandidate: Encodable {
    let candidateID: String
    let rawContent: String

    enum CodingKeys: String, CodingKey {
        case candidateID = "candidate_id"
        case rawContent = "raw_content"
    }
}
