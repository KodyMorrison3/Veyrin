import AppKit
import SwiftUI

/// Interaction accents and content colours. Environmental colours belong only
/// to AppPreferences.environmentalPalette, never to fixed brand tokens.
extension Color {
    static let caiPrimary = Color(red: 0.482, green: 0.549, blue: 1.0)       // #7B8CFF
    static let caiText = Color.primary
    static let caiMuted = Color.secondary
}

/// Board-derived geometry. Content stays open; only navigation and floating
/// controls use glass. System fonts and semantic foreground styles remain native.
enum GlassMetrics {
    static let controlRadius: CGFloat = 12
    static let popoverRadius: CGFloat = 14
    static let messageRadius: CGFloat = 18
    static let composerRadius: CGFloat = 22
    static let composerHeight: CGFloat = 44
    static let sendDiameter: CGFloat = 28
    static let contentWidth: CGFloat = 780

    static let interaction = Animation.easeOut(duration: 0.16)
}

/// Roles differ in readability and tint, not in increasingly elaborate borders.
enum GlassSurfaceRole {
    case navigation, floatingControl, popover, sheet, characterMessage, userMessage, searchField, characterHeader

    /// In-window Liquid Glass for every role, including the bottom profile
    /// control. Scales smoothly with preferences.glassTintScale.
    func systemGlassTint(isDark: Bool, palette: EnvironmentalPalette, tintScale: Double = 1.0) -> Color {
        let baseTint = palette.glassSurfaceTint
        let scale = tintScale
        // Light mode uses lower system tint: macOS regular glass already adds a
        // strong milky lift over bright environmental wallpapers.
        switch self {
        case .navigation: return baseTint.opacity((isDark ? 0.32 : 0.13) * scale)
        case .searchField: return baseTint.opacity((isDark ? 0.16 : 0.07) * scale)
        case .characterHeader: return baseTint.opacity((isDark ? 0.12 : 0.045) * scale)
        case .floatingControl: return baseTint.opacity((isDark ? 0.22 : 0.09) * scale)
        case .characterMessage: return baseTint.opacity((isDark ? 0.42 : 0.19) * scale)
        case .userMessage: return baseTint.opacity((isDark ? 0.18 : 0.07) * scale)
        case .popover, .sheet: return baseTint.opacity((isDark ? 0.36 : 0.15) * scale)
        }
    }

    /// Subtle material wash derived from the active wallpaper tone. Using the
    /// source color rather than white avoids the milky white slab effect in light mode.
    func environmentalWash(isDark: Bool, palette: EnvironmentalPalette) -> Color {
        switch self {
        case .navigation: return palette.atmosphericBase.opacity(isDark ? 0.12 : 0.055)
        case .searchField: return palette.ambientColor.opacity(isDark ? 0.035 : 0.025)
        case .characterHeader: return palette.ambientColor.opacity(isDark ? 0.045 : 0.03)
        case .floatingControl: return palette.ambientColor.opacity(isDark ? 0.08 : 0.045)
        case .characterMessage: return palette.ambientColor.opacity(isDark ? 0.13 : 0.075)
        case .userMessage: return palette.ambientHighlight.opacity(isDark ? 0.08 : 0.10)
        case .popover, .sheet: return palette.atmosphericBase.opacity(isDark ? 0.11 : 0.055)
        }
    }

    var lightModeRimOpacity: Double {
        switch self {
        case .navigation, .searchField, .characterHeader: return 0.045
        case .floatingControl: return 0.065
        case .characterMessage: return 0.075
        case .userMessage: return 0.11
        case .popover, .sheet: return 0.055
        }
    }
}

/// One material recipe for the entire app. A filled light wash replaces edge
/// strokes; only keyboard focus gets an outline. Native windows/popovers supply
/// their own elevation, so no additional drop shadow is applied here.
struct GlassSurfaceBackground: View {
    var role: GlassSurfaceRole = .floatingControl
    var cornerRadius: CGFloat = GlassMetrics.controlRadius
    var isFocused = false

