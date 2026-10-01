import Foundation

struct CharacterService {
    private let httpClient: AuthenticatedHTTPClient

    init(httpClient: AuthenticatedHTTPClient) {
        self.httpClient = httpClient
    }

    func loadProfile(
        externalID: String,
        language: String = "en"
    ) async throws -> CharacterProfile {
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
