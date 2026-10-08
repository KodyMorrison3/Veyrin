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
}

/// Identity the server confirmed for a token. Fields are `nil` when the
/// response does not provide them; nothing is inferred or fabricated.
struct ValidatedAccount: Equatable, Sendable {
    let username: String?
}

/// Validates a session token with the existing authenticated persona list
/// request (`GET https://neo.character.ai/character/v1/get_user_personas`).
/// It is the only existing authenticated endpoint that does not need a
/// username, so it can run before any identity is known.
struct SessionValidator {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func validate(sessionToken: String) async throws -> ValidatedAccount {
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
        return ValidatedAccount(username: username)
    }
}

private struct ValidationPersonasResponse: Decodable {
    let personas: [Item]

    struct Item: Decodable {
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
