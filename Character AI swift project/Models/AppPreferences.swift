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
        static let wallpaperBlurOverride = "preferences.wallpaperBlurOverride"
        static let glassOpacity = "preferences.glassOpacity"
        static let windowTransparency = "preferences.windowTransparency"
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
    /// - Custom Wallpaper: recognizable user image softened behind glass.
    /// - Solid Colour: user solid background colour underneath glass.
    @Published var backgroundMode: BackgroundMode {
        didSet {
            defaults.set(backgroundMode.rawValue, forKey: Keys.backgroundMode)
            updateDerivedColors()
            if backgroundMode == .default {
                updateDefaultEnvironment(forAvatarURL: defaultArtworkURL)
            } else {
                defaultArtworkTask?.cancel()
                defaultArtworkTask = nil
            }
        }
    }

    /// Selected solid environmental background colour.
    @Published var solidColor: Color {
        didSet {
            defaults.set(solidColor.toHex() ?? "#0F1226", forKey: Keys.solidColorHex)
            updateDerivedColors()
        }
    }

    static let wallpaperBlurRange = 0.0...40.0
    static let glassOpacityRange = 0.20...0.85
    static let defaultGlassOpacity = 0.45
    static let defaultArtworkBlur = 36.0
    static let customWallpaperBlur = 16.0

    static let windowTransparencyRange = 0.0...0.80
    static let defaultWindowTransparency = 0.0

    /// nil means mode-aware automatic blur; a manual override survives mode changes.
    @Published private(set) var wallpaperBlurOverride: Double?
    @Published private var storedGlassOpacity: Double
    @Published private var storedWindowTransparency: Double

    var wallpaperBlur: Double {
        get {
            guard backgroundMode != .solidColor else { return 0 }
            return wallpaperBlurOverride ?? (backgroundMode == .default
                ? Self.defaultArtworkBlur : Self.customWallpaperBlur)
        }
        set {
            wallpaperBlurOverride = Self.clamped(newValue, to: Self.wallpaperBlurRange,
                                                fallback: Self.defaultArtworkBlur)
            defaults.set(wallpaperBlurOverride, forKey: Keys.wallpaperBlurOverride)
        }
    }

    var glassOpacity: Double {
        get { storedGlassOpacity }
        set {
            storedGlassOpacity = Self.clamped(newValue, to: Self.glassOpacityRange,
                                              fallback: Self.defaultGlassOpacity)
            defaults.set(storedGlassOpacity, forKey: Keys.glassOpacity)
        }
    }

    /// User-facing Window Transparency (0% = fully opaque window, 80% = max supported transparency).
    var windowTransparency: Double {
        get { storedWindowTransparency }
        set {
            storedWindowTransparency = Self.clamped(newValue, to: Self.windowTransparencyRange,
                                                    fallback: Self.defaultWindowTransparency)
            defaults.set(storedWindowTransparency, forKey: Keys.windowTransparency)
        }
    }

    /// Backing opacity for the window environmental foundation (1.0 = fully opaque, 0.20 = max transparent).
    var windowEnvironmentOpacity: Double {
        1.0 - windowTransparency
    }

    /// Visibility ratio for the environmental base layers (1.0 = opaque window, 0.20 = max transparent).
    var environmentVisibility: Double {
        windowEnvironmentOpacity
    }

    /// Shared glass density adjustment for translucent surfaces.
    var additionalGlassDensity: Double { max(0, glassOpacity - Self.defaultGlassOpacity) * 0.70 }

    func resetWallpaperBlur() {
        wallpaperBlurOverride = nil
        defaults.removeObject(forKey: Keys.wallpaperBlurOverride)
    }

    func resetGlassOpacity() {
        glassOpacity = Self.defaultGlassOpacity
        defaults.removeObject(forKey: Keys.glassOpacity)
    }

    func resetWindowTransparency() {
        windowTransparency = Self.defaultWindowTransparency
        defaults.removeObject(forKey: Keys.windowTransparency)
    }

    private static func clamped(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
    }

    /// Loaded custom wallpaper image from local disk.
    @Published private(set) var customWallpaper: NSImage? {
        didSet {
            customWallpaperAmbientColor = customWallpaper?.averageColor().map { Color(nsColor: $0) }
            updateDerivedColors()
        }
    }

    /// Dominant / derived ambient lighting color extracted from the active environment.
    @Published private(set) var derivedAmbientColor: Color = EnvironmentalPalette.defaultPalette.ambientColor

    /// Complete environmental color palette derived from the active wallpaper / solid color.
    @Published private(set) var environmentalPalette: EnvironmentalPalette = EnvironmentalPalette.defaultPalette

    /// Shared artwork also supplies secondary windows (Settings, profiles, sheets).
    @Published private(set) var defaultArtwork: NSImage?

    private var customWallpaperAmbientColor: Color?
    private var defaultArtworkTask: Task<Void, Never>?
    private let defaults: UserDefaults
    private let persistedWallpaperURL: URL?
    private let fileManager = FileManager.default

    private var wallpaperFileURL: URL {
        if let persistedWallpaperURL { return persistedWallpaperURL }
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let dir = appSupport.appendingPathComponent("CharacterAI", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("custom_wallpaper.png")
    }

    init(defaults: UserDefaults = .standard, wallpaperURL: URL? = nil) {
        self.defaults = defaults
        self.persistedWallpaperURL = wallpaperURL
        let stored = defaults.string(forKey: Keys.avatarShape)
        avatarShape = stored.flatMap(AvatarShape.init(rawValue:)) ?? .circle
        let storedShow = defaults.object(forKey: Keys.showPopularTrending) as? Bool
        showPopularTrending = storedShow ?? true

        let storedMode = defaults.string(forKey: Keys.backgroundMode)
        backgroundMode = storedMode.flatMap(BackgroundMode.init(rawValue:)) ?? .default

        wallpaperBlurOverride = (defaults.object(forKey: Keys.wallpaperBlurOverride) as? NSNumber).map {
            Self.clamped($0.doubleValue, to: Self.wallpaperBlurRange, fallback: Self.defaultArtworkBlur)
        }
        storedGlassOpacity = Self.clamped(
            (defaults.object(forKey: Keys.glassOpacity) as? NSNumber)?.doubleValue ?? Self.defaultGlassOpacity,
            to: Self.glassOpacityRange, fallback: Self.defaultGlassOpacity
        )
        storedWindowTransparency = Self.clamped(
            (defaults.object(forKey: Keys.windowTransparency) as? NSNumber)?.doubleValue ?? Self.defaultWindowTransparency,
            to: Self.windowTransparencyRange, fallback: Self.defaultWindowTransparency
        )

        let storedHex = defaults.string(forKey: Keys.solidColorHex) ?? "#0F1226"
        solidColor = Color(hex: storedHex) ?? Color(red: 0.059, green: 0.071, blue: 0.149)

        loadPersistedWallpaper()
        customWallpaperAmbientColor = customWallpaper?.averageColor().map { Color(nsColor: $0) }
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
        guard let url else { return }
        if url != defaultArtworkURL {
            defaultArtworkTask?.cancel()
            defaultArtworkTask = nil
            defaultArtworkURL = url
            defaultArtwork = nil
            defaultArtworkPalette = nil
            if backgroundMode == .default { updateDerivedColors() }
        }
        // Track the selected artwork even in Custom/Solid mode, so reverting
        // to Default uses the current character rather than a stale palette.
        guard backgroundMode == .default, defaultArtworkPalette == nil,
              defaultArtworkTask == nil else { return }

        defaultArtworkTask = Task { @MainActor [weak self] in
            defer {
                if !Task.isCancelled, self?.defaultArtworkURL == url {
                    self?.defaultArtworkTask = nil
                }
            }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled, let self,
                      self.backgroundMode == .default,
                      self.defaultArtworkURL == url,
                      let image = NSImage(data: data),
                      let avg = image.averageColor() else { return }
                self.defaultArtwork = image
                self.defaultArtworkPalette = EnvironmentalPalette.from(color: Color(nsColor: avg))
                self.updateDerivedColors()
            } catch {
                // A neutral fallback, never an unrelated brand-colour wash.
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
                derivedAmbientColor = EnvironmentalPalette.defaultPalette.ambientColor
                environmentalPalette = EnvironmentalPalette.defaultPalette
            }
        case .solidColor:
            derivedAmbientColor = solidColor
            environmentalPalette = EnvironmentalPalette.from(color: solidColor)
        case .customWallpaper:
            if let color = customWallpaperAmbientColor {
                derivedAmbientColor = color
                environmentalPalette = EnvironmentalPalette.from(color: color)
            } else {
                derivedAmbientColor = EnvironmentalPalette.defaultPalette.ambientColor
                environmentalPalette = EnvironmentalPalette.defaultPalette
            }
        }
    }

    /// Removes all stored preferences (Settings → Advanced). Published
    /// properties reset to their defaults and notify observers.
    func resetToDefaults() {
        avatarShape = .circle
        showPopularTrending = true
        resetWallpaperBlur()
        resetGlassOpacity()
        resetWindowTransparency()
        backgroundMode = .default
        solidColor = Color(red: 0.059, green: 0.071, blue: 0.149)
        clearCustomWallpaper()
        defaults.removeObject(forKey: Keys.avatarShape)
        defaults.removeObject(forKey: Keys.showPopularTrending)
        defaults.removeObject(forKey: Keys.backgroundMode)
        defaults.removeObject(forKey: Keys.solidColorHex)
        defaults.removeObject(forKey: Keys.wallpaperBlurOverride)
        defaults.removeObject(forKey: Keys.glassOpacity)
        defaults.removeObject(forKey: Keys.windowTransparency)
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
        guard let image = cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        // Normalize arbitrary image profiles/formats to a small sRGB buffer.
        // This keeps extraction independent of the original bitmap representation.
        let size = 16
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: size, height: size,
                                          bitsPerComponent: 8, bytesPerRow: size * 4,
                                          space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drawn else { return nil }
        var red = 0, green = 0, blue = 0, alpha = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            // RGB is premultiplied: divide by total alpha, not pixel count,
            // to exclude transparent borders from the atmospheric colour.
            red += Int(pixels[index])
            green += Int(pixels[index + 1])
            blue += Int(pixels[index + 2])
            alpha += Int(pixels[index + 3])
        }
        guard alpha > 0 else { return nil }
        return NSColor(srgbRed: CGFloat(red) / CGFloat(alpha),
                       green: CGFloat(green) / CGFloat(alpha),
                       blue: CGFloat(blue) / CGFloat(alpha), alpha: 1)
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

    /// No artwork yet (or unavailable): neutral, not a permanent brand gradient.
    static let defaultPalette = make(color: Color(.sRGB, white: 0.18, opacity: 1),
                                     hue: 0, saturation: 0, brightness: 0.18)

    /// Opaque accessible fallback. Light appearance needs a light surface for
    /// semantic black text; dark appearance keeps the deeper environmental tone.
    func opaqueSurface(isDark: Bool) -> Color {
        if isDark { return glassSurfaceTint }
        guard let source = NSColor(ambientColor).usingColorSpace(.sRGB) else { return .white }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        source.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(hue: Double(hue), saturation: Double(saturation * 0.12), brightness: 0.96)
    }

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

        return make(color: color, hue: hue, saturation: saturation, brightness: brightness)
    }

    private static func make(color: Color, hue: CGFloat, saturation: CGFloat,
                             brightness: CGFloat) -> EnvironmentalPalette {
        // All tones keep the source hue. No minimum saturation: greys, black,
        // and white must stay neutral rather than acquiring an arbitrary hue.
        func tone(saturation factor: CGFloat, brightness value: CGFloat) -> Color {
            Color(hue: Double(hue), saturation: Double(saturation * factor),
                  brightness: Double(value))
        }
        return EnvironmentalPalette(
            atmosphericBase: tone(saturation: 0.70, brightness: max(brightness * 0.12, 0.04)),
            ambientColor: color,
            ambientHighlight: tone(saturation: 0.65, brightness: min(brightness * 1.20 + 0.18, 1)),
            glassSurfaceTint: tone(saturation: 0.55, brightness: max(brightness * 0.22, 0.08)),
            selectionTint: color.opacity(0.24)
        )
    }
}
