import Foundation

nonisolated struct Candidate: Codable, Equatable, Sendable {
    let candidateId: String
    let rawContent: String
    let isFinal: Bool?
    let modelType: String?

    /// HAR-verified filter marker (`candidates[].safety_truncated`, censored
    /// conversations): a filtered AI response is a normal final turn whose
    /// candidate carries this flag. `nil` on turns without the key.
    let isSafetyTruncated: Bool?

    var isFiltered: Bool { isSafetyTruncated == true }

    enum CodingKeys: String, CodingKey {
        case candidateId = "candidate_id"
        case rawContent = "raw_content"
        case isFinal = "is_final"
        case modelType = "model_type"
        case isSafetyTruncated = "safety_truncated"
    }

    init(
        candidateId: String,
        rawContent: String,
        isFinal: Bool? = nil,
        modelType: String? = nil,
        isSafetyTruncated: Bool? = nil
    ) {
        self.candidateId = candidateId
        self.rawContent = rawContent
        self.isFinal = isFinal
        self.modelType = modelType
        self.isSafetyTruncated = isSafetyTruncated
    }
}
