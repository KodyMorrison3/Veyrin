//
//  CharmsModels.swift
//  Character AI swift project
//
//  Read-only models for the captured VC transactions and quests endpoints.
//  The HAR does not contain a balance response, so no balance model is added.
//

import Foundation

struct CharmTransactionsResponse: Codable {
    let transactions: [CharmTransaction]
}

struct CharmTransaction: Codable, Identifiable {
    let transactionID: String
    let userID: String
    let productID: String
    let amount: String
    let description: String
    let createTime: String

    var id: String { transactionID }

    enum CodingKeys: String, CodingKey {
        case transactionID = "transactionId"
        case userID = "userId"
        case productID = "productId"
        case amount
        case description
        case createTime
    }
}

struct CharmQuestsResponse: Codable {
    let quests: [CharmQuest]
}

struct CharmQuest: Codable, Identifiable {
    let questID: String
    let questTitle: String
    let questProgressAmount: String
    let questObjectiveAmount: String
    let questProgressStatus: String
    let rewardClaimed: Bool
    let questRewardAmount: String
    let questType: String
    let questInterval: String
    let questExpireTime: String?

    var id: String { questID }

    enum CodingKeys: String, CodingKey {
        case questID = "questId"
        case questTitle
        case questProgressAmount
        case questObjectiveAmount
        case questProgressStatus
        case rewardClaimed
        case questRewardAmount
        case questType
        case questInterval
        case questExpireTime
    }
}
