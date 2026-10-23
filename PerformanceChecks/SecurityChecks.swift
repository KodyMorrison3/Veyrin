import Foundation

nonisolated enum SecurityChecks {
    static func run() {
        let allowedHosts = [
            "character.ai",
            "neo.character.ai",
            "plus.character.ai",
            "feed.api.character.ai",
            "subscription.api.character.ai"
        ]
        for host in allowedHosts {
            precondition(CharacterAISession.allowsAuthentication(to: URL(string: "https://\(host)/")))
            precondition(CharacterAISession.allowsAuthentication(to: URL(string: "https://\(host):443/")))
        }
        precondition(!CharacterAISession.allowsAuthentication(to: nil))
        precondition(!CharacterAISession.allowsAuthentication(to: URL(string: "http://character.ai/")))
        precondition(!CharacterAISession.allowsAuthentication(to: URL(string: "https://example.com/")))
        precondition(!CharacterAISession.allowsAuthentication(to: URL(string: "https://character.ai:444/")))
        precondition(!CharacterAISession.allowsAuthentication(to: URL(string: "https://user:password@character.ai/")))
        precondition(!CharacterAISession.allowsAuthentication(to: URL(string: "https://character.ai@evil.example/")))

        let redirectPolicy = CharacterAIRedirectPolicy()
        let url = URL(string: "https://character.ai/")!
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": "https://example.com/"])!
        let request = URLRequest(url: URL(string: "https://example.com/")!)
        var redirectedRequest: URLRequest? = request
        redirectPolicy.urlSession(URLSession.shared, task: URLSession.shared.dataTask(with: url),
                                  willPerformHTTPRedirection: response, newRequest: request) {
            redirectedRequest = $0
        }
        precondition(redirectedRequest == nil)

        let rawServerText = "private-server-detail"
        let rawTransportText = "private-transport-detail"
        let errors: [NetworkError] = [
            .httpError(503),
            .requestFailed(NSError(domain: rawTransportText, code: 1)),
            .decodingError(NSError(domain: rawServerText, code: 2))
        ]
        for error in errors {
            let description = error.localizedDescription
            precondition(!description.contains(rawServerText))
            precondition(!description.contains(rawTransportText))
        }
        print("PASS authenticated URL allowlist, redirect refusal, and safe network error descriptions")
    }
}
