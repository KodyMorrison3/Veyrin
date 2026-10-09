//
//  CharacterSearchService.swift
//  Character AI swift project
//
//  Search service mirroring DiscoverService's shape.
//
//  Two endpoints, very different auth stories:
//  - Autocomplete on `neo.` works today with the app's `Token` auth.
//  - The results endpoint (`character.ai/api/trpc/search.search`) requires a
//    browser-only `web-next-auth` cookie. With the app's Token auth it
//    reliably answers HTTP 500 wrapping an upstream 401; that known signature
//    is mapped to `SearchError.resultsRequireWebSession` so the UI can show an
//    honest unavailable state instead of a generic failure. No bypass is
//    attempted — reproducing web credentials is out of scope by design.
//

import Foundation

enum SearchError: LocalizedError {
    /// The results endpoint needs a web-session credential the native client
    /// does not have. This is a known, expected condition — not a bug.
    case resultsRequireWebSession

    var errorDescription: String? {
        switch self {
        case .resultsRequireWebSession:
            return
                "Character search needs a web session — unavailable in the native app yet."
        }
    }
}

struct CharacterSearchService {
    private let session: URLSession
    private let authorizationProvider: DiscoverService.AuthorizationProvider

    init(
        session: URLSession = .shared,
        authStore: AuthStore
    ) {
        self.session = session
        self.authorizationProvider = .authStore(authStore)
    }

    #if DEBUG
    /// Test-only fixed-token provider. Production code should use the
    /// `authStore` initializer; contract tests must not touch the Keychain.
    init(
        session: URLSession = .shared,
        fixedToken: String
    ) {
        self.session = session
        self.authorizationProvider = .fixedToken(fixedToken)
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

    // MARK: - Results (blocked on a web-session credential)

    func searchCharacters(query: String) async throws -> [CharacterSearchResult] {
        guard let url = Self.resultsURL(query: query) else {
            throw NetworkError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        try await addAuthentication(to: &request)

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.invalidResponse
            }

            // The known signature: gateway HTTP 500 wrapping upstream 401.
            // Treat it as the documented web-session requirement, not a crash
            // or a generic server error. Anything else stays a NetworkError.
            if httpResponse.statusCode == 500,
               let batch = try? await HTTPResponseDecoder.decode(
                    TRPCBatchResponse<SearchResultsPayload>.self,
                    from: data
               ),
               batch.entries.contains(where: { $0.error != nil }) {
                throw SearchError.resultsRequireWebSession
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
            if let errorBody = entry.error {
                throw NetworkError.serverMessage(
                    errorBody.json?.message ?? "Search request failed."
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
