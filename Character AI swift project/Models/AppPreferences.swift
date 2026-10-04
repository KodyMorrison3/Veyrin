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

import AppKit
import Combine
import Foundation
import SwiftUI

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

enum BackgroundMode: String, CaseIterable, Identifiable {
    case `default`
    case customWallpaper
    case solidColor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .default: return "Default"
        case .customWallpaper: return "Custom Wallpaper"
        case .solidColor: return "Solid Colour"
        }
    }
}

final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    private enum Keys {
        static let avatarShape = "preferences.avatarShape"
        static let showPopularTrending = "preferences.showPopularTrending"
        static let backgroundMode = "preferences.backgroundMode"
        static let solidColorHex = "preferences.solidColorHex"
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

    /// Environmental background mode across the entire app:
    /// - Default: character avatar/artwork with derived environmental tone.
    /// - Custom Wallpaper: user image blurred into atmospheric environment.
    /// - Solid Colour: user solid background colour underneath glass.
    @Published var backgroundMode: BackgroundMode {
        didSet { defaults.set(backgroundMode.rawValue, forKey: Keys.backgroundMode) }
    }

    /// Selected solid environmental background colour.
    @Published var solidColor: Color {
        didSet {
            defaults.set(solidColor.toHex() ?? "#0F1226", forKey: Keys.solidColorHex)
            updateDerivedColors()
        }
    }

    /// Loaded custom wallpaper image from local disk.
    @Published private(set) var customWallpaper: NSImage? {
        didSet { updateDerivedColors() }
    }

    /// Dominant / derived ambient lighting color extracted from the active environment.
    @Published private(set) var derivedAmbientColor: Color = Color.caiPrimary

    /// Complete environmental color palette derived from the active wallpaper / solid color.
    @Published private(set) var environmentalPalette: EnvironmentalPalette = EnvironmentalPalette.defaultPalette

    private let defaults: UserDefaults
    private let fileManager = FileManager.default

    private var wallpaperFileURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let dir = appSupport.appendingPathComponent("CharacterAI", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("custom_wallpaper.png")
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Keys.avatarShape)
        avatarShape = stored.flatMap(AvatarShape.init(rawValue:)) ?? .circle
        let storedShow = defaults.object(forKey: Keys.showPopularTrending) as? Bool
        showPopularTrending = storedShow ?? true

        let storedMode = defaults.string(forKey: Keys.backgroundMode)
        backgroundMode = storedMode.flatMap(BackgroundMode.init(rawValue:)) ?? .default

        let storedHex = defaults.string(forKey: Keys.solidColorHex) ?? "#0F1226"
        solidColor = Color(hex: storedHex) ?? Color(red: 0.059, green: 0.071, blue: 0.149)

        loadPersistedWallpaper()
        updateDerivedColors()
    }

    /// The corner radius to clip a list/card avatar with, based on the
    /// current shape preference.
    var listAvatarCornerRadius: CGFloat {
        switch avatarShape {
        case .circle: return 20
        case .roundedSquare: return 8
        }
    }

    /// Sets and saves custom wallpaper from chosen file URL.
    func setCustomWallpaper(from sourceURL: URL) {
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        guard let image = NSImage(contentsOf: sourceURL),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            return
        }

        do {
            try pngData.write(to: wallpaperFileURL, options: .atomic)
            customWallpaper = image
            backgroundMode = .customWallpaper
        } catch {
            print("Failed to save custom wallpaper:", error)
        }
    }

    /// Removes custom wallpaper file and reverts to default.
    func clearCustomWallpaper() {
        try? fileManager.removeItem(at: wallpaperFileURL)
        customWallpaper = nil
        if backgroundMode == .customWallpaper {
            backgroundMode = .default
        }
        updateDerivedColors()
    }

    private func loadPersistedWallpaper() {
        if fileManager.fileExists(atPath: wallpaperFileURL.path),
           let image = NSImage(contentsOf: wallpaperFileURL) {
            customWallpaper = image
        } else {
            customWallpaper = nil
            if backgroundMode == .customWallpaper {
                backgroundMode = .default
            }
        }
    }

    // MARK: Default-mode artwork environment
    //
    // In default background mode the environment is driven by the selected
    // character's artwork: the shell blurs that artwork while this palette
    // derives tonal variants from its average color. The result is published
    // through `environmentalPalette`, the single source every surface (shell,
    // glass chrome, sidebar, bubbles, profile controls) renders from.

    /// Avatar URL currently driving the default-mode environment (in-memory).
    private var defaultArtworkURL: URL?
    /// Palette last derived from `defaultArtworkURL` (in-memory).
    private var defaultArtworkPalette: EnvironmentalPalette?

    /// Updates the default-mode environment from the driving avatar artwork.
    /// Only the main window shell passes a non-nil URL; secondary surfaces
    /// (Settings, popovers) pass nil and are ignored, so they can never
    /// overwrite the shared environment with their own tint.
    func updateDefaultEnvironment(forAvatarURL url: URL?) {
        guard backgroundMode == .default, let url else { return }
        if url == defaultArtworkURL,
           let palette = defaultArtworkPalette,
           environmentalPalette == palette {
            return
        }
        defaultArtworkURL = url

        Task { @MainActor [weak self] in
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let self,
                      self.backgroundMode == .default,
                      self.defaultArtworkURL == url,
                      let image = NSImage(data: data),
                      let avg = image.averageColor() else {
                    return
                }
                let color = Color(nsColor: avg)
                let palette = EnvironmentalPalette.from(color: color)
                self.derivedAmbientColor = color
                self.defaultArtworkPalette = palette
                self.environmentalPalette = palette
            } catch {
                // Keep the current palette on network failure.
            }
        }
    }

    /// Derives an ambient lighting tint from the current custom wallpaper or solid color.
    private func updateDerivedColors() {
        switch backgroundMode {
        case .default:
            if let palette = defaultArtworkPalette {
                // Returning to default mode: restore the artwork-derived
                // environment instead of flashing the brand palette.
                derivedAmbientColor = palette.ambientColor
                environmentalPalette = palette
            } else {
                derivedAmbientColor = Color.caiPrimary
                environmentalPalette = EnvironmentalPalette.defaultPalette
            }
        case .solidColor:
            derivedAmbientColor = solidColor
            environmentalPalette = EnvironmentalPalette.from(color: solidColor)
        case .customWallpaper:
            if let customWallpaper, let avg = customWallpaper.averageColor() {
                let color = Color(nsColor: avg)
                derivedAmbientColor = color
                environmentalPalette = EnvironmentalPalette.from(color: color)
            } else {
                derivedAmbientColor = Color.caiPrimary
                environmentalPalette = EnvironmentalPalette.defaultPalette
            }
        }
    }

    /// Removes all stored preferences (Settings → Advanced). Published
    /// properties reset to their defaults and notify observers.
    func resetToDefaults() {
        avatarShape = .circle
        showPopularTrending = true
        backgroundMode = .default
        solidColor = Color(red: 0.059, green: 0.071, blue: 0.149)
        clearCustomWallpaper()
        defaults.removeObject(forKey: Keys.avatarShape)
        defaults.removeObject(forKey: Keys.showPopularTrending)
        defaults.removeObject(forKey: Keys.backgroundMode)
        defaults.removeObject(forKey: Keys.solidColorHex)
    }
}

