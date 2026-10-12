import Foundation

/// Authenticated responses stay in memory. Endpoint changes must be reviewed,
/// not followed with a session token attached.
nonisolated final class CharacterAIRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

nonisolated enum CharacterAISession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: CharacterAIRedirectPolicy(), delegateQueue: nil)
    }()

    static func allowsAuthentication(to url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        return ["character.ai", "neo.character.ai", "plus.character.ai",
                "feed.api.character.ai", "subscription.api.character.ai"].contains(url.host ?? "")
    }
}
