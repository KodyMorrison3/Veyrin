import Foundation

struct FeedService {
    private let session: URLSession
    private let authorizationProvider: AuthorizationProvider

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

        var authorization: (token: String, generation: UUID?)? {
            get async {
                switch self {
                case .authStore(let authStore):
                    await MainActor.run {
                        guard let session = authStore.session else { return nil }
                        return (session.sessionToken, authStore.sessionGeneration)
                    }
                case .fixedToken(let token):
                    (token, nil)
                }
            }
        }
    }

    init(session: URLSession = CharacterAISession.shared, authStore: AuthStore) {
        self.session = session
        authorizationProvider = .authStore(authStore)
    }

    #if DEBUG
    init(session: URLSession = CharacterAISession.shared, fixedToken: String) {
        self.session = session
        authorizationProvider = .fixedToken(fixedToken)
    }
    #endif

    func loadSocialFeed(forceRefresh: Bool = false) async throws -> FeedResponse {
        let computeCost: (FeedResponse) -> Int = { feed in
            var cost = 512
            for item in feed.contents {
                let textLen = (item.post?.content?.utf8.count ?? 0) + (item.post?.caption?.utf8.count ?? 0)
                cost += 1024 + textLen * 4
            }
            return cost
        }
        return try await authorizationProvider.cached(
            key: "feed:social",
            ttl: 60,
            forceRefresh: forceRefresh,
            cost: computeCost
        ) {
            try await fetchSocialFeed()
        }
    }

    private func fetchSocialFeed() async throws -> FeedResponse {
        guard let url = URL(string: "https://feed.api.character.ai/api/feed/social_feed") else {
            throw NetworkError.invalidURL
        }
        guard let authorization = await authorizationProvider.authorization else {
            throw NetworkError.unauthenticated
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("https://character.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://character.ai/", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Token \(authorization.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(FeedRequest())

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.invalidResponse
            }
            if httpResponse.statusCode == 401 {
                if case .authStore(let authStore) = authorizationProvider,
                   let generation = authorization.generation {
                    authStore.invalidateSession(
                        ifGeneration: generation,
                        authorization: request.value(forHTTPHeaderField: "Authorization")
                    )
                }
                throw NetworkError.unauthenticated
            }
            guard 200..<300 ~= httpResponse.statusCode else {
                throw NetworkError.httpError(httpResponse.statusCode)
            }
            return try await HTTPResponseDecoder.decode(FeedResponse.self, from: data)
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