// MARK: - Color Hex & NSImage Helpers

extension Color {
    init?(hex: String) {
        var str = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.hasPrefix("#") {
            str.removeFirst()
        }
        guard str.count == 6 || str.count == 8,
              let intVal = UInt64(str, radix: 16) else {
            return nil
        }
        let r, g, b, a: Double
        if str.count == 8 {
            r = Double((intVal >> 24) & 0xff) / 255.0
            g = Double((intVal >> 16) & 0xff) / 255.0
            b = Double((intVal >> 8) & 0xff) / 255.0
            a = Double(intVal & 0xff) / 255.0
        } else {
            r = Double((intVal >> 16) & 0xff) / 255.0
            g = Double((intVal >> 8) & 0xff) / 255.0
            b = Double(intVal & 0xff) / 255.0
            a = 1.0
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    func toHex() -> String? {
        guard let components = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = Int(round(components.redComponent * 255))
        let g = Int(round(components.greenComponent * 255))
        let b = Int(round(components.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

extension NSImage {
    /// Fast average color extraction for ambient lighting tint.
    func averageColor() -> NSColor? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        guard w > 0, h > 0 else { return nil }

        var rTotal: CGFloat = 0
        var gTotal: CGFloat = 0
        var bTotal: CGFloat = 0
        var count: CGFloat = 0

        let stepX = max(1, w / 16)
        let stepY = max(1, h / 16)

        for y in stride(from: 0, to: h, by: stepY) {
            for x in stride(from: 0, to: w, by: stepX) {
                if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    rTotal += color.redComponent
                    gTotal += color.greenComponent
                    bTotal += color.blueComponent
                    count += 1
                }
            }
        }
        guard count > 0 else { return nil }
        return NSColor(srgbRed: rTotal / count, green: gTotal / count, blue: bTotal / count, alpha: 1.0)
    }
}

// MARK: - Environmental Tonal Palette

/// Dynamic tonal palette derived from the active wallpaper or environmental source.
/// Generates harmonious tonal variants within the exact same color family/hue:
/// - deep atmospheric floor/base
/// - base environmental ambient color
/// - lighter / less-saturated highlight tint
/// - surface & glass tint variants for Liquid Glass surfaces
struct EnvironmentalPalette: Equatable {
    /// Deep atmospheric foundation used for the window base and depth vignettes.
    let atmosphericBase: Color
    /// The source / active environmental ambient color.
    let ambientColor: Color
    /// Lighter, lifted highlight variant for ambient radial glow.
    let ambientHighlight: Color
    /// Subtle translucent tint for Liquid Glass chrome and panels.
    let glassSurfaceTint: Color
    /// Translucent tint for selected items (sidebar rows, segmented controls).
    let selectionTint: Color

    /// Default palette: matches the native dark indigo/blue brand atmosphere.
    static let defaultPalette = EnvironmentalPalette(
        atmosphericBase: Color(red: 0.059, green: 0.071, blue: 0.149), // #0F1226
        ambientColor: Color.caiPrimary,                                  // #7B8CFF
        ambientHighlight: Color(red: 0.431, green: 0.906, blue: 1.0),   // #6EE7FF
        glassSurfaceTint: Color(red: 0.102, green: 0.122, blue: 0.243), // #1A1F3E
        selectionTint: Color.caiPrimary.opacity(0.22)
    )

    /// Dynamically constructs an environmental tonal palette from any arbitrary source color.
    static func from(color: Color) -> EnvironmentalPalette {
        guard let nsColor = NSColor(color).usingColorSpace(.sRGB) else {
            return .defaultPalette
        }

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        nsColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        // 1. Deep atmospheric base: Keep the source hue with low brightness and moderate saturation
        // so dark floor gradients remain within the exact wallpaper color family.
        let baseBrightness = min(max(brightness * 0.12, 0.04), 0.15)
        let baseSaturation = min(max(saturation * 0.70, 0.15), 0.85)
        let baseNS = NSColor(hue: hue, saturation: baseSaturation, brightness: baseBrightness, alpha: 1.0)
        let atmosphericBase = Color(nsColor: baseNS)

        // 2. Base ambient color: The source color itself.
        let ambientColor = color

        // 3. Ambient highlight: Lifted brightness and softened saturation within the same hue.
        let highlightBrightness = min(brightness * 1.25 + 0.15, 1.0)
        let highlightSaturation = max(saturation * 0.75, 0.15)
        let highlightNS = NSColor(hue: hue, saturation: highlightSaturation, brightness: highlightBrightness, alpha: 1.0)
        let ambientHighlight = Color(nsColor: highlightNS)

        // 4. Glass surface tint: Subtle translucent tint keeping hue cohesion.
        let surfaceBrightness = min(max(brightness * 0.22, 0.08), 0.26)
        let surfaceSaturation = min(max(saturation * 0.55, 0.12), 0.70)
        let surfaceNS = NSColor(hue: hue, saturation: surfaceSaturation, brightness: surfaceBrightness, alpha: 1.0)
        let glassSurfaceTint = Color(nsColor: surfaceNS)

        // 5. Selection tint: Clean translucent accent tint for selected list rows and buttons.
        let selectionTint = color.opacity(0.24)

        return EnvironmentalPalette(
            atmosphericBase: atmosphericBase,
            ambientColor: ambientColor,
            ambientHighlight: ambientHighlight,
            glassSurfaceTint: glassSurfaceTint,
            selectionTint: selectionTint
        )
    }
}
