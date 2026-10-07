//
//  ChatPreviewResponse.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 28/09/2026.
//

import Foundation

nonisolated struct ChatPreviewResponse: Decodable, Sendable {
    let chats: [ChatPreview]
}
