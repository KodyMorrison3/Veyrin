import Foundation

struct FeedService {
    private let session: URLSession
    private let authorizationProvider: AuthorizationProvider

    enum AuthorizationProvider {
        case authStore(AuthStore)
        case fixedToken(String)

        var token: String? {
            get async {
                switch self {
                case .authStore(let authStore):
                    await MainActor.run { authStore.session?.sessionToken }
                case .fixedToken(let token):
                    token
                }
            }
        }
    }

    init(session: URLSession = .shared, authStore: AuthStore) {
        self.session = session
        authorizationProvider = .authStore(authStore)
    }

    #if DEBUG
    init(session: URLSession = .shared, fixedToken: String) {
        self.session = session
        authorizationProvider = .fixedToken(fixedToken)
    }
    #endif

    func loadSocialFeed() async throws -> FeedResponse {
        guard let url = URL(string: "https://feed.api.character.ai/api/feed/social_feed") else {
            throw NetworkError.invalidURL
        }
        guard let token = await authorizationProvider.token else {
            throw NetworkError.unauthenticated
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("https://character.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://character.ai/", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(FeedRequest())

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.invalidResponse
            }
            guard 200..<300 ~= httpResponse.statusCode else {
                throw NetworkError.httpError(httpResponse.statusCode)
            }
            do {
                return try JSONDecoder().decode(FeedResponse.self, from: data)
            } catch {
                throw NetworkError.decodingError(error)
            }
        } catch let error as NetworkError {
            throw error
        } catch {
            throw NetworkError.requestFailed(error)
        }
    }
}
