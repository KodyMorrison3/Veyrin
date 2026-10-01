import Foundation

struct DiscoverService {
    private let session: URLSession

    /// Supplies the Character.AI session token for the Authorization header.
    /// Discover only reads the session; it never mutates authentication state.
    enum AuthorizationProvider {
        case authStore(AuthStore)
        case fixedToken(String)

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

    func loadRecommendedFeed(cursor: String?) async throws -> DiscoverFeedResponse {
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

        do {
            return try JSONDecoder().decode(DiscoverFeedResponse.self, from: data)
        } catch {
            throw NetworkError.decodingError(error)
        }
    }

    func loadCuratedScenes(cursor: String?) async throws -> CuratedScenesResponse {
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

        do {
            return try JSONDecoder().decode(CuratedScenesResponse.self, from: data)
        } catch {
            throw NetworkError.decodingError(error)
        }
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
        } catch let error as NetworkError {
            throw error
        } catch {
            throw NetworkError.requestFailed(error)
        }
    }
}
