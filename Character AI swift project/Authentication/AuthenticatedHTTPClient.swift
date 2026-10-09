//
//  AuthenticatedHTTPClient.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 26/09/2026.
//

import Foundation

struct AuthenticatedHTTPClient {
    private let session: URLSession
    private let authStore: AuthStore
    var resources: ResourceCache { authStore.resources }
    var conversationCache: ResourceCache { authStore.conversations }
    var sessionGeneration: UUID { authStore.sessionGeneration }
    var accountID: String? { authStore.session?.userID }

    init(
        session: URLSession = .shared,
        authStore: AuthStore
    ) {
        self.session = session
        self.authStore = authStore
    }

    @MainActor
    func get<Response: Decodable & Sendable>(
        _ url: URL,
        headers: [String: String] = [:]
    ) async throws -> Response {
        var request = URLRequest(url: url)
        headers.forEach { name, value in
            request.setValue(value, forHTTPHeaderField: name)
        }

        let generation = try addAuthentication(
            to: &request
        )

        do {
            let (data, response) = try await session.data(
                for: request
            )

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.invalidResponse
            }

            if httpResponse.statusCode == 401 {
                // Only the session this request was made with may be cleared.
                authStore.invalidateSession(
                    ifGeneration: generation,
                    authorization: request.value(forHTTPHeaderField: "Authorization")
                )
                throw NetworkError.unauthenticated
            }

            guard 200..<300 ~= httpResponse.statusCode else {
                throw NetworkError.httpError(
                    httpResponse.statusCode
                )
            }
            let decoded = try await HTTPResponseDecoder.decode(Response.self, from: data)
            guard generation == authStore.sessionGeneration else { throw CancellationError() }
            return decoded
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NetworkError {
            throw error
        } catch {
            try Task.checkCancellation()
            throw NetworkError.requestFailed(error)
        }
    }

    @MainActor
    func post<Body: Encodable, Response: Decodable & Sendable>(
        _ url: URL,
        body: Body,
        headers: [String: String] = [:]
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        headers.forEach { name, value in
            request.setValue(value, forHTTPHeaderField: name)
        }

        let generation = try addAuthentication(
            to: &request
        )

        do {
            let (data, response) = try await session.data(
                for: request
            )

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.invalidResponse
            }

            if httpResponse.statusCode == 401 {
                // Only the session this request was made with may be cleared.
                authStore.invalidateSession(
                    ifGeneration: generation,
                    authorization: request.value(forHTTPHeaderField: "Authorization")
                )
                throw NetworkError.unauthenticated
            }

            guard 200..<300 ~= httpResponse.statusCode else {
                throw NetworkError.httpError(
                    httpResponse.statusCode
                )
            }
            let decoded = try await HTTPResponseDecoder.decode(Response.self, from: data)
            guard generation == authStore.sessionGeneration else { throw CancellationError() }
            return decoded
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NetworkError {
            throw error
        } catch {
            try Task.checkCancellation()
            throw NetworkError.requestFailed(error)
        }
    }
    
    @MainActor
    func send(
        _ url: URL,
        method: String,
        body: Data? = nil,
        headers: [String: String] = [:]
    ) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = method

        if let body {
            request.setValue(
                "application/json",
                forHTTPHeaderField: "Content-Type"
            )
            request.httpBody = body
        }

        headers.forEach { name, value in
            request.setValue(value, forHTTPHeaderField: name)
        }

        let generation = try addAuthentication(
            to: &request
        )

        do {
            let (_, response) = try await session.data(
                for: request
            )

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.invalidResponse
            }

            if httpResponse.statusCode == 401 {
                // Only the session this request was made with may be cleared.
                authStore.invalidateSession(
                    ifGeneration: generation,
                    authorization: request.value(forHTTPHeaderField: "Authorization")
                )
                throw NetworkError.unauthenticated
            }

            guard 200..<300 ~= httpResponse.statusCode else {
                throw NetworkError.httpError(
                    httpResponse.statusCode
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NetworkError {
            throw error
        } catch {
            try Task.checkCancellation()
            throw NetworkError.requestFailed(error)
        }
    }

    /// Attaches the current session and returns its generation, so a failure
    /// can be attributed to the session that made the request.
    @MainActor
    private func addAuthentication(
        to request: inout URLRequest
    ) throws -> UUID {
        guard let session = authStore.session else {
            throw NetworkError.unauthenticated
        }

        request.setValue(
            "Token \(session.sessionToken)",
            forHTTPHeaderField: "Authorization"
        )
        return authStore.sessionGeneration
    }
}
