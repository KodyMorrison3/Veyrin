import Foundation

nonisolated struct AvailableModelsResponse: Decodable, Sendable {
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

nonisolated struct ModelSelectionOption: Identifiable, Sendable {
    let modelType: String
    let name: String?
    let isPlusOnly: Bool
    let isFeatured: Bool
    let isBeta: Bool
    let isLegacy: Bool
    let hasModelSteering: Bool

    var id: String { modelType }
    var displayName: String { name ?? Self.fallbackDisplayName(for: modelType) }

    nonisolated static func fallbackDisplayName(for modelType: String) -> String {
        let knownNames = [
            "MODEL_TYPE_DEEP_SYNTH": "DeepSqueak",
            "MODEL_TYPE_LONGSQUEAK": "LongSqueak",
            "MODEL_TYPE_DEEP_SYNTH_LITE": "DeepSqueak Lite",
            "MODEL_TYPE_DEEP_SYNTH_LITE_V2_1": "DeepSqueak Lite 2.1",
            "MODEL_TYPE_ROMANTIC": "Romantic",
            "MODEL_TYPE_PIPSQUEAK_3": "Pipsqueak 3",
            "MODEL_TYPE_SHORTSQUEAK": "ShortSqueak"
        ]
        if let knownName = knownNames[modelType] {
            return knownName
        }

        let normalized = modelType
            .replacingOccurrences(of: "^MODEL_TYPE_", with: "", options: .regularExpression)
            .replacingOccurrences(of: "_V([0-9]+)_([0-9]+)$", with: " $1.$2", options: .regularExpression)
            .replacingOccurrences(of: "_V([0-9]+)$", with: " $1", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ")
            .lowercased()
        return normalized.split(separator: " ").map { word in
            word.first.map { $0.uppercased() + word.dropFirst() } ?? ""
        }.joined(separator: " ")
    }
}

nonisolated struct AvailableModelConfiguration: Decodable, Sendable {
    let name: String?
    let displayName: String?
    let isPlusOnly: Bool?
    let isFeatured: Bool?
    let isBeta: Bool?
    let isLegacy: Bool?
    let hasModelSteering: Bool?

    enum CodingKeys: String, CodingKey {
        case name
        case displayName = "display_name"
        case isPlusOnly
        case isFeatured
        case isBeta
        case isLegacy
        case hasModelSteering
    }
}
