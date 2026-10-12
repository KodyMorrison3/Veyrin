//
//  UserProfileService.swift
//  Character AI swift project
//
//  Loads the signed-in user's public profile via
//  `GET https://character.ai/api/trpc/social.publicProfile?batch=1&input=
//  {"0":{"json":{"username":"…"}}}` — captured in profile.har and
//  live-verified with the app's existing `Token` auth (HTTP 200; the
//  endpoint is public, so no web-session credential is required).
//
//  Mirrors DiscoverService's shape (same AuthorizationProvider pattern,
//  same NetworkError mapping).
//

import Foundation

struct UserProfileService {
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
    /// Test-only fixed-token provider. Production code should use the
    /// `authStore` initializer; contract tests must not touch the Keychain.
    init(
        session: URLSession = CharacterAISession.shared,
        fixedToken: String
    ) {
        self.session = session
        self.authorizationProvider = .fixedToken(fixedToken)
    }
    #endif

    func loadProfile(username: String, forceRefresh: Bool = false) async throws -> UserProfile {
        try await authorizationProvider.cached(key: "user-profile:\(username)", ttl: 300, forceRefresh: forceRefresh,
                                               cost: { _ in 2048 }) {
            try await fetchProfile(username: username)
        }
    }

    private func fetchProfile(username: String) async throws -> UserProfile {
        // Escaping is defensive: the username comes from the user's own
        // stored session.
        let escaped = username
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let input = "{\"0\":{\"json\":{\"username\":\"\(escaped)\"}}}"

        var components = URLComponents(
            string: "https://character.ai/api/trpc/social.publicProfile"
        )
        components?.queryItems = [
            URLQueryItem(name: "batch", value: "1"),
            URLQueryItem(name: "input", value: input),
        ]

        guard let url = components?.url else {
            throw NetworkError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        try await addAuthentication(to: &request)

        let data = try await responseData(for: request)

        do {
            let response = try await HTTPResponseDecoder.decode(UserProfileResponse.self, from: data)
            guard let profile = response.firstProfile() else {
                throw NetworkError.invalidResponse
            }
            return profile
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NetworkError {
            throw error
        } catch {
            try Task.checkCancellation()
            throw NetworkError.decodingError(error)
        }
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

    private func responseData(for request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.invalidResponse
            }

            guard 200..<300 ~= httpResponse.statusCode else {
                throw NetworkError.httpError(httpResponse.statusCode)
            }

            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NetworkError {
            throw error
        } catch {
            try Task.checkCancellation()
            throw NetworkError.requestFailed(error)
        }
    }
}
