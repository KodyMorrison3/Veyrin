//
//  EditTurnCandidateRequest.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 30/09/2026.
//

import Foundation

struct EditTurnCandidateRequest: Encodable {
    let chatType: String
    let turnKey: EditTurnKey
    let currentCandidateID: String
    let newCandidateRawContent: String

    enum CodingKeys: String, CodingKey {
        case chatType = "chat_type"
        case turnKey = "turn_key"
        case currentCandidateID = "current_candidate_id"
        case newCandidateRawContent = "new_candidate_raw_content"
    }
}

struct EditTurnKey: Encodable {
    let chatID: String
    let turnID: String

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case turnID = "turn_id"
    }
}
