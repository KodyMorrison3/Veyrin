import AppKit
import SwiftUI

/// Shared Design System Tokens (matching Image 1 target specifications)
extension Color {
    static let caiPrimary = Color(red: 0.482, green: 0.549, blue: 1.0)       // #7B8CFF
    static let caiAccent = Color(red: 0.431, green: 0.906, blue: 1.0)        // #6EE7FF
    static let caiSurface = Color(red: 0.102, green: 0.122, blue: 0.200)      // #1A1F33
    static let caiGlass = Color(red: 0.165, green: 0.184, blue: 0.333)        // #2A2F55
    static let caiText = Color(red: 0.949, green: 0.957, blue: 1.0)          // #F2F4FF
    static let caiMuted = Color(red: 0.631, green: 0.627, blue: 0.714)       // #A1A0B6
    static let caiBackground = Color(red: 0.055, green: 0.067, blue: 0.118)  // #0E111E
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
    case navigation, floatingControl, popover, sheet, characterMessage, userMessage

    var material: Material {
        switch self {
        case .navigation, .userMessage: .ultraThin
        case .floatingControl, .characterMessage: .thin
        case .popover, .sheet: .regular
        }
    }

    func tint(isDark: Bool) -> Color {
        switch self {
        case .characterMessage:
            Color.caiSurface.opacity(isDark ? 0.85 : 0.70)
        case .userMessage:
            Color.caiGlass.opacity(isDark ? 0.75 : 0.50)
        case .navigation:
            Color.caiSurface.opacity(isDark ? 0.70 : 0.50)
        case .floatingControl:
            Color.caiSurface.opacity(isDark ? 0.82 : 0.65)
        case .popover, .sheet:
            Color.caiSurface.opacity(isDark ? 0.92 : 0.85)
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

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isDark: Bool { colorScheme == .dark }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack {
            if reduceTransparency {
                shape.fill(Color.caiSurface)
            } else {
                shape.fill(role.material)
            }
            shape.fill(role.tint(isDark: isDark))

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

            if isFocused {
                shape.strokeBorder(Color.caiPrimary.opacity(0.6), lineWidth: 1)
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

/// Artwork is supplied by an image already loaded or an avatar URL.
/// Softened, blurred, and tinted so text remains 100% readable while
/// creating the rich atmospheric environment from Image 1.
struct ShellEnvironmentalBackground: View {
    var artwork: Image? = nil
    var avatarURL: URL? = nil

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.caiBackground

                if !reduceTransparency {
                    if let artwork {
                        artwork
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                            .saturation(0.85)
                            .blur(radius: 45)
                            .opacity(isDark ? 0.35 : 0.20)
                    } else if let avatarURL {
                        AsyncImage(url: avatarURL) { phase in
                            if case .success(let image) = phase {
                                image
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: geometry.size.width, height: geometry.size.height)
                                    .clipped()
                                    .saturation(0.85)
                                    .blur(radius: 45)
                                    .opacity(isDark ? 0.35 : 0.20)
                            }
                        }
                    }
                }

                // Vignette gradient for text readability and depth
                LinearGradient(
                    colors: [
                        Color.caiBackground.opacity(0.70),
                        Color.clear,
                        Color.caiBackground.opacity(0.80)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                // Atmospheric ambient lighting
                RadialGradient(
                    colors: [Color.caiPrimary.opacity(isDark ? 0.09 : 0.04), .clear],
                    center: .topTrailing,
                    startRadius: 0,
                    endRadius: max(geometry.size.width, geometry.size.height) * 0.7
                )
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
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
