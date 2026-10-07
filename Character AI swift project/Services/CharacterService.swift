import Foundation

struct CharacterService {
    private let httpClient: AuthenticatedHTTPClient

    init(httpClient: AuthenticatedHTTPClient) {
        self.httpClient = httpClient
    }

    func loadProfile(externalID: String, language: String = "en", forceRefresh: Bool = false) async throws -> CharacterProfile {
        try await httpClient.resources.value(for: "profile:\(language):\(externalID)", ttl: 300,
                                              forceRefresh: forceRefresh, cost: { profile in
            2048 + [profile.description, profile.greeting].compactMap { $0 }.reduce(0) { $0 + $1.utf8.count * 4 }
                + (profile.additionalGreetings ?? []).reduce(0) { $0 + $1.utf8.count * 4 }
        }) {
            try await fetchProfile(externalID: externalID, language: language)
        }
    }

    func cachedProfile(externalID: String, language: String = "en") -> CharacterProfile? {
        httpClient.resources.cached("profile:\(language):\(externalID)", as: CharacterProfile.self, maxAge: 900)
    }

    private func fetchProfile(externalID: String, language: String) async throws -> CharacterProfile {
        guard let url = URL(string: "https://neo.character.ai/character/v1/get_character_info") else {
            throw NetworkError.invalidURL
        }

        let response: CharacterProfileResponse = try await httpClient.post(
            url,
            body: CharacterProfileRequest(externalID: externalID, language: language)
        )
        return response.character
    }

    func loadSimilarCharacters(externalID: String) async throws -> [SimilarCharacter] {
        try await httpClient.resources.value(for: "similar:\(externalID)", ttl: 300, cost: { $0.reduce(256) { $0 + 1024 + ($1.description?.utf8.count ?? 0) * 4 } }) {
            try await fetchSimilarCharacters(externalID: externalID)
        }
    }

    private func fetchSimilarCharacters(externalID: String) async throws -> [SimilarCharacter] {
        let allowedPathCharacters = CharacterSet.urlPathAllowed.subtracting(
            CharacterSet(charactersIn: "/?#")
        )
        let encodedID = externalID.addingPercentEncoding(
            withAllowedCharacters: allowedPathCharacters
        ) ?? externalID

        guard let url = URL(string: "https://neo.character.ai/recommendation/v1/character/similar/\(encodedID)") else {
            throw NetworkError.invalidURL
        }

        let response: SimilarCharactersResponse = try await httpClient.get(url)
        return response.characters
    }
}

private struct CharacterProfileRequest: Encodable {
    let externalID: String
    let language: String

    enum CodingKeys: String, CodingKey {
        case externalID = "external_id"
        case language = "lang"
    }
}