    @ObservedObject private var appearanceStore = GlassAppearanceStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isDark: Bool { colorScheme == .dark }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        let appearance = appearanceStore.appearance
        let palette = appearance.palette
        ZStack {
            if reduceTransparency {
                shape.fill(palette.opaqueSurface(isDark: isDark))
            } else {
                shape.fill(Color.clear)
                    .glassEffect(
                        Glass.regular.tint(role.systemGlassTint(isDark: isDark, palette: palette, tintScale: appearance.tintScale)),
                        in: shape
                    )

                // Scale glass density without creating a uniform opaque white card.
                // The density wash remains tinted by the wallpaper-derived palette.
                shape.fill(palette.glassSurfaceTint
                    .opacity(appearance.density * (isDark ? 1.0 : 0.55)))
                shape.fill(role.environmentalWash(isDark: isDark, palette: palette))

                if role == .userMessage {
                    // Light neutral lift keeps user messages brighter than character
                    // messages without bleaching out their wallpaper environment.
                    shape.fill(Color.white.opacity(isDark ? 0.10 : 0.055))
                }

                if role == .userMessage || role == .characterMessage || role == .floatingControl {
                    // Light-mode rims use a restrained dark edge for definition;
                    // dark mode keeps the existing soft highlight.
                    let rim = isDark ? Color.white : Color.black
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [
                                rim.opacity(isDark ? (role == .userMessage ? 0.10 : 0.08) : role.lightModeRimOpacity),
                                rim.opacity(0.008)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
                }
            }

            if isFocused {
                shape.strokeBorder(palette.ambientColor.opacity(0.6), lineWidth: 1)
            }
        }
        .animation(reduceMotion ? nil : GlassMetrics.interaction, value: isFocused)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct GlassSurface: ViewModifier {
    var role: GlassSurfaceRole
    var cornerRadius: CGFloat
    var isFocused: Bool

    func body(content: Content) -> some View {
        content.background {
            GlassSurfaceBackground(
                role: role,
                cornerRadius: cornerRadius,
                isFocused: isFocused
            )
        }
    }
}

/// Quiet content grouping, intentionally NOT another layer of glass. Used for
/// discovery entries and feed articles where reading outranks surface effects.
private struct ContentSurface: ViewModifier {
    var cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.primary.opacity(contrast == .increased ? 0.10 :
                    (colorScheme == .dark ? 0.035 : 0.025)))
        }
    }
}

extension View {
    func glassSurface(
        _ role: GlassSurfaceRole = .floatingControl,
        cornerRadius: CGFloat = GlassMetrics.controlRadius,
        isFocused: Bool = false
    ) -> some View {
        modifier(GlassSurface(role: role, cornerRadius: cornerRadius, isFocused: isFocused))
    }

    func contentSurface(cornerRadius: CGFloat = GlassMetrics.controlRadius) -> some View {
        modifier(ContentSurface(cornerRadius: cornerRadius))
    }
}

/// Primary actions use the same transparent Liquid Glass as floating controls
/// instead of a filled accent slab. The label keeps native text contrast; the
/// surface supplies the tint, rim and hover/press feedback.
struct GlassProminentButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        GlassProminentBody(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct GlassProminentBody: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat
        @Environment(\.controlSize) private var controlSize
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovering = false

        private var horizontalPadding: CGFloat {
            switch controlSize {
            case .mini, .small: return 10
            case .large, .extraLarge: return 18
            default: return 14
            }
        }

        private var verticalPadding: CGFloat {
            switch controlSize {
            case .mini, .small: return 4
            case .large, .extraLarge: return 10
            default: return 7
            }
        }

        var body: some View {
            configuration.label
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .background {
                    ZStack {
                        GlassSurfaceBackground(role: .floatingControl, cornerRadius: cornerRadius)
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color.primary.opacity(isEnabled && isHovering ? 0.045 : 0))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.45)
                .onHover { isHovering = $0 }
                .animation(reduceMotion ? nil : GlassMetrics.interaction, value: configuration.isPressed)
                .animation(reduceMotion ? nil : GlassMetrics.interaction, value: isHovering)
        }
    }
}

