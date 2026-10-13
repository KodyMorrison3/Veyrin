import Foundation

// Synthetic fixtures only. Subscription strings are the captured values
// (PLUS, PLUS_STARTER) plus NONE and CAI_LITE, which the web client maps to free/lite.

@main
@MainActor
struct ModelDefaultChecks {
    static var failures: [String] = []

    static func expect(_ condition: Bool, _ name: String) {
        if condition {
            print("PASS \(name)")
        } else {
            failures.append(name)
            print("FAIL \(name)")
        }
    }

    static func option(_ modelType: String) -> ModelSelectionOption {
        ModelSelectionOption(
            modelType: modelType,
            name: nil,
            isPlusOnly: false,
            isFeatured: false,
            isBeta: false,
            isLegacy: false,
            hasModelSteering: false
        )
    }

    static func main() {
        // Tier mapping from the captured subscription_type values.
        expect(SubscriptionTier(subscriptionType: "PLUS") == .plus, "PLUS maps to plus")
        expect(SubscriptionTier(subscriptionType: "PLUS_STARTER") == .plus, "PLUS_STARTER maps to plus")
        expect(SubscriptionTier(subscriptionType: "NONE") == .free, "NONE maps to free")
        expect(SubscriptionTier(subscriptionType: "CAI_LITE") == .free, "CAI_LITE is not Plus, so maps to free")
        expect(SubscriptionTier(subscriptionType: nil) == nil, "missing subscription type is unknown, not free")
        expect(SubscriptionTier(subscriptionType: "") == nil, "empty subscription type is unknown, not free")

        // Default selection.
        let models = [
            option("MODEL_TYPE_SMART"),
            option("MODEL_TYPE_DEEP_SYNTH"),
            option("MODEL_TYPE_PIPSQUEAK_3"),
        ]
        expect(
            ModelDefaults.defaultModelType(tier: .plus, availableModels: models) == "MODEL_TYPE_DEEP_SYNTH",
            "plus defaults to DeepSqueak"
        )
        expect(
            ModelDefaults.defaultModelType(tier: .free, availableModels: models) == "MODEL_TYPE_PIPSQUEAK_3",
            "free defaults to Pipsqueak 3"
        )
        expect(
            ModelDefaults.defaultModelType(tier: nil, availableModels: models) == "MODEL_TYPE_SMART",
            "unknown tier keeps the first listed model"
        )
        let withoutDeepSqueak = [option("MODEL_TYPE_SMART"), option("MODEL_TYPE_PIPSQUEAK_3")]
        expect(
            ModelDefaults.defaultModelType(tier: .plus, availableModels: withoutDeepSqueak) == "MODEL_TYPE_SMART",
            "plus falls back to the first model when DeepSqueak is not listed"
        )
        expect(
            ModelDefaults.defaultModelType(tier: .free, availableModels: []) == nil,
            "no listed models yields no default"
        )

        if failures.isEmpty {
            print("Model default checks passed")
        } else {
            print("Model default checks failed: \(failures.count)")
            exit(1)
        }
    }
}
