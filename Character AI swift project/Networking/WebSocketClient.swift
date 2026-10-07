import Foundation
import OSLog

nonisolated private final class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate, Sendable {
    let event: @Sendable (URLSessionWebSocketTask, Bool, Error?) -> Void

    init(event: @escaping @Sendable (URLSessionWebSocketTask, Bool, Error?) -> Void) {
        self.event = event
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        event(webSocketTask, true, nil)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        event(webSocketTask, false, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let task = task as? URLSessionWebSocketTask else { return }
        event(task, false, error)
    }
}

nonisolated protocol WebSocketTransport: Sendable {
    func connect(sessionToken: String) async throws
    func receive() async throws -> Data
    func send(_ message: String) async throws
    func disconnect() async
}

actor WebSocketClient: WebSocketTransport {
    nonisolated enum State: Sendable {
        case disconnected, connecting, connected, failed, cancelled
    }

    nonisolated private static let logger = Logger(subsystem: "CharacterAI", category: "WebSocket")
    private let session: URLSession
    private var webSocketTask: URLSessionWebSocketTask?
    private var delegate: WebSocketDelegate?
    private var connectionTimeout: Task<Void, Never>?
    private var connectionWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private(set) var state: State = .disconnected
    var isConnected: Bool { state == .connected }

    init(session: URLSession = .shared) {
        self.session = session
    }

    func connect(sessionToken: String) async throws {
        try Task.checkCancellation()
        if state == .connected { return }
        if webSocketTask == nil {
            guard let url = URL(string: "wss://neo.character.ai/ws/") else {
                throw NetworkError.invalidURL
            }
            var request = URLRequest(url: url)
            request.setValue("https://character.ai", forHTTPHeaderField: "Origin")
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Safari/537.36",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue("Token \(sessionToken)", forHTTPHeaderField: "Authorization")
            let task = session.webSocketTask(with: request)
            let delegate = WebSocketDelegate { [weak self] task, opened, error in
                Task { await self?.handleEvent(task: task, opened: opened, error: error) }
            }
            self.delegate = delegate
            task.delegate = delegate
            webSocketTask = task
            state = .connecting
            task.resume()
            connectionTimeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                await self?.fail(task, error: URLError(.timedOut))
            }
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connectionWaiters[waiterID] = continuation
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        connectionWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        if connectionWaiters.isEmpty && state == .connecting { disconnect() }
    }

    private func handleEvent(task: URLSessionWebSocketTask, opened: Bool, error: Error?) {
        guard webSocketTask === task else { return }
        if opened {
            state = .connected
            connectionTimeout?.cancel()
            connectionTimeout = nil
            let waiters = connectionWaiters.values
            connectionWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        } else {
            fail(task, error: error ?? URLError(.networkConnectionLost))
            if error == nil { state = .disconnected }
        }
    }

    private func fail(_ task: URLSessionWebSocketTask, error: Error) {
        // An old suspended send/receive must never tear down a newer connection.
        guard webSocketTask === task else { return }
        task.cancel(with: .abnormalClosure, reason: nil)
        webSocketTask = nil
        delegate = nil
        connectionTimeout?.cancel()
        connectionTimeout = nil
        state = error is CancellationError ? .cancelled : .failed
        let waiters = connectionWaiters.values
        connectionWaiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: error) }
    }

    func receive() async throws -> Data {
        guard let task = webSocketTask, state == .connected else { throw NetworkError.invalidResponse }
        do {
            let message = try await task.receive()
            guard webSocketTask === task else { throw CancellationError() }
            switch message {
            case .string(let text): return Data(text.utf8)
            case .data(let data): return data
            @unknown default: throw NetworkError.invalidResponse
            }
        } catch {
            fail(task, error: error)
            Self.logger.error("WebSocket receive failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }

    func disconnect() {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        delegate = nil
        connectionTimeout?.cancel()
        connectionTimeout = nil
        state = .cancelled
        let waiters = connectionWaiters.values
        connectionWaiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: CancellationError()) }
    }

    func send(_ message: String) async throws {
        guard let task = webSocketTask, state == .connected else { throw NetworkError.invalidResponse }
        do {
            try await task.send(.string(message))
            guard webSocketTask === task else { throw CancellationError() }
        } catch {
            fail(task, error: error)
            throw error
        }
    }
}
