//
//  ConversationSummary.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 27/09/2026.
//

import Foundation

struct ConversationSummary: Identifiable {
    let id: String
    let chatID: String
    let characterID: String
    let characterName: String
    let characterAvatarURI: String
    let lastUpdated: String
    let state: String
    let lastMessage: String?

    static func matchingCharacterName(
        _ searchText: String,
        in conversations: [ConversationSummary]
    ) -> [ConversationSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return conversations
        }

        return conversations.filter {
            $0.characterName.localizedCaseInsensitiveContains(query)
        }
    }
}
