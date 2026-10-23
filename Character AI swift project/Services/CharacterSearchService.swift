//
//  CharacterSearchService.swift
//  Character AI swift project
//
//  Search service mirroring DiscoverService's shape.
//
//  Two endpoints, very different auth stories:
//  - Autocomplete on `neo.` works today with the app's `Token` auth.
//  - The results endpoint (`character.ai/api/trpc/search.search`) requires a
//    browser-only `web-next-auth` cookie. The app never obtains that cookie
//    itself; the user may paste one, which is stored in the Keychain and sent
//    only to `character.ai`. Without it, the endpoint's HTTP 500 wrapping an
//    upstream 401 is mapped to `SearchError.resultsRequireWebSession`; with a
//    cookie that is refused, it maps to `SearchError.webSessionRejected`.
//    No credential is reproduced, fetched or refreshed by the app.
//

import Foundation

enum SearchError: LocalizedError {
    /// The results endpoint needs a web-session cookie and none is saved.
    case resultsRequireWebSession
    /// A saved web-session cookie was refused (usually expired or revoked).
    case webSessionRejected

    var errorDescription: String? {
        switch self {
        case .resultsRequireWebSession:
            return
                "Character search needs a web session cookie. Add it in Preferences → Account."
        case .webSessionRejected:
            return
                "Character.AI rejected the saved web session cookie. It may have expired — update it in Preferences → Account."
        }
    }
}

struct CharacterSearchService {
    private let session: URLSession
    private let authorizationProvider: DiscoverService.AuthorizationProvider
    private let webSessionCookieProvider: () -> String?

    init(
        session: URLSession = CharacterAISession.shared,
        authStore: AuthStore
    ) {
        self.session = session
        self.authorizationProvider = .authStore(authStore)
        self.webSessionCookieProvider = { authStore.webSessionCookie() }
    }

    #if DEBUG
    /// Test-only fixed providers. Production code should use the `authStore`
    /// initializer; contract tests must not touch the Keychain.
    init(
        session: URLSession = CharacterAISession.shared,
        fixedToken: String,
        webSessionCookie: String? = nil
    ) {
        self.session = session
        self.authorizationProvider = .fixedToken(fixedToken)
        let normalized = webSessionCookie.flatMap {
            try? WebSessionCookie.normalizedHeader(from: $0)
        }
        self.webSessionCookieProvider = { normalized }
    }
    #endif

    // MARK: - Autocomplete (live today)

    func fetchAutocomplete(queryPrefix: String) async throws -> [String] {
        var components = URLComponents(
            string: "https://neo.character.ai/search/v1/query/autocomplete"
        )
        components?.queryItems = [
            URLQueryItem(name: "query_prefix", value: queryPrefix)
        ]

        guard let url = components?.url else {
            throw NetworkError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try await addAuthentication(to: &request)

        let data = try await responseData(for: request)

        return try await HTTPResponseDecoder.decode(SearchAutocompleteResponse.self, from: data)
            .searchAutocomplete
    }

    // MARK: - Results (needs a user-supplied web-session cookie)

    func searchCharacters(query: String) async throws -> [CharacterSearchResult] {
        guard let url = Self.resultsURL(query: query) else {
            throw NetworkError.invalidURL
        }

        let webSessionCookie = webSessionCookieProvider()

        var request = URLRequest(url: url)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if let webSessionCookie {
            // Match the browser request this endpoint serves: the cookie is
            // the credential, so do not also present the native Token header.
            // This cookie is never attached to neo.character.ai or a provider.
            request.setValue(webSessionCookie, forHTTPHeaderField: "Cookie")
            request.setValue("https://character.ai", forHTTPHeaderField: "Origin")
            request.setValue("https://character.ai/", forHTTPHeaderField: "Referer")
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Safari/537.36",
                forHTTPHeaderField: "User-Agent"
            )
        } else {
            try await addAuthentication(to: &request)
        }

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.invalidResponse
            }

            // The known signature: gateway HTTP 500 wrapping upstream 401.
            // Without a cookie this is the documented web-session requirement;
            // with one it means the credential was refused. Anything else stays
            // a NetworkError.
            if httpResponse.statusCode == 500,
               let batch = try? await HTTPResponseDecoder.decode(
                    TRPCBatchResponse<SearchResultsPayload>.self,
                    from: data
               ),
               batch.entries.contains(where: { $0.error != nil }) {
                throw webSessionCookie == nil
                    ? SearchError.resultsRequireWebSession
                    : SearchError.webSessionRejected
            }

            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403,
               webSessionCookie != nil {
                throw SearchError.webSessionRejected
            }

            guard 200..<300 ~= httpResponse.statusCode else {
                throw NetworkError.httpError(httpResponse.statusCode)
            }

            let batch: TRPCBatchResponse<SearchResultsPayload>
            batch = try await HTTPResponseDecoder.decode(
                TRPCBatchResponse<SearchResultsPayload>.self,
                from: data
            )

            guard let entry = batch.entries.first else {
                throw NetworkError.invalidResponse
            }
            if entry.error != nil {
                if webSessionCookie != nil {
                    throw SearchError.webSessionRejected
                }
                throw NetworkError.serverMessage(
                    "Character.AI rejected the search request."
                )
            }
            guard let result = entry.result else {
                throw NetworkError.invalidResponse
            }
            return result.data.json.characters
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NetworkError {
            throw error
        } catch let error as SearchError {
            throw error
        } catch {
            try Task.checkCancellation()
            throw NetworkError.requestFailed(error)
        }
    }

    /// Builds the exact captured request URL: a tRPC batch
    /// GET with the superjson-style `input` envelope. Page 1 only — the
    /// page-2 `cursor` input shape was never captured, so pagination is
    /// deliberately not attempted.
    static func resultsURL(query: String) -> URL? {
        let input = """
        {"0":{"json":{"searchQuery":"\(Self.escapedJSON(query))","tagId":null,"sortedBy":"relevance","filters":null,"direction":"forward"},"meta":{"values":{"tagId":["undefined"],"filters":["undefined"]},"v":1}}}
        """

        var components = URLComponents(
            string: "https://character.ai/api/trpc/search.search"
        )
        components?.queryItems = [
            URLQueryItem(name: "batch", value: "1"),
            URLQueryItem(name: "input", value: input),
        ]
        return components?.url
    }

    private static func escapedJSON(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            default:
                if scalar.value < 0x20 {
                    escaped += String(format: "\\u%04x", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return escaped
    }

    private func addAuthentication(to request: inout URLRequest) async throws {
        guard let token = await authorizationProvider.token else {
            throw NetworkError.unauthenticated
        }

        request.setValue(
            "Token \(token)",
            forHTTPHeaderField: "Authorization"
        )
    }

    private func responseData(for request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.invalidResponse
            }

            guard 200..<300 ~= httpResponse.statusCode else {
                throw NetworkError.httpError(httpResponse.statusCode)
            }

            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NetworkError {
            throw error
        } catch {
            try Task.checkCancellation()
            throw NetworkError.requestFailed(error)
        }
    }
}
