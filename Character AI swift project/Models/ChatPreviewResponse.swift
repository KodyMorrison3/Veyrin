//
//  ChatPreviewResponse.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 28/09/2026.
//

import Foundation

struct ChatPreviewResponse: Decodable {
    let chats: [ChatPreview]
}

struct ChatPreview: Decodable {
    let chatID: String
    let previewTurns: [APITurn]?

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case previewTurns = "preview_turns"
    }

    var lastMessage: String? {
        previewTurns?.last?.candidates.first?.rawContent
    }
}
