//
//  UserProfileModels.swift
//  Character AI swift project
//
//  Public user-profile models for `GET /api/trpc/social.publicProfile`
//  (captured in profile.har and live-verified 2026-10-01 with the app's
//  existing `Token` auth — this endpoint is public and NOT web-session
//  gated, unlike `search.search`).
//
//  Public profile data is deliberately separate from `AuthSession`; the
//  session token is never part of anything modeled or displayed here.
//

import Foundation

nonisolated struct UserProfileResponse: Decodable, Sendable {
    nonisolated struct Entry: Decodable, Sendable {
        nonisolated struct ResultBody: Decodable, Sendable {
            nonisolated struct DataBody: Decodable, Sendable {
                let json: UserProfile
            }

            let data: DataBody
        }

        let result: ResultBody?
    }

    let entries: [Entry]

    init(from decoder: Decoder) throws {
        entries = try decoder.singleValueContainer().decode([Entry].self)
    }

    func firstProfile() -> UserProfile? {
        entries.first?.result?.data.json
    }
}

nonisolated struct UserProfile: Decodable, Sendable {
    let username: String?
    let name: String?
    let bio: String?
    let avatarFileName: String?
    let subscriptionType: String?
    let followerCount: Int?
    let followingCount: Int?
    let publicCharacters: [DiscoverFeedCharacter]

    enum CodingKeys: String, CodingKey {
        case username
        case name
        case bio
        case avatarFileName = "avatar_file_name"
        case subscriptionType = "subscription_type"
        case followerCount = "num_followers"
        case followingCount = "num_following"
        case publicCharacters = "characters"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        bio = try container.decodeIfPresent(String.self, forKey: .bio)
        avatarFileName = try container.decodeIfPresent(String.self, forKey: .avatarFileName)
        subscriptionType = try container.decodeIfPresent(String.self, forKey: .subscriptionType)
        followerCount = try container.decodeIfPresent(Int.self, forKey: .followerCount)
        followingCount = try container.decodeIfPresent(Int.self, forKey: .followingCount)
        // The captured minimal profile may omit `characters` entirely.
        publicCharacters = try container.decodeIfPresent(
            [DiscoverFeedCharacter].self,
            forKey: .publicCharacters
        ) ?? []
    }
}
