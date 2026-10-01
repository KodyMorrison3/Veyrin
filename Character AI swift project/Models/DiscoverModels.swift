import Foundation

struct DiscoverFeedRequest: Encodable {
    struct Options: Encodable {
        let componentTypes: [Int]

        enum CodingKeys: String, CodingKey {
            case componentTypes = "component_types"
        }
    }

    let pageSize: Int
    let options: Options
    let cursor: String?

    init(cursor: String?) {
        pageSize = 10
        options = Options(componentTypes: [3, 7, 8, 9, 10, 11])
        self.cursor = cursor
    }

    enum CodingKeys: String, CodingKey {
        case pageSize = "page_size"
        case options
        case cursor
    }
}

struct DiscoverFeedResponse: Decodable {
    let uuid: String?
    let title: String?
    let contents: [DiscoverFeedItem]
    let nextCursor: String?
    let feedItemCount: Int?

    enum CodingKeys: String, CodingKey {
        case uuid
        case title
        case contents
        case nextCursor = "next_cursor"
        case feedItemCount = "feed_item_count"
    }
}

struct DiscoverFeedItem: Decodable {
    let itemID: String?
    let componentType: Int?
    let size: Int?
    let retrievalChannel: String?
    let characterItem: DiscoverFeedCharacter?

    enum CodingKeys: String, CodingKey {
        case itemID = "item_id"
        case componentType = "component_type"
        case size
        case retrievalChannel = "retrieval_channel"
        case characterItem = "character_item"
    }
}

struct DiscoverFeedCharacter: Decodable {
    let externalID: String?
    let name: String?
    let participantName: String?
    let interactionCount: Int?
    let title: String?
    let description: String?
    let greeting: String?
    let visibility: String?
    let avatarFileName: String?
    let username: String?
    let shortHash: String?

    enum CodingKeys: String, CodingKey {
        case externalID = "external_id"
        case name
        case participantName = "participant__name"
        case interactionCount = "participant__num_interactions"
        case title
        case description
        case greeting
        case visibility
        case avatarFileName = "avatar_file_name"
        case username = "user__username"
        case shortHash = "short_hash"
    }
}

struct CuratedScenesResponse: Decodable {
    let scenes: [CuratedScene]
    let nextCursor: String?
    let version: Int?
    let hasNext: Bool?

    enum CodingKeys: String, CodingKey {
        case scenes
        case nextCursor = "next_cursor"
        case version
        case hasNext = "has_next"
    }
}

struct CuratedScene: Decodable {
    let sceneID: String?
    let title: String?
    let description: String?
    let backgroundImageURL: String?
    let creatorUsername: String?

    enum CodingKeys: String, CodingKey {
        case sceneID = "scene_id"
        case title
        case description
        case backgroundImageURL = "background_image_url"
        case creatorUsername = "creator_username"
    }
}
