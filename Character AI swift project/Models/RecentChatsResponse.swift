//
//  RecentChatsResponse.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 26/09/2026.
//

import Foundation

nonisolated struct RecentChatsResponse: Decodable, Sendable {
    let chats: [RecentChat]
    let meta: RecentChatsMeta?
}

nonisolated struct RecentChatsMeta: Decodable, Sendable {
    let nextToken: String?

    enum CodingKeys: String, CodingKey {
        case nextToken = "next_token"
    }
}

nonisolated struct RecentChat: Decodable, Sendable {
    let chatID: String
    let createTime: String
    let creatorID: String
    let characterID: String
    let state: String
    let type: String
    let visibility: String
    let characterName: String
    let characterAvatarURI: String
    let characterVisibility: String

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case createTime = "create_time"
        case creatorID = "creator_id"
        case characterID = "character_id"
        case state
        case type
        case visibility
        case characterName = "character_name"
        case characterAvatarURI = "character_avatar_uri"
        case characterVisibility = "character_visibility"
    }
}

nonisolated struct ChatHistoryListResponse: Decodable, Sendable {
    let chats: [ChatPreview]
}

nonisolated struct ChatPreview: Decodable, Sendable {
    let chatID: String
    let createTime: String
    let creatorID: String
    let characterID: String
    let state: String
    let type: String
    let visibility: String
    let preferredModelType: String?
    let modelPreferenceVersion: String?
    let previewTurns: [APITurn]?

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case createTime = "create_time"
        case creatorID = "creator_id"
        case characterID = "character_id"
        case state
        case type
        case visibility
        case preferredModelType = "preferred_model_type"
        case modelPreferenceVersion = "model_preference_version"
        case previewTurns = "preview_turns"
    }

    var lastMessage: String? {
        guard let lastTurn = previewTurns?.last,
              let candidate = lastTurn.candidates.first(where: {
                  $0.candidateID == lastTurn.primaryCandidateID
              }) ?? lastTurn.candidates.first else {
            return nil
        }
        return candidate.rawContent
    }

    var openingMessage: String? {
        guard let firstUserTurn = previewTurns?.first(where: { turn in
            turn.author.authorID != characterID
        }),
        let candidate = firstUserTurn.candidates.first(where: {
            $0.candidateID == firstUserTurn.primaryCandidateID
        }) ?? firstUserTurn.candidates.first else {
            return nil
        }
        return candidate.rawContent
    }
}

nonisolated struct RecentTurnKey: Decodable, Sendable {
    let chatID: String
    let turnID: String

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case turnID = "turn_id"
    }
}

nonisolated struct RecentTurnAuthor: Decodable, Sendable {
    let authorID: String
    let isHuman: Bool?
    let name: String

    enum CodingKeys: String, CodingKey {
        case authorID = "author_id"
        case isHuman = "is_human"
        case name
    }
}

nonisolated struct RecentTurnCandidate: Decodable, Sendable {
    let candidateID: String
    let rawContent: String
    let isFinal: Bool?

    enum CodingKeys: String, CodingKey {
        case candidateID = "candidate_id"
        case rawContent = "raw_content"
        case isFinal = "is_final"
    }
}
