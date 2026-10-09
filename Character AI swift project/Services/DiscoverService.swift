import Foundation

struct DiscoverService {
    private let session: URLSession

    /// Supplies the Character.AI session token for the Authorization header.
    /// Discover only reads the session; it never mutates authentication state.
    enum AuthorizationProvider {
        case authStore(AuthStore)
        case fixedToken(String)

        func cached<Value: Sendable>(key: String, ttl: TimeInterval, forceRefresh: Bool = false,
                                     cost: @escaping (Value) -> Int,
                                     load: @escaping @MainActor () async throws -> Value) async throws -> Value {
            switch self {
            case .authStore(let authStore):
                return try await authStore.resources.value(for: key, ttl: ttl, forceRefresh: forceRefresh, cost: cost, load: load)
            case .fixedToken:
                return try await load()
            }
        }

        var token: String? {
            get async {
                switch self {
                case .authStore(let authStore):
                    // AuthStore is @MainActor; hop over to read the session.
                    return await MainActor.run { authStore.session?.sessionToken }

                case .fixedToken(let token):
                    return token
                }
            }
        }
    }

    private let authorizationProvider: AuthorizationProvider

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
    init(session: URLSession = .shared, fixedToken: String) {
        self.session = session
        self.authorizationProvider = .fixedToken(fixedToken)
    }
    #endif

    func loadRecommendedFeed(cursor: String?, forceRefresh: Bool = false) async throws -> DiscoverFeedResponse {
        // Cache the first page only. Further pages belong to the visible browse session.
        guard cursor == nil else { return try await fetchRecommendedFeed(cursor: cursor) }
        return try await authorizationProvider.cached(key: "discover:recommended", ttl: 60, forceRefresh: forceRefresh,
                                                     cost: { $0.contents.reduce(512) { $0 + 2048 + ($1.characterItem?.description?.utf8.count ?? 0) * 4 } }) {
            try await fetchRecommendedFeed(cursor: nil)
        }
    }

    private func fetchRecommendedFeed(cursor: String?) async throws -> DiscoverFeedResponse {
        guard let url = URL(string: "https://feed.api.character.ai/api/feed/recommended") else {
            throw NetworkError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(DiscoverFeedRequest(cursor: cursor))
        try await addAuthentication(to: &request)

        let data = try await responseData(for: request)

        return try await HTTPResponseDecoder.decode(DiscoverFeedResponse.self, from: data)
    }

    func loadCuratedScenes(cursor: String?, forceRefresh: Bool = false) async throws -> CuratedScenesResponse {
        guard cursor == nil else { return try await fetchCuratedScenes(cursor: cursor) }
        return try await authorizationProvider.cached(key: "discover:scenes", ttl: 300, forceRefresh: forceRefresh,
                                                     cost: { $0.scenes.reduce(512) { $0 + 1024 + ($1.description?.utf8.count ?? 0) * 4 } }) {
            try await fetchCuratedScenes(cursor: nil)
        }
    }

    private func fetchCuratedScenes(cursor: String?) async throws -> CuratedScenesResponse {
        var components = URLComponents(
            string: "https://neo.character.ai/scene/v1/scenes/curated"
        )

        if let cursor {
            components?.queryItems = [
                URLQueryItem(name: "cursor", value: cursor)
            ]
        }

        guard let url = components?.url else {
            throw NetworkError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try await addAuthentication(to: &request)

        let data = try await responseData(for: request)

        return try await HTTPResponseDecoder.decode(CuratedScenesResponse.self, from: data)
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
