import Foundation

struct AvailableModelsResponse: Decodable {
    let availableModels: [String]
    let defaultModelType: String?
    let freeDefaultModelType: String?
    let configs: [String: AvailableModelConfiguration]

    enum CodingKeys: String, CodingKey {
        case availableModels = "available_models"
        case defaultModelType = "default_model_type"
        case freeDefaultModelType = "free_default_model_type"
        case configs
    }
}

struct ModelSelectionOption: Identifiable {
    let modelType: String
    let name: String?
    let isPlusOnly: Bool
    let isFeatured: Bool
    let isBeta: Bool
    let isLegacy: Bool
    let hasModelSteering: Bool

    var id: String { modelType }
    var displayName: String { name ?? modelType }
}

struct AvailableModelConfiguration: Decodable {
    let name: String?
    let isPlusOnly: Bool?
    let isFeatured: Bool?
    let isBeta: Bool?
    let isLegacy: Bool?
    let hasModelSteering: Bool?
}