/// A compact icon treatment that floats on the environment instead of sitting
/// on an opaque accent tile.
struct GlassIconTile: View {
    let systemName: String
    var size: CGFloat = 34
    var cornerRadius: CGFloat = 10

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(Color.caiPrimary)
            .frame(width: size, height: size)
            .background {
                GlassSurfaceBackground(role: .floatingControl, cornerRadius: cornerRadius)
            }
            .accessibilityHidden(true)
    }
}

/// Unified global environmental background system.
///
/// Serves as the single source of truth across the entire app:
/// 1. Solid Colour: No image blur; solid base with atmospheric/vignette treatment.
/// 2. Custom Wallpaper: Lighter blur (10pt) so the user's wallpaper remains
///    recognizable and visually present while softened for Liquid Glass.
/// The active palette is published by `AppPreferences`, so every surface reads a
/// single shared environment instead of each view deriving its own.
struct ShellEnvironmentalBackground: View {

    /// Scales the readability vignette. The default preserves the main
    /// window; secondary surfaces (e.g. Settings) pass a lower value so the
    /// blurred environment contributes visibly rather than reading as a dark slab.
    var vignetteStrength: Double = 1.0

    @ObservedObject private var wallpaperStore = WallpaperAppearanceStore.shared
    @ObservedObject private var paletteStore = EnvironmentalPaletteStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var isDark: Bool { colorScheme == .dark }
    private var wallpaper: WallpaperAppearance { wallpaperStore.appearance }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if reduceTransparency {
                    activePalette.opaqueSurface(isDark: isDark)
                } else {
                    activePalette.atmosphericBase
                        .opacity(wallpaper.visibility)
                }

                if !reduceTransparency {
                    switch wallpaper.mode {
                    case .customWallpaper:
                        if let customImage = wallpaper.image {
                            Image(nsImage: customImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .clipped()
                                .saturation(0.95)
                                .blur(radius: wallpaper.blur, opaque: true)
                                .opacity((isDark ? 0.90 : 0.80) * wallpaper.visibility)
                        }

                    case .solidColor:
                        // In solid color mode, the solid color base fills the environment.
                        // We provide a soft atmospheric texture over it.
                        wallpaper.solidColor
                            .opacity((isDark ? 0.55 : 0.75) * wallpaper.visibility)
                    }
                }

                if !reduceTransparency {
                    // Keep one soft tonal veil instead of stacking two composited gradients.
                    LinearGradient(
                        colors: [
                            activePalette.atmosphericBase.opacity(0.40 * vignetteStrength * wallpaper.visibility),
                            Color.clear,
                            activePalette.atmosphericBase.opacity(0.55 * vignetteStrength * wallpaper.visibility)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Global translucency-exempt access point for surfaces that must remain solid
    /// (selection headers, fallback avatars, profile cards) while still reacting to
    /// the active environmental wallpaper color.
    static func environmentalSurfaceTint(isDark: Bool) -> Color {
        let palette = AppPreferences.shared.environmentalPalette
        return palette.atmosphericBase.opacity(isDark ? 0.85 : 0.55)
    }

    /// The single shared palette. Every background mode publishes its derived
    /// palette through `AppPreferences`, so the shell and all glass surfaces
    /// always render from the same wallpaper-derived color family.
    private var activePalette: EnvironmentalPalette {
        paletteStore.palette
    }

}

/// A quieter selection lens than regular glass nested inside sidebar glass.
/// Clear Liquid Glass avoids the system's milky white regular-glass wash;
/// tonal lift and a tiny leading marker keep selection legible at every hue.
struct EnvironmentalSelectionBackground: View {
    var cornerRadius: CGFloat = 10
    @ObservedObject private var paletteStore = EnvironmentalPaletteStore.shared
    @ObservedObject private var glassAppearanceStore = GlassAppearanceStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let palette = paletteStore.palette
        let isDark = colorScheme == .dark
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack(alignment: .leading) {
            if reduceTransparency {
                shape.fill(palette.opaqueSurface(isDark: isDark))
                shape.fill(palette.ambientHighlight.opacity(isDark ? 0.20 : 0.10))
            } else {
                shape.fill(Color.clear)
                    .glassEffect(.clear, in: shape)
                shape.fill(palette.ambientHighlight.opacity(isDark ? 0.14 : 0.10))
                shape.fill(palette.opaqueSurface(isDark: isDark)
                    .opacity(glassAppearanceStore.appearance.density))
            }
            Capsule()
                .fill(Color.primary.opacity(contrast == .increased ? 0.80 : 0.50))
                .frame(width: 2, height: 16)
                .padding(.leading, 3)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Suppresses only AppKit's painted List selection, not its selection model.
/// SwiftUI's tint does not override the focused macOS sidebar highlight (the
/// supplied screenshots show it behind our own pill). Attach this to a row so
/// the nearest table/outline is scoped to that List, never to global appearance.
struct NativeListSelectionAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> SelectionAnchor { SelectionAnchor() }

    func updateNSView(_ nsView: SelectionAnchor, context: Context) {
        nsView.scheduleSelectionAppearance()
    }

    final class SelectionAnchor: NSView {
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            scheduleSelectionAppearance()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleSelectionAppearance()
        }

        func scheduleSelectionAppearance() {
            DispatchQueue.main.async { [weak self] in
                var ancestor = self?.superview
                while let view = ancestor {
                    if let table = view as? NSTableView {
                        table.selectionHighlightStyle = .none
                        return
                    }
                    ancestor = view.superview
                }
            }
        }
    }
}

/// Shared native Button/Label row for contextual popovers. Keeps actions,
/// keyboard activation, disabled states, and destructive semantics at the call site.
struct GlassActionRow: View {
    let title: String
    let systemImage: String
    var role: ButtonRole? = nil
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(QuietHoverButtonStyle())
        .foregroundStyle(role == .destructive ? Color.red : Color.primary)
        .disabled(isDisabled)
    }
}

/// A tonal hover/press state, not another permanent rounded card.
struct QuietHoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration)
    }

