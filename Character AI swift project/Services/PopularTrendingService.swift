//
//  PopularTrendingService.swift
//  Character AI swift project
//
//  Loads the curated popular/trending character lists from
//  `neo.character.ai/recommendation/v1/curated_character_lists`, mirroring
//  DiscoverService's shape (same auth provider pattern, same NetworkError
//  mapping). One GET returns both lists; there is no pagination — these are
//  fixed server-curated sets (~25 characters per list).
//

import Foundation

struct PopularTrendingService {
    enum ListID {
        /// "Popular (last 30 days)" — cold-start curated list.
        nonisolated static let popular = "cold_start_popular_characters_l30d_v1"
        /// "Trending" — cold-start curated list.
        nonisolated static let trending = "cold_start_trending_characters_v1"
    }

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

    func loadCuratedLists(popularListID: String = ListID.popular, trendingListID: String = ListID.trending, forceRefresh: Bool = false) async throws -> CuratedCharacterListsResponse {
        try await authorizationProvider.cached(key: "popular-trending:\(popularListID):\(trendingListID)", ttl: 300, forceRefresh: forceRefresh,
                                               cost: { lists in
            lists.curatedCharacterLists.values.reduce(512) { total, list in
                total + list.reduce(0) { $0 + 1024 + ($1.description?.utf8.count ?? 0) * 4 }
            }
        }) {
            try await fetchCuratedLists(popularListID: popularListID, trendingListID: trendingListID)
        }
    }

    private func fetchCuratedLists(popularListID: String, trendingListID: String) async throws -> CuratedCharacterListsResponse {
        var components = URLComponents(
            string: "https://neo.character.ai/recommendation/v1/curated_character_lists"
        )
        // The endpoint requires repeated `list_id` params (live-verified);
        // a request without any answers HTTP 400 invalid request.
        components?.queryItems = [
            URLQueryItem(name: "list_id", value: popularListID),
            URLQueryItem(name: "list_id", value: trendingListID),
        ]

        guard let url = components?.url else {
            throw NetworkError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try await addAuthentication(to: &request)

        let data = try await responseData(for: request)

        return try await HTTPResponseDecoder.decode(CuratedCharacterListsResponse.self, from: data)
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
