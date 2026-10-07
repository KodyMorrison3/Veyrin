//
//  TurnsResponse.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 26/09/2026.
//

import Foundation

nonisolated struct TurnsResponse: Decodable, Sendable {
    let turns: [APITurn]
    let meta: TurnsMeta
}

nonisolated struct TurnsMeta: Decodable, Sendable {
    let nextToken: String?

    enum CodingKeys: String, CodingKey {
        case nextToken = "next_token"
    }
}

nonisolated struct APITurn: Decodable, Sendable {
    let turnKey: APITurnKey
    let createTime: String?
    let lastUpdateTime: String?
    let state: String
    let author: TurnAuthor
    let candidates: [APICandidate]
    let primaryCandidateID: String
    let isPinned: Bool?

    enum CodingKeys: String, CodingKey {
        case turnKey = "turn_key"
        case createTime = "create_time"
        case lastUpdateTime = "last_update_time"
        case state
        case author
        case candidates
        case primaryCandidateID = "primary_candidate_id"
        case isPinned = "is_pinned"
    }
}

nonisolated struct APITurnKey: Decodable, Sendable {
    let turnID: String
    let chatID: String

    enum CodingKeys: String, CodingKey {
        case turnID = "turn_id"
        case chatID = "chat_id"
    }
}

nonisolated struct TurnAuthor: Decodable, Sendable {
    let authorID: String
    let name: String

    enum CodingKeys: String, CodingKey {
        case authorID = "author_id"
        case name
    }
}

nonisolated struct TurnEditor: Decodable, Sendable {
    let authorID: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case authorID = "author_id"
        case name
    }
}

nonisolated struct APICandidate: Decodable, Sendable {
    let candidateID: String
    let createTime: String?
    let rawContent: String
    let editor: TurnEditor?
    let isFinal: Bool?
    let modelType: String?
    let displayName: String?

    var userFacingModelName: String? {
        displayName ?? modelType.map(ModelSelectionOption.fallbackDisplayName(for:))
    }

    enum CodingKeys: String, CodingKey {
        case candidateID = "candidate_id"
        case createTime = "create_time"
        case rawContent = "raw_content"
        case editor
        case isFinal = "is_final"
        case modelType = "model_type"
        case displayName = "display_name"
    }
}
