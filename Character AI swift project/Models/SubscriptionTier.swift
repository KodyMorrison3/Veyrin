//
//  SubscriptionTier.swift
//  Character AI swift project
//

import Foundation

/// Tier of the signed-in account, from the `subscription_type` field of the
/// account profile. Captured values: `PLUS` (Plus accounts). The web client
/// treats any value containing `PLUS` as Plus; other values (`NONE`, `CAI_LITE`)
/// are treated as free here.
nonisolated enum SubscriptionTier: Equatable, Sendable {
    case plus
    case free

    /// Returns `nil` when the server did not report a subscription type, so the
    /// caller can keep the server's default model instead of guessing a tier.
    init?(subscriptionType: String?) {
        guard let subscriptionType, !subscriptionType.isEmpty else { return nil }
        self = subscriptionType.contains("PLUS") ? .plus : .free
    }

    /// Model a fresh conversation defaults to: DeepSqueak for Plus, Pipsqueak 3 for free.
    var defaultModelType: String {
        switch self {
        case .plus: "MODEL_TYPE_DEEP_SYNTH"
        case .free: "MODEL_TYPE_PIPSQUEAK_3"
        }
    }
}

nonisolated enum ModelDefaults {
    /// The tier's default model when the server lists it; otherwise the first
    /// listed model, which is the behaviour when the tier is unknown.
    static func defaultModelType(
        tier: SubscriptionTier?,
        availableModels: [ModelSelectionOption]
    ) -> String? {
        if let tier, let preferred = availableModels.first(where: { $0.modelType == tier.defaultModelType }) {
            return preferred.modelType
        }
        return availableModels.first?.modelType
    }
}
