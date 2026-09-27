//
//  Character.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 26/09/2026.
//

import Foundation

struct Character: Codable {
    let externalID: String
    let title: String
    let name: String
    let visibility: String
    let copyable: Bool
    let greeting: String
    let description: String
    let avatarFileName: String

    enum CodingKeys: String, CodingKey {
        case externalID = "external_id"
        case title
        case name
        case visibility
        case copyable
        case greeting
        case description
        case avatarFileName = "avatar_file_name"
    }
}
