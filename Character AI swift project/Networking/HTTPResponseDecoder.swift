import Foundation

/// Request construction and authentication stay on MainActor. Only immutable
/// response bytes and explicitly nonisolated, Sendable DTOs cross this boundary.
nonisolated enum HTTPResponseDecoder {
    @concurrent
    static func decode<Response: Decodable & Sendable>(
        _ type: Response.Type,
        from data: Data
    ) async throws -> Response {
        try Task.checkCancellation()
        do {
            let response = try JSONDecoder().decode(type, from: data)
            try Task.checkCancellation()
            return response
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NetworkError.decodingError(error)
        }
    }
}
