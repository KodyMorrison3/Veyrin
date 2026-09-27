import Foundation

struct Author: Codable {
    let authorId: String
    let isHuman: Bool
    let name: String

    enum CodingKeys: String, CodingKey {
        case authorId = "author_id"
        case isHuman = "is_human"
        case name
    }
}
