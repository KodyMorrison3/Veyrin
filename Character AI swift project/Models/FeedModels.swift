import Foundation

struct FeedRequest: Encodable {
    struct Options: Encodable {
        let componentTypes: [Int]

        enum CodingKeys: String, CodingKey {
            case componentTypes = "component_types"
        }
    }

    let pageSize: Int
    let options: Options

    init() {
        pageSize = 30
        options = Options(componentTypes: [3, 7, 8, 9, 10, 11])
    }

    enum CodingKeys: String, CodingKey {
        case pageSize = "page_size"
        case options
    }
}

struct FeedResponse: Decodable {
    let uuid: String
    let title: String
    let chips: [FeedChip]
    let contents: [FeedItem]
    let nextCursor: String?
    let feedItemCount: Int?

    enum CodingKeys: String, CodingKey {
        case uuid
        case title
        case chips
        case contents
        case nextCursor = "next_cursor"
        case feedItemCount = "feed_item_count"
    }
}

struct FeedChip: Decodable, Identifiable {
    let label: String
    let reloadCursor: String

    var id: String { reloadCursor }

    enum CodingKeys: String, CodingKey {
        case label
        case reloadCursor = "reload_cursor"
    }
}

struct FeedItem: Decodable, Identifiable {
    let itemID: String
    let componentType: Int
    let post: FeedPost?
    let recommendedCreatorModule: FeedRecommendedCreatorModule?

    var id: String { itemID }

    enum CodingKeys: String, CodingKey {
        case itemID = "item_id"
        case componentType = "component_type"
        case post
        case recommendedCreatorModule = "recommended_creator_module"
    }
}

struct FeedPost: Decodable {
    let id: String
    let authorID: String?
    let authorType: Int?
    let type: Int
    let participants: [FeedParticipant]
    let content: String?
    let caption: String?
    let mediaURLs: [String]
    let createdAt: String?
    let authorInfo: FeedAuthor?
    let reactions: [String: Int]?
    let userReactions: [String: Int]?
    let metadata: FeedPostMetadata?

    enum CodingKeys: String, CodingKey {
        case id
        case authorID = "author_id"
        case authorType = "author_type"
        case type
        case participants
        case content
        case caption
        case mediaURLs = "media_urls"
        case createdAt = "created_at"
        case authorInfo = "author_info"
        case reactions
        case userReactions = "user_reactions"
        case metadata
    }
}

struct FeedPostMetadata: Decodable {
    let conversationID: String?

    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
    }
}

struct FeedParticipant: Decodable, Identifiable {
    let id: String
    let name: String?
    let avatarURL: String?
    let authorType: Int?
    let description: String?
    let creatorInfo: FeedCreatorInfo?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case avatarURL = "avatar_url"
        case authorType = "author_type"
        case description
        case creatorInfo = "creator_info"
    }
}

struct FeedAuthor: Decodable {
    let username: String?
    let name: String?
    let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case username
        case name
        case avatarURL = "avatar_url"
    }
}

struct FeedCreatorInfo: Decodable {
    let username: String?
}

struct FeedRecommendedCreatorModule: Decodable {
    let creators: [FeedRecommendedCreator]
}

struct FeedRecommendedCreator: Decodable, Identifiable {
    let displayName: String?
    let username: String
    let avatarFilename: String?
    let numFollowers: String?
    let numPostsCreated: String?

    var id: String { username }

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case username
        case avatarFilename = "avatar_filename"
        case numFollowers = "num_followers"
        case numPostsCreated = "num_posts_created"
    }
}
