//
//  WebSocketMessage.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 26/09/2026.
//

import Foundation

struct WebSocketMessage: Codable {
    let command: String
    let requestID: String
    let payload: [String: AnyCodable]?
    let originID: String?

    enum CodingKeys: String, CodingKey {
        case command
        case requestID = "request_id"
        case payload
        case originID = "origin_id"
    }
}
