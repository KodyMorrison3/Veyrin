//
//  TurnsResponse.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 26/09/2026.
//

import Foundation

struct TurnsResponse: Decodable {
    let turns: [APITurn]
    let meta: TurnsMeta
}

struct TurnsMeta: Decodable {
    let nextToken: String?

    enum CodingKeys: String, CodingKey {
        case nextToken = "next_token"
    }
}

struct APITurn: Decodable {
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

struct APITurnKey: Decodable {
    let turnID: String
    let chatID: String

    enum CodingKeys: String, CodingKey {
        case turnID = "turn_id"
        case chatID = "chat_id"
    }
}

struct TurnAuthor: Decodable {
    let authorID: String
    let name: String

    enum CodingKeys: String, CodingKey {
        case authorID = "author_id"
        case name
    }
}

struct TurnEditor: Decodable {
    let authorID: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case authorID = "author_id"
        case name
    }
}

struct APICandidate: Decodable {
    let candidateID: String
    let createTime: String?
    let rawContent: String
    let editor: TurnEditor?
    let isFinal: Bool?

    enum CodingKeys: String, CodingKey {
        case candidateID = "candidate_id"
        case createTime = "create_time"
        case rawContent = "raw_content"
        case editor
        case isFinal = "is_final"
    }
}
