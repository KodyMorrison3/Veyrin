//
//  CreateChatRequest.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 26/09/2026.
//

import Foundation

struct CreateChatRequest: Encodable {
    let chatType: String
    let chat: NewChat
    let withGreeting: Bool
    let withPreGeneratedHistory: Bool

    enum CodingKeys: String, CodingKey {
        case chatType = "chat_type"
        case chat
        case withGreeting = "with_greeting"
        case withPreGeneratedHistory = "with_pre_generated_history"
    }
}

struct NewChat: Encodable {
    let chatID: String
    let creatorID: String
    let visibility: String
    let characterID: String
    let type: String

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case creatorID = "creator_id"
        case visibility
        case characterID = "character_id"
        case type
    }
}
