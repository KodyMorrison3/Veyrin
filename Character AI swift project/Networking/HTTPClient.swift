import Foundation

struct HTTPClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func get<Response: Decodable & Sendable>(
        _ url: URL
    ) async throws -> Response {
        do {
            let (data, response) = try await session.data(from: url)

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

    func post<Body: Encodable, Response: Decodable & Sendable>(
        _ url: URL,
        body: Body
    ) async throws -> Response {
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"

            request.setValue(
                "application/json",
                forHTTPHeaderField: "Content-Type"
            )

            request.setValue(
                "application/json",
                forHTTPHeaderField: "Accept"
            )

            request.httpBody = try JSONEncoder().encode(body)

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
}
