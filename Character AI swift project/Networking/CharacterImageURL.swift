//
//  CharacterImageURL.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 26/09/2026.
//

import Foundation

struct CharacterImageURL {
    static func makeURL(
        avatarFileName: String
    ) -> URL? {
        URL(
            string: "https://characterai.io/i/80/static/avatars/\(avatarFileName)?webp=true&anim=0"
        )
    }
}
