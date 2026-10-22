import AppKit
import Foundation

@MainActor
final class LocalOllamaLifecycle {
    static let shared = LocalOllamaLifecycle()

    private var stopLaunchedOllama: (@MainActor () -> Void)?

    func recordLaunch(stop: @escaping @MainActor () -> Void) {
        stopLaunchedOllama = stop
    }

    func applicationWillTerminate() {
        let stop = stopLaunchedOllama
        stopLaunchedOllama = nil
        stop?()
    }
}

struct LocalOllamaService {
    let baseURL: URL
    private let session: URLSession
    private let launchApplication: @MainActor () async throws -> Void
    private let waitForStartup: @Sendable (Duration) async throws -> Void
    private let startsApplicationWhenUnavailable: Bool

    init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!, session: URLSession = .shared,
         startsApplicationWhenUnavailable: Bool = true,
         launchApplication: @escaping @MainActor () async throws -> Void = LocalOllamaService.launchOllama,
         waitForStartup: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) throws {
        guard baseURL.scheme == "http",
              ["127.0.0.1", "localhost", "::1"].contains(baseURL.host ?? "") else {
            throw LocalOllamaError.nonLoopbackURL
        }
        self.baseURL = baseURL
        self.session = session
        self.startsApplicationWhenUnavailable = startsApplicationWhenUnavailable
        self.launchApplication = launchApplication
        self.waitForStartup = waitForStartup
    }

    func models() async throws -> [String] {
        do { return try await fetchModels() }
        catch LocalOllamaError.unavailable {
            guard startsApplicationWhenUnavailable else { throw LocalOllamaError.unavailable }
            try await launchApplication()
            for _ in 0..<40 {
                try Task.checkCancellation()
                do { return try await fetchModels() }
                catch LocalOllamaError.unavailable { try await waitForStartup(.milliseconds(500)) }
            }
            throw LocalOllamaError.startupTimedOut
        }
    }

    private func fetchModels() async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 2
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw LocalOllamaError.unavailable
            }
            let result = try JSONDecoder().decode(OllamaModelsResponse.self, from: data)
            return result.models.map(\.name).sorted()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LocalOllamaError {
            throw error
        } catch {
            try Task.checkCancellation()
            throw LocalOllamaError.unavailable
        }
    }

    @MainActor
    private static func launchOllama() async throws {
        let bundleID = "com.electron.ollama"
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw LocalOllamaError.notInstalled
        }
        let wasAlreadyRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) { runningApp, error in
                if let error {
                    continuation.resume(throwing: LocalOllamaError.launchFailed(error.localizedDescription))
                } else {
                    if !wasAlreadyRunning, let runningApp {
                        Task { @MainActor in
                            LocalOllamaLifecycle.shared.recordLaunch {
                                runningApp.terminate()
                            }
                        }
                    }
                    continuation.resume()
                }
            }
        }
    }

    func reply(model: String, character: LocalCharacter, messages: [LocalChatMessage]) async throws -> String {
        let history = messages.suffix(24).map { message in
            OllamaMessage(role: message.role, content: message.content)
        }
        let body = OllamaChatRequest(
            model: model,
            messages: [OllamaMessage(role: "system", content: character.characterPrompt)] + history,
            stream: false
        )
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalOllamaError.unavailable }
        guard (200..<300).contains(http.statusCode) else {
            throw LocalOllamaError.serverRejected(http.statusCode)
        }
        let result = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
        let content = result.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw LocalCharacterLibraryError.responseWasEmpty }
        return content
    }
}

private struct OllamaModelsResponse: Decodable {
    let models: [OllamaModel]
}

private struct OllamaModel: Decodable {
    let name: String
}

private struct OllamaChatRequest: Encodable {
    let model: String
    let messages: [OllamaMessage]
    let stream: Bool
}

private struct OllamaMessage: Codable {
    let role: String
    let content: String
}

private struct OllamaChatResponse: Decodable {
    let message: OllamaMessage
}

enum LocalOllamaError: LocalizedError {
    case nonLoopbackURL
    case unavailable
    case notInstalled
    case launchFailed(String)
    case startupTimedOut
    case noModels
    case serverRejected(Int)
    case modelMissing

    var errorDescription: String? {
        switch self {
        case .nonLoopbackURL: "Local chat only connects to an Ollama server on this Mac."
        case .unavailable: "Ollama is unavailable."
        case .notInstalled: "Ollama is not installed. Install it, then try again."
        case .launchFailed(let reason): "Could not open Ollama: \(reason)"
        case .startupTimedOut: "Ollama opened but did not become ready. Try again."
        case .noModels: "No Ollama models are installed."
        case .serverRejected(let status): "Ollama rejected the request (HTTP \(status))."
        case .modelMissing: "Choose an installed Ollama model first."
        }
    }
}
