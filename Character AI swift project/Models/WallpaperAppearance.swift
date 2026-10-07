import AppKit
import Combine
import Foundation
import SwiftUI

struct WallpaperAppearance {
    let mode: BackgroundMode
    let image: NSImage?
    let solidColor: Color
    let blur: Double
    let visibility: Double

    func matches(_ other: WallpaperAppearance) -> Bool {
        mode == other.mode && image === other.image && solidColor == other.solidColor
            && blur == other.blur && visibility == other.visibility
    }
}

@MainActor
final class WallpaperAppearanceStore: ObservableObject {
    static let shared = WallpaperAppearanceStore()

    @Published private(set) var appearance = WallpaperAppearance(
        mode: .default,
        image: nil,
        solidColor: .black,
        blur: 0,
        visibility: 1
    )

    func update(_ appearance: WallpaperAppearance) {
        guard !self.appearance.matches(appearance) else { return }
        self.appearance = appearance
    }
}
