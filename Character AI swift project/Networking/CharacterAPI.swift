import Foundation

struct CharacterAPI {
    private let httpClient: HTTPClient

    init(httpClient: HTTPClient = HTTPClient()) {
        self.httpClient = httpClient
    }

    func getCharacterInfo(
        externalID: String,
        language: String = "en"
    ) async throws -> Character {
        guard let url = URL(
            string: "https://neo.character.ai/character/v1/get_character_info"
        ) else {
            throw NetworkError.invalidURL
        }

        let requestBody = GetCharacterInfoRequest(
            externalID: externalID,
            language: language
        )

        let response: CharacterResponse = try await httpClient.post(
            url,
            body: requestBody
        )

        return response.character
    }
}

private struct GetCharacterInfoRequest: Encodable {
    let externalID: String
    let language: String

    enum CodingKeys: String, CodingKey {
        case externalID = "external_id"
        case language = "lang"
    }
}

nonisolated private struct CharacterResponse: Decodable, Sendable {
    let character: Character
}
