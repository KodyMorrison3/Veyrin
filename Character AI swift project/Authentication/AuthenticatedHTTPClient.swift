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

    init(
        session: URLSession = .shared,
        authStore: AuthStore
    ) {
        self.session = session
        self.authStore = authStore
    }

    func get<Response: Decodable>(
        _ url: URL
    ) async throws -> Response {
        var request = URLRequest(url: url)

        try addAuthentication(
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
                await authStore.clearSession()
                throw NetworkError.unauthenticated
            }

            guard 200..<300 ~= httpResponse.statusCode else {
                throw NetworkError.httpError(
                    httpResponse.statusCode
                )
            }

            do {
                return try JSONDecoder().decode(
                    Response.self,
                    from: data
                )
            } catch {
                throw NetworkError.decodingError(error)
            }
        } catch let error as NetworkError {
            throw error
        } catch {
            throw NetworkError.requestFailed(error)
        }
    }

    private func addAuthentication(
        to request: inout URLRequest
    ) throws {
        guard let session = authStore.session else {
            throw NetworkError.unauthenticated
        }

        request.setValue(
            "Token \(session.sessionToken)",
            forHTTPHeaderField: "Authorization"
        )
    }
}
