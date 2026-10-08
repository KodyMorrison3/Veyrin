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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        turnKey = try container.decode(APITurnKey.self, forKey: .turnKey)
        createTime = try container.decodeIfPresent(String.self, forKey: .createTime)
        lastUpdateTime = try container.decodeIfPresent(String.self, forKey: .lastUpdateTime)
        // Streaming and filtered frames omit turn-level fields the web client
        // itself guards (`e.primary_candidate_id && (...)`); they must decode
        // rather than abort the whole response.
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? ""
        author = try container.decode(TurnAuthor.self, forKey: .author)
        candidates = try container.decode([APICandidate].self, forKey: .candidates)
        primaryCandidateID = try container.decodeIfPresent(String.self, forKey: .primaryCandidateID) ?? ""
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned)
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        authorID = try container.decode(String.self, forKey: .authorID)
        // The web client renders author names with `?? ""` guards.
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
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
    let isSafetyTruncated: Bool?

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
        case isSafetyTruncated = "safety_truncated"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The web client tolerates absent candidate identity/content
        // (`o.candidate_id ? ... : -1`, `o.raw_content?.trim()`), including on
        // censored (`safety_truncated`) candidates. A frame omitting them must
        // still decode so the turn is represented instead of failing routing.
        candidateID = try container.decodeIfPresent(String.self, forKey: .candidateID) ?? ""
        createTime = try container.decodeIfPresent(String.self, forKey: .createTime)
        rawContent = try container.decodeIfPresent(String.self, forKey: .rawContent) ?? ""
        editor = try container.decodeIfPresent(TurnEditor.self, forKey: .editor)
        isFinal = try container.decodeIfPresent(Bool.self, forKey: .isFinal)
        modelType = try container.decodeIfPresent(String.self, forKey: .modelType)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        isSafetyTruncated = try container.decodeIfPresent(Bool.self, forKey: .isSafetyTruncated)
    }
}
