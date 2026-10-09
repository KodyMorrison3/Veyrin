//
//  SessionValidator.swift
//  Character AI swift project
//

import Foundation

enum SessionValidationError: Error, Equatable {
    /// The server rejected the token (HTTP 401/403).
    case invalidSession
    /// The session could not be verified (network, server or unexpected response).
    case unavailable
    /// The token was accepted, but no account ID was available from the API or user input.
    case accountIDUnavailable
}

/// Identity the server confirmed for a token. Fields are `nil` when the
/// response does not provide them; nothing is inferred or fabricated.
struct ValidatedAccount: Equatable, Sendable {
    let username: String?
    let userID: String?
}

/// Validates a session token with the existing authenticated persona list
/// request (`GET https://neo.character.ai/character/v1/get_user_personas`).
/// It is the only existing authenticated endpoint that does not need a
/// username, so it can run before any identity is known.
struct SessionValidator {
    private let session: URLSession

    nonisolated init(session: URLSession = .shared) {
        self.session = session
    }

    nonisolated func validate(sessionToken: String) async throws -> ValidatedAccount {
        guard let url = URL(string: "https://neo.character.ai/character/v1/get_user_personas?force_refresh=0") else {
            throw SessionValidationError.unavailable
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Token \(sessionToken)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            throw SessionValidationError.unavailable
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SessionValidationError.unavailable
        }

        switch httpResponse.statusCode {
        case 401, 403:
            throw SessionValidationError.invalidSession
        case 200..<300:
            break
        default:
            throw SessionValidationError.unavailable
        }

        // Only the fields needed for identity are decoded, so unrelated schema
        // changes in persona records do not reject an otherwise valid session.
        guard let decoded = try? JSONDecoder().decode(ValidationPersonasResponse.self, from: data) else {
            throw SessionValidationError.unavailable
        }

        let username = decoded.personas.lazy
            .compactMap(\.userUsername)
            .first(where: { !$0.isEmpty })
        let userID = try await loadAccountID(sessionToken: sessionToken)
        return ValidatedAccount(username: username, userID: userID)
    }

    /// The persona response may omit the account ID (`user__id` is null in
    /// captured responses), so resolve it from the authenticated account route.
    nonisolated private func loadAccountID(sessionToken: String) async throws -> String? {
        guard let url = URL(string: "https://plus.character.ai/chat/user/") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Token \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  200..<300 ~= httpResponse.statusCode else { return nil }
            return try? JSONDecoder().decode(SessionAccountResponse.self, from: data).accountID
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }
}

nonisolated private struct SessionAccountResponse: Decodable, Sendable {
    let user: Account?
    let id: AccountIdentifier?
    let userID: AccountIdentifier?
    let userExternalID: AccountIdentifier?

    enum CodingKeys: String, CodingKey {
        case user
        case id
        case userID = "user_id"
        case userExternalID = "user__id"
    }

    var accountID: String? {
        user?.accountID ?? userID?.stringValue ?? userExternalID?.stringValue ?? id?.stringValue
    }

    nonisolated struct Account: Decodable, Sendable {
        let id: AccountIdentifier?
        let user: NestedAccount?
        let userID: AccountIdentifier?
        let userExternalID: AccountIdentifier?

        enum CodingKeys: String, CodingKey {
            case id
            case user
            case userID = "user_id"
            case userExternalID = "user__id"
        }

        var accountID: String? {
            user?.accountID ?? userID?.stringValue ?? userExternalID?.stringValue ?? id?.stringValue
        }
    }

    nonisolated struct NestedAccount: Decodable, Sendable {
        let id: AccountIdentifier?
        let userID: AccountIdentifier?
        let userExternalID: AccountIdentifier?

        enum CodingKeys: String, CodingKey {
            case id
            case userID = "user_id"
            case userExternalID = "user__id"
        }

        var accountID: String? {
            userID?.stringValue ?? userExternalID?.stringValue ?? id?.stringValue
        }
    }
}

nonisolated private struct AccountIdentifier: Decodable, Sendable {
    let stringValue: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Account ID cannot be empty."
                )
            }
            stringValue = trimmed
        } else if let value = try? container.decode(Int64.self), value != 0 {
            stringValue = String(value)
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Expected a non-empty string or non-zero integer account ID.")
            )
        }
    }
}

nonisolated private struct ValidationPersonasResponse: Decodable, Sendable {
    let personas: [Item]

    nonisolated struct Item: Decodable, Sendable {
        let userUsername: String?

        enum CodingKeys: String, CodingKey {
            case userUsername = "user__username"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            userUsername = try container.decodeIfPresent(String.self, forKey: .userUsername)
        }
    }
}
