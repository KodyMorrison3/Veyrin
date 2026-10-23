import Foundation

nonisolated protocol ProviderHTTPTransport: Sendable {
    func consume(_ request: URLRequest,
                 receive: @escaping @Sendable (Data) async throws -> Void) async throws
}

nonisolated struct ProviderHTTPClient: ProviderHTTPTransport {
    // Tests inject URLProtocol through this factory, not URLSession.AsyncBytes.
    // A dedicated delegate/session per request makes cancellation ownership explicit.
    let configuration: @Sendable () -> URLSessionConfiguration

    init(configuration: @escaping @Sendable () -> URLSessionConfiguration = {
        let value = URLSessionConfiguration.ephemeral
        value.urlCache = nil
        value.httpCookieStorage = nil
        value.httpShouldSetCookies = false
        value.urlCredentialStorage = nil
        value.requestCachePolicy = .reloadIgnoringLocalCacheData
        value.timeoutIntervalForResource = 300
        return value
    }) {
        self.configuration = configuration
    }

    func consume(_ request: URLRequest,
                 receive: @escaping @Sendable (Data) async throws -> Void) async throws {
        let pair = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        let delegate = ProviderHTTPDelegate(output: pair.continuation)
        let session = URLSession(configuration: configuration(), delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        pair.continuation.onTermination = { @Sendable _ in task.cancel() }
        defer { task.cancel(); session.invalidateAndCancel() }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            task.resume()
            do {
                for try await data in pair.stream {
                    try Task.checkCancellation()
                    try await receive(data)
                }
                try Task.checkCancellation()
            } catch {
                try Task.checkCancellation()
                if let error = error as? ProviderError { throw error }
                throw ProviderError.unavailable
            }
        } onCancel: {
            task.cancel()
        }
    }
}

nonisolated private final class ProviderHTTPDelegate: NSObject, URLSessionDataDelegate, Sendable {
    let output: AsyncThrowingStream<Data, Error>.Continuation

    init(output: AsyncThrowingStream<Data, Error>.Continuation) { self.output = output }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            output.finish(throwing: ProviderError.invalidResponse)
            completionHandler(.cancel)
            return
        }
        guard (200..<300).contains(response.statusCode) else {
            let error: ProviderError
            switch response.statusCode {
            case 401: error = .authentication
            case 403: error = .forbidden
            case 404: error = .missingModel
            case 429: error = .rateLimited
            default: error = .rejected(response.statusCode)
            }
            // Never surface arbitrary response/error text (it may echo the key or prompt).
            output.finish(throwing: error)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // Split large URLSession callbacks to keep the queue bound meaningful.
        for offset in stride(from: 0, to: data.count, by: 16 * 1024) {
            let chunk = data.subdata(in: offset..<min(offset + 16 * 1024, data.count))
            if case .dropped = output.yield(chunk) {
                output.finish(throwing: ProviderError.responseTooLarge)
                dataTask.cancel()
                return
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil { output.finish(throwing: ProviderError.unavailable) }
        else { output.finish() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor ProviderDataBuffer {
    private var data = Data()
    func append(_ chunk: Data) throws {
        guard data.count + chunk.count <= 8 * 1024 * 1024 else { throw ProviderError.responseTooLarge }
        data.append(chunk)
    }
    func value() -> Data { data }
}

extension ProviderHTTPTransport {
    func data(_ request: URLRequest) async throws -> Data {
        let buffer = ProviderDataBuffer()
        try await consume(request) { try await buffer.append($0) }
        return await buffer.value()
    }
}
