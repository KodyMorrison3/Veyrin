//
//  ChatPreviewResponse.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 28/09/2026.
//

import Foundation

nonisolated struct ChatPreviewResponse: Decodable, Sendable {
    let chats: [ChatPreview]

    enum CodingKeys: String, CodingKey {
        case chats
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The server omits `chats` entirely when the character has no conversations.
        chats = try container.decodeIfPresent([ChatPreview].self, forKey: .chats) ?? []
    }
}
