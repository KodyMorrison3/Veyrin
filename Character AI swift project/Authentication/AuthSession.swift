//
//  AuthSession.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 26/09/2026.
//

import Foundation

struct AuthSession: Codable {
    let sessionToken: String
    let userID: String
    let username: String
}
