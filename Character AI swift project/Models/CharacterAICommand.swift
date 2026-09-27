//
//  CharacterAICommand.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 26/09/2026.
//

import Foundation

struct CharacterAICommand<Payload: Encodable>: Encodable {
    let command: String
    let requestID: String
    let payload: Payload
    let originID: String

    enum CodingKeys: String, CodingKey {
        case command
        case requestID = "request_id"
        case payload
        case originID = "origin_id"
    }
}
