//
//  WebSocketTurnResponse.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 26/09/2026.
//

import Foundation

struct WebSocketTurnResponse: Decodable {
    let turn: APITurn?
    let chatInfo: ChatInfo?
    let command: String
    let requestID: String

    enum CodingKeys: String, CodingKey {
        case turn
        case chatInfo = "chat_info"
        case command
        case requestID = "request_id"
    }
}

struct ChatInfo: Decodable {
    let type: String
}

struct WebSocketErrorResponse: Decodable {
    let command: String
    let requestID: String
    let comment: String
    let errorCode: Int
    let subCode: Int?
    let retryAfterSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case command
        case requestID = "request_id"
        case comment
        case errorCode = "error_code"
        case subCode = "sub_code"
        case retryAfterSeconds = "retry_after_seconds"
    }
}
