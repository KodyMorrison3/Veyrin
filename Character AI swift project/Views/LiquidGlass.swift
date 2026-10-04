import AppKit
import Combine
import SwiftUI

/// Shared Design System Tokens (matching Image 1 target specifications)
extension Color {
    static let caiPrimary = Color(red: 0.482, green: 0.549, blue: 1.0)       // #7B8CFF
    static let caiAccent = Color(red: 0.431, green: 0.906, blue: 1.0)        // #6EE7FF
    static let caiSurface = Color(red: 0.102, green: 0.122, blue: 0.243)      // #1A1F3E
    static let caiGlass = Color(red: 0.176, green: 0.196, blue: 0.388)        // #2D3263
    static let caiText = Color(red: 0.949, green: 0.957, blue: 1.0)          // #F2F4FF
    static let caiMuted = Color(red: 0.631, green: 0.627, blue: 0.714)       // #A1A0B6
    static let caiBackground = Color(red: 0.059, green: 0.071, blue: 0.149)  // #0F1226
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

    var material: Material {
        switch self {
        case .navigation, .userMessage, .searchField, .characterHeader: .ultraThin
        case .floatingControl, .characterMessage: .thin
        case .popover, .sheet: .regular
        }
    }

    func tint(isDark: Bool, palette: EnvironmentalPalette = AppPreferences.shared.environmentalPalette) -> Color {
        let baseTint = palette.glassSurfaceTint
        switch self {
        case .characterMessage:
            return baseTint.opacity(isDark ? 0.62 : 0.48)
        case .userMessage:
            return baseTint.opacity(isDark ? 0.50 : 0.34)
        case .navigation:
            return baseTint.opacity(isDark ? 0.38 : 0.30)
        case .searchField:
            return baseTint.opacity(isDark ? 0.28 : 0.20)
        case .characterHeader:
            // Rendered via system glass; fallback only for Reduce Transparency.
            return baseTint.opacity(isDark ? 0.55 : 0.40)
        case .floatingControl:
            return baseTint.opacity(isDark ? 0.82 : 0.65)
        case .popover, .sheet:
            return baseTint.opacity(isDark ? 0.92 : 0.85)
        }
    }
}

/// Roles rendered with true system Liquid Glass (sampling in-window
/// content) rather than a behind-window material wash.
private extension GlassSurfaceRole {
    var usesSystemGlass: Bool {
        self == .navigation || self == .searchField || self == .characterHeader
    }

