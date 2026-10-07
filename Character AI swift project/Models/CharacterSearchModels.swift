//
//  CharacterSearchModels.swift
//  Character AI swift project
//
//  Typed models for character search, decoded strictly from the captured
//  contract in Docs/CharacterSearchProtocol.md (HAR-verified 2026-10-01).
//

import Foundation

// MARK: - Autocomplete (works with the app's existing Token auth)

nonisolated struct SearchAutocompleteResponse: Decodable, Sendable {
    let searchAutocomplete: [String]

    private enum CodingKeys: String, CodingKey {
        case searchAutocomplete = "search_autocomplete"
    }
}

// MARK: - tRPC batch envelope
//
// The results endpoint replies `[ { "result": { "data": { "json": … } } } ]`
// on success, or `[ { "error": { "json": … } } ]` on failure (observed as
// HTTP 500 wrapping an upstream 401 — see the protocol doc §1 and §4).

nonisolated struct TRPCBatchResponse<Payload: Decodable & Sendable>: Decodable, Sendable {
    nonisolated struct Entry: Decodable, Sendable {
        nonisolated struct ResultBody: Decodable, Sendable {
            nonisolated struct DataBody: Decodable, Sendable {
                let json: Payload
            }

            let data: DataBody
        }

        /// tRPC error entries wrap their body in a `json` key:
        /// `{"error":{"json":{"message":…,"code":…}}}` (doc §4).
        nonisolated struct ErrorBody: Decodable, Sendable {
            nonisolated struct JsonBody: Decodable, Sendable {
                let message: String?
                let code: Int?
            }

            let json: JsonBody?
        }

        let result: ResultBody?
        let error: ErrorBody?
    }

    let entries: [Entry]

    init(from decoder: Decoder) throws {
        entries = try decoder.singleValueContainer().decode([Entry].self)
    }
}

// MARK: - Results payload

nonisolated struct SearchResultsPayload: Decodable, Sendable {
    let characters: [CharacterSearchResult]
    let uuid: String?
    let nextCursor: String?
    let safetyFiltered: Bool?

    private enum CodingKeys: String, CodingKey {
        case characters
        case uuid
        case nextCursor
        case safetyFiltered
    }

    // Tolerant decoding: unknown payload keys (e.g. `tags`, `adsContext`,
    // whose shapes were never captured) are ignored by keyed decoding rather
    // than guessed at.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        characters = try container.decodeIfPresent(
            [CharacterSearchResult].self,
            forKey: .characters
        ) ?? []

        uuid = try container.decodeIfPresent(String.self, forKey: .uuid)
        // Opaque pagination cursor — decoded but deliberately unused: the
        // page-2 input shape was never captured (protocol doc §6).
        nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)

        // This API family uses both Bool and Int 0/1 for flags across hosts.
        if let bool = try? container.decodeIfPresent(Bool.self, forKey: .safetyFiltered) {
            safetyFiltered = bool
        } else if let int = try? container.decodeIfPresent(Int.self, forKey: .safetyFiltered) {
            safetyFiltered = int != 0
        } else {
            safetyFiltered = nil
        }
    }
}

// MARK: - Character search result (minimal card subset, protocol doc §5)

nonisolated struct CharacterSearchResult: Decodable, Sendable {
    let externalID: String?
    let name: String?
    let title: String?
    let description: String?
    let avatarFileName: String?
    let interactionCount: Int?
    let creatorUsername: String?
    let tagLabel: String?

    private enum CodingKeys: String, CodingKey {
        case externalID = "external_id"
        case name
        case title
        case description
        case avatarFileName = "avatar_file_name"
        case interactionCount = "participant__num_interactions"
        case creatorUsername = "user__username"
        case tagLabel = "tag_v2"
    }
}
