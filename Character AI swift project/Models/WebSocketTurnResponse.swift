//
//  WebSocketTurnResponse.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 26/09/2026.
//

import Foundation

nonisolated struct WebSocketTurnResponse: Decodable, Sendable {
    let turn: APITurn?
    let chat: Chat?
    let chatInfo: ChatInfo?
    let command: String
    /// Control frames (`{"command": "ok"}` replies to `update_primary_candidate`,
    /// verified in captured traffic) carry no `request_id` and must not abort
    /// routing; operations route by the requests they registered.
    let requestID: String?
    let errorComment: String?
    let errorCode: Int?
    let subCode: Int?
    let retryAfterSeconds: Int?

    var asErrorResponse: WebSocketErrorResponse {
        WebSocketErrorResponse(
            command: command,
            requestID: requestID ?? "",
            // Server comments can echo submitted content; don't put them in UI errors or logs.
            comment: "Character.AI rejected the request (code \(errorCode ?? 0)).",
            errorCode: errorCode ?? 0,
            subCode: subCode,
            retryAfterSeconds: retryAfterSeconds
        )
    }

    enum CodingKeys: String, CodingKey {
        case turn
        case chat
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

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case type
    }
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
