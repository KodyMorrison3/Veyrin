//
//  CharmsService.swift
//  Character AI swift project
//
//  Read-only access to the captured VC transactions and quests endpoints.
//  No balance, claim, redeem, spend, or other mutation endpoint is assumed.
//

import Foundation

struct CharmsService {
    private let session: URLSession
    private let authorizationProvider: DiscoverService.AuthorizationProvider

    init(
        session: URLSession = CharacterAISession.shared,
        authStore: AuthStore
    ) {
        self.session = session
        self.authorizationProvider = .authStore(authStore)
    }

    #if DEBUG
    /// Test-only fixed-token provider. Production uses the stored app session.
    init(
        session: URLSession = CharacterAISession.shared,
        fixedToken: String
    ) {
        self.session = session
        self.authorizationProvider = .fixedToken(fixedToken)
    }
    #endif

    func loadTransactions(userID: String, forceRefresh: Bool = false) async throws -> [CharmTransaction] {
        try await authorizationProvider.cached(key: "charms:transactions:\(userID)", ttl: 120, forceRefresh: forceRefresh,
                                               cost: { $0.count * 512 + 256 }) {
            let response: CharmTransactionsResponse = try await get(
                userID: userID,
                resource: "transactions"
            )
            return response.transactions
        }
    }

    func loadQuests(userID: String, forceRefresh: Bool = false) async throws -> [CharmQuest] {
        try await authorizationProvider.cached(key: "charms:quests:\(userID)", ttl: 300, forceRefresh: forceRefresh,
                                               cost: { $0.count * 512 + 256 }) {
            let response: CharmQuestsResponse = try await get(
                userID: userID,
                resource: "quests"
            )
            return response.quests
        }
    }

    private func get<Response: Decodable & Sendable>(
        userID: String,
        resource: String
    ) async throws -> Response {
        guard let url = Self.url(userID: userID, resource: resource) else {
            throw NetworkError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try await addAuthentication(to: &request)

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.invalidResponse
            }
            guard 200..<300 ~= httpResponse.statusCode else {
                throw NetworkError.httpError(httpResponse.statusCode)
            }

            return try await HTTPResponseDecoder.decode(Response.self, from: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NetworkError {
            throw error
        } catch {
            try Task.checkCancellation()
            throw NetworkError.requestFailed(error)
        }
    }

    private static func url(userID: String, resource: String) -> URL? {
        let allowedCharacters = CharacterSet.urlPathAllowed
            .subtracting(CharacterSet(charactersIn: "/?#"))
        guard let escapedUserID = userID.addingPercentEncoding(
            withAllowedCharacters: allowedCharacters
        ) else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "subscription.api.character.ai"
        components.percentEncodedPath = "/v1/vc/users/\(escapedUserID)/\(resource)"
        return components.url
    }

    private func addAuthentication(to request: inout URLRequest) async throws {
        guard let token = await authorizationProvider.token else {
            throw NetworkError.unauthenticated
        }

        request.setValue(
            "Token \(token)",
            forHTTPHeaderField: "Authorization"
        )
    }
}
