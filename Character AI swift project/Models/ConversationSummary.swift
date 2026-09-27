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
}