    /// Restrained tints for system-glass roles derived from the active environment.
    /// Search sits inside the navigation panel, so it stays lighter to read as one
    /// coherent surface. The character header floats over the environment, so it
    /// stays lighter still: the blurred wallpaper reads through instead of an opaque wash.
    func systemGlassTint(isDark: Bool, palette: EnvironmentalPalette = AppPreferences.shared.environmentalPalette) -> Color {
        let baseTint = palette.glassSurfaceTint
        switch self {
        case .searchField:
            return baseTint.opacity(isDark ? 0.16 : 0.12)
        case .characterHeader:
            return baseTint.opacity(isDark ? 0.12 : 0.08)
        default:
            return baseTint.opacity(isDark ? 0.32 : 0.24)
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

    @ObservedObject private var preferences = AppPreferences.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isDark: Bool { colorScheme == .dark }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        // Observed so every glass surface re-renders the moment the shared
        // environmental palette changes (wallpaper, solid colour, artwork).
        let palette = preferences.environmentalPalette
        ZStack {
            if reduceTransparency {
                shape.fill(palette.glassSurfaceTint)
            } else if role.usesSystemGlass {
                // Navigation panels and the search capsule are true system
                // Liquid Glass: the environmental background reads through
                // with a restrained tint instead of a stacked opaque
                // wash, so the sidebar stays one coherent surface.
                shape.fill(Color.clear)
                    .glassEffect(
                        Glass.regular.tint(role.systemGlassTint(isDark: isDark, palette: palette)),
                        in: shape
                    )
            } else {
                shape.fill(role.material)
                shape.fill(role.tint(isDark: isDark, palette: palette))

                if role == .userMessage {
                    // Board: user bubbles read brighter/neutral against the
                    // indigo character surface. One recipe, a white lift only.
                    shape.fill(Color.white.opacity(isDark ? 0.14 : 0.20))
                }

                // Subtle top-leading rim light for native Liquid Glass depth
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(role == .userMessage ? 0.14 : (isDark ? 0.08 : 0.12)),
                            Color.white.opacity(0.02)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.75
                )
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

/// Unified global environmental background system.
///
/// Serves as the single source of truth across the entire app:
/// 1. Default: Heavy blur (~36pt) on character avatar/artwork as an environmental
///    color/light source rather than something clearly visible.
/// 2. Custom Wallpaper: Noticeably lighter/moderate blur (~15pt, within 12–18pt) so the user's
///    wallpaper remains recognizable and visually present while softened for Liquid Glass.
/// 3. Solid Colour: No image blur; solid base with atmospheric/vignette treatment.
/// Default-mode artwork extraction lives in `AppPreferences`
/// (`updateDefaultEnvironment(forAvatarURL:)`) so that every surface reads a
/// single shared palette instead of each view deriving its own environment.
struct ShellEnvironmentalBackground: View {
    var artwork: Image? = nil
    var avatarURL: URL? = nil
    /// Scales the readability vignette. The default preserves the main
    /// window; secondary surfaces (e.g. Settings) pass a lower value so the
    /// blurred environment contributes visibly rather than reading as a dark slab.
    var vignetteStrength: Double = 1.0

    @ObservedObject private var preferences = AppPreferences.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                activePalette.atmosphericBase

                if !reduceTransparency {
                    switch preferences.backgroundMode {
                    case .customWallpaper:
                        if let customImage = preferences.customWallpaper {
                            Image(nsImage: customImage)
                                .resizable()
                                .scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .clipped()
                                .saturation(0.95)
                                .blur(radius: 15, opaque: true)
                                .opacity(isDark ? 0.85 : 0.60)
                        } else {
                            defaultArtworkView(geometry: geometry)
                        }

                    case .solidColor:
                        // In solid color mode, the solid color base fills the environment.
                        // We provide a soft atmospheric texture over it.
                        preferences.solidColor
                            .opacity(isDark ? 0.90 : 0.75)

                    case .default:
                        defaultArtworkView(geometry: geometry)
                    }
                }

                // Vignette gradient for text readability and depth using the dynamic atmospheric base
                LinearGradient(
                    colors: [
                        activePalette.atmosphericBase.opacity(0.40 * vignetteStrength),
                        Color.clear,
                        activePalette.atmosphericBase.opacity(0.55 * vignetteStrength)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                // Atmospheric ambient lighting dynamically tinted from the active environment
                // Top-trailing highlight using ambientHighlight and ambientColor
                RadialGradient(
                    colors: [
                        activePalette.ambientHighlight.opacity(isDark ? 0.16 : 0.08),
                        activePalette.ambientColor.opacity(isDark ? 0.10 : 0.05),
                        Color.clear
                    ],
                    center: .topTrailing,
                    startRadius: 0,
                    endRadius: max(geometry.size.width, geometry.size.height) * 0.75
                )
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            preferences.updateDefaultEnvironment(forAvatarURL: avatarURL)
        }
        .onChange(of: avatarURL) { _, newURL in
            preferences.updateDefaultEnvironment(forAvatarURL: newURL)
        }
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
        preferences.environmentalPalette
    }

    @ViewBuilder
    private func defaultArtworkView(geometry: GeometryProxy) -> some View {
        if let artwork {
            artwork
                .resizable()
                .scaledToFill()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .saturation(0.90)
                .blur(radius: 36, opaque: true)
                .opacity(isDark ? 0.80 : 0.55)
        } else if let avatarURL {
            AsyncImage(url: avatarURL) { phase in
                if case .success(let image) = phase {
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .saturation(0.90)
                        .blur(radius: 36, opaque: true)
                        .opacity(isDark ? 0.80 : 0.55)
                }
            }
        }
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
