import Foundation
import Synchronization

nonisolated private struct DecodeProbe: Decodable, Sendable {
    let value: Int
    init(from decoder: Decoder) throws {
        precondition(!Thread.isMainThread, "HTTP decoding ran on the UI thread")
        value = try decoder.singleValueContainer().decode(Int.self)
    }
}

private actor FakeSocket: WebSocketTransport {
    private let frames: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var iterator: AsyncThrowingStream<Data, Error>.Iterator
    var failSend = false
    var connects = 0

    init() {
        let (frames, continuation) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        self.frames = frames
        self.continuation = continuation
        iterator = frames.makeAsyncIterator()
    }
    func connect(sessionToken: String) { connects += 1 }
    func receive() async throws -> Data {
        // Only the router calls this method, once at a time.
        var iterator = self.iterator
        guard let value = try await iterator.next(isolation: self) else { throw URLError(.networkConnectionLost) }
        self.iterator = iterator
        return value
    }
    func send(_ message: String) throws { if failSend { throw URLError(.networkConnectionLost) } }
    func disconnect() { continuation.finish() }
    func emit(id: String, command: String) {
        continuation.yield(Data("{\"command\":\"\(command)\",\"request_id\":\"\(id)\"}".utf8))
    }
    func setSendFailure() { failSend = true }
}

@main
struct ReliabilityChecks {
    @MainActor static func main() async throws {
        let probe = try await HTTPResponseDecoder.decode(DecodeProbe.self, from: Data("42".utf8))
        precondition(probe.value == 42)
        let cancelled = Task {
            try await Task.sleep(for: .seconds(1))
            return try await HTTPResponseDecoder.decode(DecodeProbe.self, from: Data("42".utf8))
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("Cancellation lost") }
        catch is CancellationError {}

        let socket = FakeSocket()
        let router = WebSocketRouter(client: socket)
        try await router.connect(sessionToken: "synthetic-test-token")
        let pin = try router.responses(for: "pin", timeout: .seconds(1))
        let create = try router.responses(for: "create", timeout: .seconds(1))
        let generation = try router.responses(for: "generation", timeout: .seconds(1))
        await socket.emit(id: "generation", command: "update_turn")
        await socket.emit(id: "pin", command: "neo_error")
        await socket.emit(id: "unrelated", command: "ignored")
        await socket.emit(id: "create", command: "create_chat")
        var pinIterator = pin.makeAsyncIterator()
        var createIterator = create.makeAsyncIterator()
        var generationIterator = generation.makeAsyncIterator()
        let pinResponse = try await pinIterator.next()
        let createResponse = try await createIterator.next()
        let generationResponse = try await generationIterator.next()
        precondition(pinResponse?.requestID == "pin")
        precondition(createResponse?.requestID == "create")
        precondition(generationResponse?.requestID == "generation")
        router.finish("pin"); router.finish("create"); router.finish("generation")

        let timeout = try router.responses(for: "missing", timeout: .milliseconds(25))
        var timeoutIterator = timeout.makeAsyncIterator()
        do { _ = try await timeoutIterator.next(); preconditionFailure("Missing ACK did not time out") }
        catch let error as URLError { precondition(error.code == .timedOut) }
        // A late ACK cannot resume the old waiter; its ID can be registered again.
        await socket.emit(id: "missing", command: "update_turn")
        let reRegistered = try router.responses(for: "missing", timeout: .seconds(1))
        router.finish("missing")
        _ = reRegistered

        let failed = try router.responses(for: "send-failure")
        await socket.setSendFailure()
        do { try await router.send("{}"); preconditionFailure("Send failure swallowed") } catch {}
        var failedIterator = failed.makeAsyncIterator()
        do { _ = try await failedIterator.next(); preconditionFailure("Pending operation survived failure") } catch {}
        router.disconnect()
        print("HTTP executor/cancellation and WebSocket routing/timeout/failure checks passed")
        try await runConversationChecks()
        try await runFilteredResponseChecks()
        try await runHTTPChecks()
        try await runImageChecks()
        try runRenderingChecks()
        runWindowSurfaceChecks()
        try await runProviderChecks()
        try await runPersonaChecks()
    }
}
