//
//  UpdatePrimaryCandidateRequest.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 30/09/2026.
//

import Foundation

struct UpdatePrimaryCandidateRequest: Encodable {
    let chatType: String
    let candidateID: String
    let turnKey: UpdatePrimaryCandidateTurnKey

    enum CodingKeys: String, CodingKey {
        case chatType = "chat_type"
        case candidateID = "candidate_id"
        case turnKey = "turn_key"
    }
}

struct UpdatePrimaryCandidateTurnKey: Encodable {
    let chatID: String
    let turnID: String

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case turnID = "turn_id"
    }
}
