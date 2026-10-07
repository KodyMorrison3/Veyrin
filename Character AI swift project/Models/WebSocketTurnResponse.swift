//
//  WebSocketTurnResponse.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 26/09/2026.
//

import Foundation

nonisolated struct WebSocketTurnResponse: Decodable, Sendable {
    let turn: APITurn?
    let chatInfo: ChatInfo?
    let command: String
    let requestID: String
    let errorComment: String?
    let errorCode: Int?
    let subCode: Int?
    let retryAfterSeconds: Int?

    var asErrorResponse: WebSocketErrorResponse {
        WebSocketErrorResponse(
            command: command,
            requestID: requestID,
            comment: errorComment ?? "Character.AI rejected the request.",
            errorCode: errorCode ?? 0,
            subCode: subCode,
            retryAfterSeconds: retryAfterSeconds
        )
    }

    enum CodingKeys: String, CodingKey {
        case turn
        case chatInfo = "chat_info"
        case command
        case requestID = "request_id"
        case errorComment = "comment"
        case errorCode = "error_code"
        case subCode = "sub_code"
        case retryAfterSeconds = "retry_after_seconds"
    }
}

nonisolated struct ChatInfo: Decodable, Sendable {
    let type: String
}

nonisolated struct WebSocketErrorResponse: Decodable, Sendable {
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
