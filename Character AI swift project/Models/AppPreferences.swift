//
//  AppPreferences.swift
//  Character AI swift project
//
//  Feature-local client preferences backing the Settings window. These are
//  local UI preferences only — no Character.AI account settings are modeled
//  here (no confirmed backend contracts exist for those), so every control
//  in Settings maps to something this app actually supports.
//
//  Persisted via UserDefaults under a single keys namespace; changes publish
//  immediately for observing views.
//

import Foundation
import Combine

enum AvatarShape: String, CaseIterable, Identifiable {
    case circle
    case roundedSquare

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .circle: return "Circle"
        case .roundedSquare: return "Rounded square"
        }
    }
}

final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    private enum Keys {
        static let avatarShape = "preferences.avatarShape"
        static let showPopularTrending = "preferences.showPopularTrending"
    }

    /// Shape of list/card avatars (sidebar rows, Discover cards). In-chat
    /// avatars and the account control keep the standard circular look.
    @Published var avatarShape: AvatarShape {
        didSet { defaults.set(avatarShape.rawValue, forKey: Keys.avatarShape) }
    }

    /// Whether Discover shows the curated Popular characters / Trending
    /// characters sections. Purely a local display toggle — the underlying
    /// feature is unchanged.
    @Published var showPopularTrending: Bool {
        didSet { defaults.set(showPopularTrending, forKey: Keys.showPopularTrending) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Keys.avatarShape)
        avatarShape = stored.flatMap(AvatarShape.init(rawValue:)) ?? .circle
        let storedShow = defaults.object(forKey: Keys.showPopularTrending) as? Bool
        showPopularTrending = storedShow ?? true
    }

    /// The corner radius to clip a list/card avatar with, based on the
    /// current shape preference.
    var listAvatarCornerRadius: CGFloat {
        switch avatarShape {
        case .circle: return 20
        case .roundedSquare: return 8
        }
    }

    /// Removes all stored preferences (Settings → Advanced). Published
    /// properties reset to their defaults and notify observers.
    func resetToDefaults() {
        avatarShape = .circle
        showPopularTrending = true
        defaults.removeObject(forKey: Keys.avatarShape)
        defaults.removeObject(forKey: Keys.showPopularTrending)
    }
}
