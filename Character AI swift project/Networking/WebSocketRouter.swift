import Foundation
import OSLog

/// MainActor owns routing state, not JSON decoding or the socket transport.
/// Register before sending so an immediate response cannot precede its waiter.
@MainActor
final class WebSocketRouter {
    private static let logger = Logger(subsystem: "CharacterAI", category: "WebSocketRouter")

    private struct Pending {
        let id: UUID
        let continuation: AsyncThrowingStream<WebSocketTurnResponse, Error>.Continuation
        let timeout: Task<Void, Never>?
    }

    private let client: any WebSocketTransport
    private var pending: [String: Pending] = [:]
    private var receiveTask: Task<Void, Never>?
    private var closingTask: Task<Void, Never>?
    private var generation = UUID()

    init(client: any WebSocketTransport = WebSocketClient()) { self.client = client }

    func connect(sessionToken: String) async throws {
        let expectedGeneration = generation
        await closingTask?.value
        guard generation == expectedGeneration else { throw CancellationError() }
        closingTask = nil
        try await client.connect(sessionToken: sessionToken)
        guard generation == expectedGeneration else { throw CancellationError() }
        guard receiveTask == nil else { return }
        let generation = self.generation
        let client = client
        receiveTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let data = try await client.receive()
                    let response: WebSocketTurnResponse
                    do {
                        response = try await WebSocketMessageProcessor.shared.decode(data)
                    } catch {
                        // One unparseable frame is a protocol failure for the
                        // operations awaiting responses — surfaced as an error,
                        // never as a valid turn — but it must not tear down the
                        // socket and routing for every other pending operation.
                        Self.logger.error("Undecodable WebSocket frame")
                        self?.failPendingOperations(NetworkError.decodingError(error), generation: generation)
                        continue
                    }
                    guard !Task.isCancelled else { return }
                    self?.route(response, generation: generation)
                }
            } catch {
                self?.failed(error, generation: generation)
            }
        }
    }

    func responses(for requestID: String, timeout: Duration? = nil) throws
        -> AsyncThrowingStream<WebSocketTurnResponse, Error> {
        guard pending[requestID] == nil, pending.count < 16 else {
            throw NetworkError.serverMessage("Too many pending WebSocket operations.")
        }
        let (stream, continuation) = AsyncThrowingStream<WebSocketTurnResponse, Error>
            .makeStream(bufferingPolicy: .bufferingOldest(64))
        let operationID = UUID()
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard self?.pending[requestID]?.id == operationID else { return }
                self?.finish(requestID)
            }
        }
        let timeoutTask = timeout.map { duration in
            Task { [weak self] in
                do { try await Task.sleep(for: duration) } catch { return }
                guard self?.pending[requestID]?.id == operationID else { return }
                self?.finish(requestID, error: URLError(.timedOut))
            }
        }
        pending[requestID] = Pending(id: operationID, continuation: continuation, timeout: timeoutTask)
        return stream
    }

    func send(_ message: String) async throws {
        let generation = self.generation
        do { try await client.send(message) }
        catch {
            failed(error, generation: generation)
            throw error
        }
    }

    func finish(_ requestID: String, error: Error? = nil) {
        guard let operation = pending.removeValue(forKey: requestID) else { return }
        operation.timeout?.cancel()
        if let error { operation.continuation.finish(throwing: error) }
        else { operation.continuation.finish() }
    }

    private func route(_ response: WebSocketTurnResponse, generation: UUID) {
        guard generation == self.generation,
              let requestID = response.requestID,
              let operation = pending[requestID] else { return }
        if case .dropped = operation.continuation.yield(response) {
            // Never silently discard final/error frames or grow an unbounded queue.
            finish(response.requestID ?? "", error: NetworkError.serverMessage("WebSocket response buffer overflowed."))
        }
    }

    /// Fails every pending operation with the given error while keeping the
    /// connection and receive loop alive.
    private func failPendingOperations(_ error: Error, generation: UUID) {
        guard generation == self.generation else { return }
        for id in Array(pending.keys) { finish(id, error: error) }
    }

    private func failed(_ error: Error, generation: UUID) {
        guard generation == self.generation else { return }
        self.generation = UUID()
        receiveTask?.cancel()
        receiveTask = nil
        for id in Array(pending.keys) { finish(id, error: error) }
        let client = client
        closingTask = Task { await client.disconnect() }
    }

    func disconnect() {
        generation = UUID()
        receiveTask?.cancel()
        receiveTask = nil
        for id in Array(pending.keys) { finish(id, error: CancellationError()) }
        let client = client
        closingTask = Task { await client.disconnect() }
    }

    deinit {
        receiveTask?.cancel()
        let client = client
        Task { await client.disconnect() }
    }
}
