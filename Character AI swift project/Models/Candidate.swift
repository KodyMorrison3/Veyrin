import Foundation

nonisolated struct Candidate: Codable, Equatable, Sendable {
    let candidateId: String
    let rawContent: String
    let isFinal: Bool?
    let modelType: String?

    enum CodingKeys: String, CodingKey {
        case candidateId = "candidate_id"
        case rawContent = "raw_content"
        case isFinal = "is_final"
        case modelType = "model_type"
    }
}
