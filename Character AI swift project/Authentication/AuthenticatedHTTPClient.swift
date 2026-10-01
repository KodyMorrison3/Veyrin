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

    func post<Body: Encodable, Response: Decodable>(
        _ url: URL,
        body: Body
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)

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
    
    func send(
        _ url: URL,
        method: String,
        body: Data? = nil
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

        try addAuthentication(
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
                await authStore.clearSession()
                throw NetworkError.unauthenticated
            }

            guard 200..<300 ~= httpResponse.statusCode else {
                throw NetworkError.httpError(
                    httpResponse.statusCode
                )
            }
        } catch let error as NetworkError {
            throw error
        } catch {
            throw NetworkError.requestFailed(error)
        }
    }

    func getRaw(
        _ url: URL
    ) async throws -> Data {
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

            return data
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
