import Foundation

struct Turn: Codable {
    let turnID: String
    let chatID: String
    let authorID: String
    let authorName: String
    let isHuman: Bool
    let candidates: [Candidate]
    let primaryCandidateID: String

    enum CodingKeys: String, CodingKey {
        case turnID = "turn_id"
        case chatID = "chat_id"
        case authorID = "author_id"
        case authorName = "author_name"
        case isHuman = "is_human"
        case candidates
        case primaryCandidateID = "primary_candidate_id"
    }
}
