import Foundation

/// Keeps JSON parsing off MainActor and decodes each payload only once into a
/// superset response model, without materializing the arbitrary payload dictionary.
actor WebSocketMessageProcessor {
    static let shared = WebSocketMessageProcessor()

    private let decoder = JSONDecoder()

    func decode(_ data: Data) throws -> WebSocketTurnResponse {
        try decoder.decode(WebSocketTurnResponse.self, from: data)
    }
}
