//
//  RecentChatsResponse.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 26/09/2026.
//

import Foundation

struct RecentChatsResponse: Decodable {
    let chats: [RecentChat]
    let meta: RecentChatsMeta
}

struct RecentChatsMeta: Decodable {
    let nextToken: String?

    enum CodingKeys: String, CodingKey {
        case nextToken = "next_token"
    }
}

struct RecentChat: Decodable {
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

struct RecentTurnKey: Decodable {
    let chatID: String
    let turnID: String

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case turnID = "turn_id"
    }
}

struct RecentTurnAuthor: Decodable {
    let authorID: String
    let isHuman: Bool?
    let name: String

    enum CodingKeys: String, CodingKey {
        case authorID = "author_id"
        case isHuman = "is_human"
        case name
    }
}

struct RecentTurnCandidate: Decodable {
    let candidateID: String
    let rawContent: String
    let isFinal: Bool?

    enum CodingKeys: String, CodingKey {
        case candidateID = "candidate_id"
        case rawContent = "raw_content"
        case isFinal = "is_final"
    }
}
