import Foundation

nonisolated struct Turn: Codable, Equatable, Sendable {
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

    /// Mirrors the web client's update semantics (`updateTurn`/`updateCandidate`
    /// merge into the stored turn instead of replacing it): an incoming frame
    /// supersedes the fields it carries, but a partial frame — for example a
    /// censored final update that omits candidate content or the primary id —
    /// can never erase candidate content or the resolvable primary candidate
    /// already held for this turn.
    func merged(onto existing: Turn) -> Turn {
        var mergedCandidates = candidates
        if mergedCandidates.isEmpty { mergedCandidates = existing.candidates }

        var mergedPrimary = primaryCandidateID
        if mergedPrimary.isEmpty || !mergedCandidates.contains(where: { $0.candidateId == mergedPrimary }) {
            if mergedCandidates.contains(where: { $0.candidateId == existing.primaryCandidateID }) {
                mergedPrimary = existing.primaryCandidateID
            } else {
                mergedPrimary = mergedCandidates.first?.candidateId ?? mergedPrimary
            }
        }

        guard mergedCandidates != candidates || mergedPrimary != primaryCandidateID else { return self }
        return Turn(
            turnID: turnID,
            chatID: chatID,
            authorID: authorID,
            authorName: authorName,
            isHuman: isHuman,
            candidates: mergedCandidates,
            primaryCandidateID: mergedPrimary,
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
