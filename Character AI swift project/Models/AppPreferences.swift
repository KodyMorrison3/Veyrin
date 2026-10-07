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
import ImageIO
import SwiftUI

private let processedWallpaperQueue = DispatchQueue(label: "CharacterAI.WallpaperProcessing", qos: .userInitiated)

// Synchronous generation checks are required on the serial disk queue.
// The only mutable field is protected by this lock on every access.
nonisolated private final class WallpaperRequestGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0

    func advance() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        value &+= 1
        return value
    }

    func current() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        current() == generation
    }
}


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
        static let favoriteCharacterIDs = "preferences.favoriteCharacterIDs"
    }

    /// Set of locally favorited / liked character IDs (UI affordance without fake server sync).
    @Published private(set) var favoriteCharacterIDs: Set<String> {
        didSet {
            defaults.set(Array(favoriteCharacterIDs), forKey: Keys.favoriteCharacterIDs)
        }
    }

    func isFavorite(characterID: String) -> Bool {
        favoriteCharacterIDs.contains(characterID)
    }

    func toggleFavorite(characterID: String) {
        if favoriteCharacterIDs.contains(characterID) {
            favoriteCharacterIDs.remove(characterID)
        } else {
            favoriteCharacterIDs.insert(characterID)
        }
    }

    /// Shape of list/card avatars (sidebar rows, Discover cards). In-chat
    /// avatars and the account control keep the standard circular look.
    @Published var avatarShape: AvatarShape {
        didSet { defaults.set(avatarShape.rawValue, forKey: Keys.avatarShape) }
    }

    @Published private var storedGlassOpacity: Double {
        didSet {
            defaults.set(storedGlassOpacity, forKey: Keys.glassOpacity)
            updateGlassAppearance()
        }
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
            if backgroundMode == .default { updateDefaultEnvironment(forAvatarURL: defaultArtworkURL) }
            updateWallpaperAppearance()
            if backgroundMode != .default {
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
            updateWallpaperAppearance()
        }
    }

    static let wallpaperBlurRange = 0.0...40.0
    static let glassOpacityRange = 0.20...0.85
    static let defaultGlassOpacity = 0.45
    static let defaultArtworkBlur = 18.0
    static let customWallpaperBlur = 10.0
    static let effectiveWallpaperBlurCap = 40.0

    static let windowTransparencyRange = 0.0...0.80
    static let defaultWindowTransparency = 0.0

    /// nil means mode-aware automatic blur; a manual override survives mode changes.
    @Published private(set) var wallpaperBlurOverride: Double?
    @Published private var storedWindowTransparency: Double {
        didSet {
            defaults.set(storedWindowTransparency, forKey: Keys.windowTransparency)
            updateWallpaperAppearance()
        }
    }

    var wallpaperBlur: Double {
        get {
            guard backgroundMode != .solidColor else { return 0 }
            let configured = wallpaperBlurOverride ?? (backgroundMode == .default
                ? Self.defaultArtworkBlur : Self.customWallpaperBlur)
            return min(configured, Self.effectiveWallpaperBlurCap)
        }
        set {
            wallpaperBlurOverride = Self.clamped(newValue, to: Self.wallpaperBlurRange,
                                                fallback: Self.defaultArtworkBlur)
            defaults.set(wallpaperBlurOverride, forKey: Keys.wallpaperBlurOverride)
            updateWallpaperAppearance()
        }
    }

    var glassOpacity: Double {
        get { storedGlassOpacity }
        set {
            storedGlassOpacity = Self.clamped(newValue, to: Self.glassOpacityRange,
                                              fallback: Self.defaultGlassOpacity)
        }
    }

    /// User-facing Window Transparency (0% = fully opaque window, 80% = max supported transparency).
    var windowTransparency: Double {
        get { storedWindowTransparency }
        set {
            storedWindowTransparency = Self.clamped(newValue, to: Self.windowTransparencyRange,
                                                    fallback: Self.defaultWindowTransparency)
        }
    }

    /// Weight used by the shell’s layered environmental composition.
    /// This is environmental opacity rather than true composited AppKit-window alpha;
    /// using NSWindow.alphaValue would dim glyphs and controls along with the backdrop.
    var environmentVisibility: Double {
        1.0 - windowTransparency
    }

    /// Compatibility alias for the environmental foundation only; this is not
    /// the alpha of the complete application window.
    var windowEnvironmentOpacity: Double { environmentVisibility }

    /// The shared surface system maps Glass Opacity to one consistent fill/tint
    /// density range, retaining role-specific hierarchy and wallpaper colour.
    var glassDensity: Double {
        let progress = (glassOpacity - Self.glassOpacityRange.lowerBound)
            / (Self.glassOpacityRange.upperBound - Self.glassOpacityRange.lowerBound)
        return 0.025 + progress * 0.22
    }

    /// Compatibility alias used by existing shared glass surfaces.
    var additionalGlassDensity: Double { glassDensity }

    /// Tint scale shared by all system Liquid Glass roles.
    var glassTintScale: Double {
        let progress = (glassOpacity - Self.glassOpacityRange.lowerBound)
            / (Self.glassOpacityRange.upperBound - Self.glassOpacityRange.lowerBound)
        return 0.65 + progress * 0.70
    }

    func resetWallpaperBlur() {
        wallpaperBlurOverride = nil
        defaults.removeObject(forKey: Keys.wallpaperBlurOverride)
        updateWallpaperAppearance()
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

    /// Loaded custom wallpaper image from local disk. Palette extraction is done
    /// once when the image changes and cached alongside the image.
    @Published private(set) var customWallpaper: NSImage? {
        didSet { updateDerivedColors() }
    }

    @Published private(set) var customWallpaperDisplayImage: NSImage? {
        didSet { updateWallpaperAppearance() }
    }

    /// Dominant / derived ambient lighting color extracted from the active environment.
    @Published private(set) var derivedAmbientColor: Color = EnvironmentalPalette.defaultPalette.ambientColor

    /// Complete environmental color palette derived from the active wallpaper / solid color.
    @Published private(set) var environmentalPalette: EnvironmentalPalette = EnvironmentalPalette.defaultPalette {
        didSet {
            EnvironmentalPaletteStore.shared.update(environmentalPalette)
            updateGlassAppearance()
        }
    }
    var glassAppearance: GlassAppearance { GlassAppearanceStore.shared.appearance }
    private var lastGlassAppearance = GlassAppearance(
        palette: EnvironmentalPalette.defaultPalette,
        density: 0.11,
        tintScale: 0.92
    )
    var wallpaperAppearance: WallpaperAppearance { WallpaperAppearanceStore.shared.appearance }

    /// Shared artwork also supplies secondary windows (Settings, profiles, sheets).
    @Published private(set) var defaultArtwork: NSImage?
    @Published private(set) var defaultArtworkDisplayImage: NSImage? {
        didSet { updateWallpaperAppearance() }
    }

    private var customWallpaperAmbientColor: Color?
    private var defaultArtworkTask: Task<Void, Never>?
    nonisolated private final class ProcessedWallpaper: NSObject, Sendable {
        let image: NSImage
        let displayImage: NSImage
        let palette: EnvironmentalPalette?
        let ambientColor: NSColor?
        let pngData: Data?

        nonisolated init(image: NSImage, displayImage: NSImage, palette: EnvironmentalPalette? = nil,
                         ambientColor: NSColor? = nil, pngData: Data? = nil) {
            self.image = image
            self.displayImage = displayImage
            self.palette = palette
            self.ambientColor = ambientColor
            self.pngData = pngData
        }
    }

    private var processedDefaultArtwork: NSCache<NSURL, ProcessedWallpaper> = {
        let cache = NSCache<NSURL, ProcessedWallpaper>()
        cache.countLimit = 12
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()
    private let defaults: UserDefaults
    private let persistedWallpaperURL: URL?
    private let fileManager = FileManager.default
    private var hasLoadedPersistedWallpaper = false
    private let wallpaperRequestGeneration = WallpaperRequestGeneration()

    private var wallpaperFileURL: URL {
        if let persistedWallpaperURL { return persistedWallpaperURL }
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let dir = appSupport.appendingPathComponent("CharacterAI", isDirectory: true)
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

        let savedFavorites = defaults.stringArray(forKey: Keys.favoriteCharacterIDs) ?? []
        self.favoriteCharacterIDs = Set(savedFavorites)

        let storedHex = defaults.string(forKey: Keys.solidColorHex) ?? "#0F1226"
        solidColor = Color(hex: storedHex) ?? Color(red: 0.059, green: 0.071, blue: 0.149)

        EnvironmentalPaletteStore.shared.update(environmentalPalette)
        updateDerivedColors()
        updateGlassAppearance()
        updateWallpaperAppearance()
    }

    /// The corner radius to clip a list/card avatar with, based on the
    /// current shape preference.
    var listAvatarCornerRadius: CGFloat {
        switch avatarShape {
        case .circle: return 20
        case .roundedSquare: return 8
        }
    }

    private nonisolated static func pngWallpaper(from url: URL, maxPixelSize: Int) -> ProcessedWallpaper? {
        guard let image = ImageProcessing.thumbnail(from: url, maxPixelSize: maxPixelSize),
              let thumbnail = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let pngData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(pngData as CFMutableData, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let displayImage = NSImage(cgImage: thumbnail,
                                   size: NSSize(width: thumbnail.width, height: thumbnail.height))
        return ProcessedWallpaper(
            image: displayImage,
            displayImage: displayImage,
            palette: nil,
            ambientColor: nil,
            pngData: pngData as Data
        )
    }

    /// Sets and saves custom wallpaper from chosen file URL.
    func setCustomWallpaper(from sourceURL: URL) {
        let generationGuard = wallpaperRequestGeneration
        let generation = generationGuard.advance()
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        let destination = wallpaperFileURL
        processedWallpaperQueue.async { [weak self] in
            defer {
                if scoped { sourceURL.stopAccessingSecurityScopedResource() }
            }
            guard generationGuard.isCurrent(generation),
                  let processed = Self.pngWallpaper(from: sourceURL, maxPixelSize: 1800),
                  generationGuard.isCurrent(generation) else { return }
            let ambientColor = processed.image.averageColor()
            do {
                guard let pngData = processed.pngData else { return }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                guard generationGuard.isCurrent(generation) else { return }
                try pngData.write(to: destination, options: .atomic)
                Task { @MainActor [weak self] in
                    guard let self, generationGuard.isCurrent(generation) else { return }
                    self.customWallpaperAmbientColor = ambientColor.map { Color(nsColor: $0) }
                    self.customWallpaperDisplayImage = processed.image
                    self.customWallpaper = processed.image
                    self.backgroundMode = .customWallpaper
                }
            } catch {
                // Keep the current wallpaper/mode intact if persistence fails.
            }
        }
    }

    /// Removes custom wallpaper file and reverts to default.
    func clearCustomWallpaper() {
        _ = wallpaperRequestGeneration.advance()
        let destination = wallpaperFileURL
        processedWallpaperQueue.async {
            try? FileManager.default.removeItem(at: destination)
        }
        customWallpaperAmbientColor = nil
        customWallpaper = nil
        customWallpaperDisplayImage = nil
        updateWallpaperAppearance()
        if backgroundMode == .customWallpaper {
            backgroundMode = .default
        }
        updateDerivedColors()
    }

    private func loadPersistedWallpaper() {
        guard !hasLoadedPersistedWallpaper else { return }
        hasLoadedPersistedWallpaper = true
        let url = wallpaperFileURL
        let generationGuard = wallpaperRequestGeneration
        let generation = generationGuard.current()
        processedWallpaperQueue.async { [weak self] in
            guard generationGuard.isCurrent(generation) else { return }
            let displayImage = ImageProcessing.thumbnail(from: url, maxPixelSize: 1800)
            let ambientColor = displayImage?.averageColor()
            Task { @MainActor [weak self] in
                guard let self, generationGuard.isCurrent(generation) else { return }
                self.customWallpaperAmbientColor = ambientColor.map { Color(nsColor: $0) }
                self.customWallpaperDisplayImage = displayImage
                self.customWallpaper = displayImage
                if displayImage == nil && self.backgroundMode == .customWallpaper {
                    self.backgroundMode = .default
                }
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
            defaultArtworkDisplayImage = nil
            defaultArtworkPalette = nil
            if let cached = processedDefaultArtwork.object(forKey: url as NSURL) {
                defaultArtwork = cached.image
                defaultArtworkDisplayImage = cached.displayImage
                defaultArtworkPalette = cached.palette

            }
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
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
                guard !Task.isCancelled, let self,
                      self.defaultArtworkURL == url else { return }
                let preparedArtwork = await Self.prepareArtwork(data)
                guard !Task.isCancelled, self.defaultArtworkURL == url,
                      let preparedArtwork, let avg = preparedArtwork.ambientColor else { return }
                let displayImage = preparedArtwork.displayImage
                let palette = EnvironmentalPalette.from(color: Color(nsColor: avg))
                let processed = ProcessedWallpaper(
                    image: displayImage,
                    displayImage: displayImage,
                    palette: palette,
                    ambientColor: nil
                )
                self.processedDefaultArtwork.setObject(
                    processed,
                    forKey: url as NSURL,
                    cost: Int(displayImage.size.width * displayImage.size.height * 4)
                )
                guard self.backgroundMode == .default else { return }
                self.defaultArtwork = processed.image
                self.defaultArtworkDisplayImage = displayImage
                self.defaultArtworkPalette = palette
                self.updateDerivedColors()
                self.updateWallpaperAppearance()
            } catch {
                // A neutral fallback, never an unrelated brand-colour wash.
            }
        }
    }

    @concurrent
    private static func prepareArtwork(_ data: Data) async -> ProcessedWallpaper? {
        guard !Task.isCancelled,
              let image = ImageProcessing.thumbnail(from: data, maxPixelSize: 1200),
              let ambientColor = image.averageColor() else { return nil }
        return ProcessedWallpaper(image: image, displayImage: image, ambientColor: ambientColor)
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

    private func updateGlassAppearance() {
        let appearance = GlassAppearance(
            palette: environmentalPalette,
            density: additionalGlassDensity,
            tintScale: glassTintScale
        )
        guard !lastGlassAppearance.matches(appearance) else { return }
        lastGlassAppearance = appearance
        GlassAppearanceStore.shared.update(appearance)
    }

    private func updateWallpaperAppearance() {
        loadPersistedWallpaper()
        let selectedImage: NSImage?
        switch backgroundMode {
        case .default: selectedImage = defaultArtworkDisplayImage
        case .customWallpaper: selectedImage = customWallpaperDisplayImage
        case .solidColor: selectedImage = nil
        }
        let appearance = WallpaperAppearance(
            mode: backgroundMode,
            image: selectedImage,
            solidColor: solidColor,
            blur: wallpaperBlur,
            visibility: environmentVisibility
        )
        WallpaperAppearanceStore.shared.update(appearance)
    }

    /// Removes all stored preferences (Settings → Advanced). Published
    /// properties reset to their defaults and notify observers.
    func resetToDefaults() {
        favoriteCharacterIDs = []
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
        defaults.removeObject(forKey: Keys.favoriteCharacterIDs)
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
    nonisolated func averageColor() -> NSColor? {
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
struct EnvironmentalPalette: Equatable, Sendable {
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