    private struct HoverBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovering = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(isEnabled &&
                            (isHovering || configuration.isPressed) ? 0.07 : 0))
                }
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { isHovering = $0 }
                .animation(reduceMotion ? nil : GlassMetrics.interaction, value: isHovering)
        }
    }
}

/// Saturated accent circular send button matching Image 1
struct SendCircleButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                Circle().fill(
                    LinearGradient(
                        colors: [Color.caiPrimary, Color(red: 0.28, green: 0.38, blue: 0.96)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: Color.caiPrimary.opacity(0.40), radius: 6, x: 0, y: 2)
            }
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(reduceMotion ? nil : GlassMetrics.interaction, value: configuration.isPressed)
    }
}

/// AppKit bridge to control true macOS window-level transparency.
/// Configures NSWindow.isOpaque = false and NSWindow.backgroundColor = .clear
/// when Window Transparency > 0, allowing the real desktop to show through
/// the softened wallpaper and Liquid Glass. Respects macOS Reduce Transparency.
struct WindowTransparencyBridge: NSViewRepresentable {
    var transparency: Double
    var reduceTransparency: Bool

    func makeNSView(context: Context) -> TransparencyAnchor {
        TransparencyAnchor()
    }

    func updateNSView(_ nsView: TransparencyAnchor, context: Context) {
        nsView.update(transparency: transparency, reduceTransparency: reduceTransparency)
    }

    final class TransparencyAnchor: NSView {
        private var currentTransparency: Double = 0
        private var currentReduceTransparency: Bool = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func update(transparency: Double, reduceTransparency: Bool) {
            self.currentTransparency = transparency
            self.currentReduceTransparency = reduceTransparency
            apply()
        }

        private func apply() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                let shouldBeTransparent = self.currentTransparency > 0.001 && !self.currentReduceTransparency
                if shouldBeTransparent {
                    if window.isOpaque { window.isOpaque = false }
                    // Clear backing lets the shell’s environmentVisibility composite over the desktop.
                    // AppKit has only opaque/clear backing here; alphaValue is avoided so text stays crisp.
                    if window.backgroundColor != .clear { window.backgroundColor = .clear }
                    window.hasShadow = true
                } else {
                    if !window.isOpaque { window.isOpaque = true }
                    if window.backgroundColor != .windowBackgroundColor { window.backgroundColor = .windowBackgroundColor }
                }
                window.invalidateShadow()
            }
        }
    }
}
