import Combine
import Foundation

struct GlassAppearance {
    let palette: EnvironmentalPalette
    let density: Double
    let tintScale: Double

    func matches(_ other: GlassAppearance) -> Bool {
        palette == other.palette && density == other.density && tintScale == other.tintScale
    }
}

@MainActor
final class GlassAppearanceStore: ObservableObject {
    static let shared = GlassAppearanceStore()

    @Published private(set) var appearance = GlassAppearance(
        palette: EnvironmentalPalette.defaultPalette,
        density: 0.11,
        tintScale: 0.92
    )

    func update(_ appearance: GlassAppearance) {
        guard !self.appearance.matches(appearance) else { return }
        self.appearance = appearance
    }
}

@MainActor
final class EnvironmentalPaletteStore: ObservableObject {
    static let shared = EnvironmentalPaletteStore()

    @Published private(set) var palette = EnvironmentalPalette.defaultPalette

    func update(_ palette: EnvironmentalPalette) {
        guard self.palette != palette else { return }
        self.palette = palette
    }
}
