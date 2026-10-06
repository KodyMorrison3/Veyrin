import Foundation

/// Represents a user persona for the chat session and message composer.
struct Persona: Identifiable, Codable, Equatable, Hashable {
    let id: String
    var name: String
    var displayName: String
    var avatarFileName: String?
    var isDefaultUser: Bool

    var avatarURL: URL? {
        guard let avatarFileName, !avatarFileName.isEmpty else { return nil }
        return CharacterImageURL.makeURL(avatarFileName: avatarFileName)
    }

    static func defaultUser(username: String = "", avatarFileName: String? = nil) -> Persona {
        let clean = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = clean.isEmpty ? "User" : clean
        return Persona(
            id: "default_user",
            name: resolved,
            displayName: resolved,
            avatarFileName: avatarFileName,
            isDefaultUser: true
        )
    }
}
