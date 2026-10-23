import Foundation

nonisolated struct FeedRequest: Encodable, Sendable {
    nonisolated struct Options: Encodable, Sendable {
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

nonisolated struct FeedResponse: Decodable, Sendable {
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

nonisolated struct FeedChip: Decodable, Identifiable, Sendable {
    let label: String
    let reloadCursor: String

    var id: String { reloadCursor }

    enum CodingKeys: String, CodingKey {
        case label
        case reloadCursor = "reload_cursor"
    }
}

nonisolated struct FeedItem: Decodable, Identifiable, Sendable {
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

nonisolated struct FeedPost: Decodable, Sendable {
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
    let reactionSummary: String
    let userReactions: [String: Int]?
    let metadata: FeedPostMetadata?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        authorID = try container.decodeIfPresent(String.self, forKey: .authorID)
        authorType = try container.decodeIfPresent(Int.self, forKey: .authorType)
        type = try container.decode(Int.self, forKey: .type)
        participants = try container.decodeIfPresent([FeedParticipant].self, forKey: .participants) ?? []
        content = try container.decodeIfPresent(String.self, forKey: .content)
        caption = try container.decodeIfPresent(String.self, forKey: .caption)
        mediaURLs = try container.decode([String].self, forKey: .mediaURLs)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        authorInfo = try container.decodeIfPresent(FeedAuthor.self, forKey: .authorInfo)
        reactions = try container.decodeIfPresent([String: Int].self, forKey: .reactions)
        userReactions = try container.decodeIfPresent([String: Int].self, forKey: .userReactions)
        metadata = try container.decodeIfPresent(FeedPostMetadata.self, forKey: .metadata)
        reactionSummary = (reactions ?? [:]).sorted { $0.key < $1.key }
            .map { "\($0.key) \($0.value)" }.joined(separator: "  ·  ")
    }

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

nonisolated struct FeedPostMetadata: Decodable, Sendable {
    let conversationID: String?

    enum CodingKeys: String, CodingKey {
        case conversationID = "conversation_id"
    }
}

nonisolated struct FeedParticipant: Decodable, Identifiable, Sendable {
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

nonisolated struct FeedAuthor: Decodable, Sendable {
    let username: String?
    let name: String?
    let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case username
        case name
        case avatarURL = "avatar_url"
    }
}

nonisolated struct FeedCreatorInfo: Decodable, Sendable {
    let username: String?
}

nonisolated struct FeedRecommendedCreatorModule: Decodable, Sendable {
    let creators: [FeedRecommendedCreator]
}

nonisolated struct FeedRecommendedCreator: Decodable, Identifiable, Sendable {
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
