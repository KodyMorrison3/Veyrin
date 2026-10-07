import Foundation
import OSLog

private let webSocketLogger = Logger(subsystem: "CharacterAI", category: "WebSocket")

final class WebSocketClient {
    private let session: URLSession
    private var webSocketTask: URLSessionWebSocketTask?
    private(set) var isConnected = false
    
    init(session: URLSession = .shared) {
        self.session = session
    }

    func connect(sessionToken: String) async throws {
        disconnect()

        guard let url = URL(string: "wss://neo.character.ai/ws/") else {
            throw NetworkError.invalidURL
        }

        var request = URLRequest(url: url)

        request.setValue(
            "https://character.ai",
            forHTTPHeaderField: "Origin"
        )

        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        request.setValue(
            "Token \(sessionToken)",
            forHTTPHeaderField: "Authorization"
        )

        let task = session.webSocketTask(with: request)

        webSocketTask = task

        task.resume()

        isConnected = true

    }
    
    func receive() async throws -> String {
        guard let webSocketTask else {
            throw NetworkError.invalidResponse
        }

        do {
            let message = try await webSocketTask.receive()

            switch message {
            case .string(let text):
                return text

            case .data(let data):
                guard let text = String(data: data, encoding: .utf8) else {
                    throw NetworkError.decodingError(
                        NSError(
                            domain: "WebSocketClient",
                            code: 1,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Received WebSocket data that was not valid UTF-8."
                            ]
                        )
                    )
                }

                return text

            @unknown default:
                throw NetworkError.invalidResponse
            }

        } catch {
            webSocketTask.cancel(
                with: .abnormalClosure,
                reason: nil
            )

            self.webSocketTask = nil
            isConnected = false

            webSocketLogger.error("WebSocket receive failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    func disconnect() {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        isConnected = false

    }
    
    func send(_ message: String) async throws {
        guard let webSocketTask else {
            throw NetworkError.invalidResponse
        }

        try await webSocketTask.send(.string(message))
    }
}
