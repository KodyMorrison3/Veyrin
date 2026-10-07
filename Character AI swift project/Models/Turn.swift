import Foundation

struct Turn: Codable, Equatable {
    let turnID: String
    let chatID: String
    let authorID: String
    let authorName: String
    let isHuman: Bool
    let candidates: [Candidate]
    let primaryCandidateID: String
    let isPinned: Bool

    init(
        turnID: String,
        chatID: String,
        authorID: String,
        authorName: String,
        isHuman: Bool,
        candidates: [Candidate],
        primaryCandidateID: String,
        isPinned: Bool = false
    ) {
        self.turnID = turnID
        self.chatID = chatID
        self.authorID = authorID
        self.authorName = authorName
        self.isHuman = isHuman
        self.candidates = candidates
        self.primaryCandidateID = primaryCandidateID
        self.isPinned = isPinned
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        turnID = try container.decode(String.self, forKey: .turnID)
        chatID = try container.decode(String.self, forKey: .chatID)
        authorID = try container.decode(String.self, forKey: .authorID)
        authorName = try container.decode(String.self, forKey: .authorName)
        isHuman = try container.decode(Bool.self, forKey: .isHuman)
        candidates = try container.decode([Candidate].self, forKey: .candidates)
        primaryCandidateID = try container.decode(String.self, forKey: .primaryCandidateID)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }

    func settingPinned(_ isPinned: Bool) -> Turn {
        Turn(
            turnID: turnID,
            chatID: chatID,
            authorID: authorID,
            authorName: authorName,
            isHuman: isHuman,
            candidates: candidates,
            primaryCandidateID: primaryCandidateID,
            isPinned: isPinned
        )
    }

    enum CodingKeys: String, CodingKey {
        case turnID = "turn_id"
        case chatID = "chat_id"
        case authorID = "author_id"
        case authorName = "author_name"
        case isHuman = "is_human"
        case candidates
        case primaryCandidateID = "primary_candidate_id"
        case isPinned = "is_pinned"
    }
}
