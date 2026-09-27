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
    let creatorID: String
    let characterID: String
    let characterName: String
    let state: String
    let type: String
    let visibility: String

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case creatorID = "creator_id"
        case characterID = "character_id"
        case characterName = "character_name"
        case state
        case type
        case visibility
    }
}
