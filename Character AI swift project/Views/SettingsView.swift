//
//  SettingsView.swift
//  Character AI swift project
//
//  Feature-local native macOS Settings window. Panes map only to what the
//  app actually supports today: local client preferences where they make
//  sense (Appearance avatars, Characters content toggles, Advanced reset),
//  and clearly-marked unavailable sections where Character.AI account
//  settings would need undocumented backend contracts (Account, Chat,
//  Notifications, Privacy & Security). No fake controls.
//

import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject private var preferences = AppPreferences.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("preferences.includeBetaReleases") private var includeBetaReleases = false
    @State private var selectedPane: SettingsPane = .account
    @State private var isConfirmingReset = false
    @State private var isShowingCharms = false
    @State private var latestRelease: GitHubRelease?
    @State private var releaseCheckMessage: String?
    @State private var isCheckingForUpdates = false

    /// The signed-in username (typed session metadata — never the token),
    /// injected by the app so the Account pane can state who is signed in.
    let username: String
    let authStore: AuthStore

    enum SettingsPane: String, CaseIterable, Identifiable {
        case account, appearance, chat, characters, notifications, privacy, advanced

        var id: String { rawValue }

        var title: String {
            switch self {
            case .account: return "Account"
            case .appearance: return "Appearance"
            case .chat: return "Chat"
            case .characters: return "Characters"
            case .notifications: return "Notifications"
            case .privacy: return "Privacy & Security"
            case .advanced: return "Advanced"
            }
        }

        var systemImage: String {
            switch self {
            case .account: return "person.crop.circle"
            case .appearance: return "paintbrush"
            case .chat: return "bubble.left.and.bubble.right"
            case .characters: return "theatermasks"
            case .notifications: return "bell"
            case .privacy: return "lock.shield"
            case .advanced: return "gearshape.2"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            // Custom glass navigation (not a native List): the native
            // sidebar selection renders as a bright opaque blue pill that
            // contradicts the Liquid Glass direction. Rows mirror the main
            // conversation sidebar's restrained accent-tinted glass pill.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsPane.allCases) { pane in
                    Button {
                        selectedPane = pane
                    } label: {
                        Label(pane.title, systemImage: pane.systemImage)
                            .font(.body.weight(selectedPane == pane ? .semibold : .regular))
                            .foregroundStyle(selectedPane == pane ? Color.primary : Color.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background {
                                settingsRowBackground(isSelected: selectedPane == pane)
                            }
                    }
                    .buttonStyle(QuietHoverButtonStyle())
                    .accessibilityAddTraits(selectedPane == pane ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            // No panel behind the rows: they float directly on the window
            // material so the sidebar never reads as a separate dark bar.
            .navigationSplitViewColumnWidth(180)
        } detail: {
            Group {
                switch selectedPane {
                case .account: accountPane
                case .appearance: appearancePane
                case .chat: chatPane
                case .characters: charactersPane
                case .notifications: notificationsPane
                case .privacy: privacyPane
                case .advanced: advancedPane
                }
            }
            .frame(minWidth: 480, minHeight: 380)
        }
        // Seamless frosted window: uses the unified ShellEnvironmentalBackground
        // with reduced vignette so the environmental wallpaper softly anchors the window
        // while remaining responsive to wallpaper color. No behind-window material
        // may sample an unrelated desktop colour.
        // Both layers ignore the safe area so the glass extends under the title
        // bar: the title reads as text over the environment instead of a dark
        // system-material slab.
        .background {
            ShellEnvironmentalBackground(vignetteStrength: 0.6)
                .ignoresSafeArea()
        }
        // Keep native toolbar behaviour but remove the default window-wide
        // material shelf (same treatment as the main window). The older
        // .toolbarBackground(.hidden, for:) API does not suppress the
        // system Liquid Glass shelf on recent macOS.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .containerBackground(.clear, for: .window)
        .background {
            WindowTransparencyBridge(
                transparency: preferences.windowTransparency,
                reduceTransparency: reduceTransparency
            )
        }
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }

    // MARK: - Shared presentation

    /// Restrained selected-state pill mirroring the main conversation
    /// sidebar: translucent accent-tinted glass, never an opaque blue
    /// rectangle. Unselected rows are intentionally bare glass.
    @ViewBuilder
    private func settingsRowBackground(isSelected: Bool) -> some View {
        if isSelected {
            EnvironmentalSelectionBackground(cornerRadius: 9)
        }
    }

    /// One cardless section: title, setting rows separated by dividers,
    /// footnote footer — glass environment behind, never nested cards.
    private func settingsSection<Content: View>(
        title: String? = nil,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.headline)
            }
            content()
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    // MARK: Account

    private var accountPane: some View {
        ScrollView {
            settingsSection(
                title: "Profile",
                footer: "Public profile details are available from the account menu in the sidebar. " +
                    "Account changes (email, password, subscription, deletion) are not supported by this app."
            ) {
                HStack {
                    Text("Signed in as")
                    Spacer()
                    Text(username.isEmpty ? "Not signed in" : "@\(username)")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                Divider()
                Button {
                    isShowingCharms = true
                } label: {
                    Label("View Charms", systemImage: "sparkles")
                }
                .padding(.vertical, 6)
                .popover(isPresented: $isShowingCharms) {
                    CharmsView(authStore: authStore)
                        .frame(width: 560, height: 600)
                }
            }
        }
    }

    // MARK: Appearance

    private var appearancePane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                settingsSection(
                    title: "Environment & Wallpaper",
                    footer: "Select how the environmental background behind Liquid Glass is derived. " +
                        "Solid Colour provides an atmospheric base colour underneath the glass; " +
                        "Custom Wallpaper blurs your chosen image."
                ) {
                    Picker("Background Mode", selection: $preferences.backgroundMode) {
                        ForEach(BackgroundMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.vertical, 4)

                    switch preferences.backgroundMode {
                    case .customWallpaper:
                        VStack(alignment: .leading, spacing: 10) {
                            if let wallpaper = preferences.customWallpaper {
                                HStack(spacing: 12) {
                                    Image(nsImage: wallpaper)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 80, height: 50)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                                        )

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Custom Wallpaper Active")
                                            .font(.subheadline.weight(.medium))
                                        Text("Atmospheric blur and ambient tint are derived from this image.")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 4)
                            }

                            HStack(spacing: 10) {
                                Button {
                                    chooseCustomWallpaper()
                                } label: {
                                    Label(
                                        preferences.customWallpaper == nil ? "Choose Image…" : "Change Image…",
                                        systemImage: "photo"
                                    )
                                }

                                if preferences.customWallpaper != nil {
                                    Button("Remove Wallpaper", role: .destructive) {
                                        preferences.clearCustomWallpaper()
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }

                    case .solidColor:
                        HStack(spacing: 12) {
                            ColorPicker("Environmental Colour", selection: $preferences.solidColor, supportsOpacity: false)
                                .padding(.vertical, 4)

                            Button("Reset to Midnight") {
                                preferences.solidColor = Color(red: 0.059, green: 0.071, blue: 0.149)
                            }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }

                }

                settingsSection(
                    title: "Environmental Materials",
                    footer: reduceTransparency
                        ? "Reduce Transparency is enabled in macOS. Translucent effects are replaced with opaque, readable surfaces; your saved choices are retained."
                        : "Window Transparency adjusts the environmental background strength. Glass Opacity adjusts all shared Liquid Glass surfaces. Wallpaper Blur softens background images. Window backing remains clear/opaque to avoid dimming text and controls."
                ) {
                    // 1. Wallpaper Blur
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Wallpaper Blur")
                            Spacer()
                            Text(preferences.backgroundMode == .solidColor
                                 ? "Not applied to Solid Colour"
                                 : "\(Int(preferences.wallpaperBlur)) pt · \(preferences.wallpaperBlurOverride == nil ? "Automatic" : "Manual")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { preferences.wallpaperBlur },
                            set: { preferences.wallpaperBlur = $0 }
                        ), in: AppPreferences.wallpaperBlurRange, step: 1) {
                            Text("Wallpaper Blur")
                        } minimumValueLabel: { Text("0 pt") }
                          maximumValueLabel: { Text("40 pt") }
                        .accessibilityValue("\(Int(preferences.wallpaperBlur)) points")
                        .disabled(reduceTransparency || preferences.backgroundMode == .solidColor)

                        Button("Reset to Default") { preferences.resetWallpaperBlur() }
                            .accessibilityLabel("Reset Wallpaper Blur to Default")
                            .disabled(preferences.wallpaperBlurOverride == nil)
                        Text("Automatic: custom wallpaper 10 pt. Moving the slider overrides it until reset.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Divider().padding(.vertical, 4)

                    // 2. Glass Opacity
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Glass Opacity")
                            Spacer()
                            Text("\(Int((preferences.glassOpacity * 100).rounded()))%")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { preferences.glassOpacity },
                            set: { preferences.glassOpacity = $0 }
                        ), in: AppPreferences.glassOpacityRange, step: 0.01) {
                            Text("Glass Opacity")
                        } minimumValueLabel: { Text("More wallpaper") }
                          maximumValueLabel: { Text("More glass") }
                        .accessibilityValue("\(Int((preferences.glassOpacity * 100).rounded())) percent")
                        .disabled(reduceTransparency)

                        Button("Reset to Default") { preferences.resetGlassOpacity() }
                            .accessibilityLabel("Reset Glass Opacity to Default")
                            .disabled(abs(preferences.glassOpacity - AppPreferences.defaultGlassOpacity) < 0.001)
                        Text("One shared control for Liquid Glass surface density and tint across navigation, message bubbles, composer, and floating controls.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Divider().padding(.vertical, 4)

                    // 3. Window Transparency
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Window Transparency")
                            Spacer()
                            Text("\(Int((preferences.windowTransparency * 100).rounded()))%")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { preferences.windowTransparency },
                            set: { preferences.windowTransparency = $0 }
                        ), in: AppPreferences.windowTransparencyRange, step: 0.01) {
                            Text("Window Transparency")
                        } minimumValueLabel: { Text("Opaque (0%)") }
                          maximumValueLabel: { Text("80%") }
                        .accessibilityValue("\(Int((preferences.windowTransparency * 100).rounded())) percent")
                        .disabled(reduceTransparency)

                        Button("Reset to Default") { preferences.resetWindowTransparency() }
                            .accessibilityLabel("Reset Window Transparency to Default")
                            .disabled(abs(preferences.windowTransparency - AppPreferences.defaultWindowTransparency) < 0.001)
                        Text("Adjusts the wallpaper/environment foundation, not the alpha of the whole application window. AppKit's window backing is clear or opaque; whole-window alpha is avoided so text and controls remain crisp.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                settingsSection(
                    title: "Avatars",
                    footer: "Applies to sidebar conversation rows and Discover cards. " +
                        "In-chat avatars and the account control keep the standard circular look."
                ) {
                    Picker("List & card avatars", selection: $preferences.avatarShape) {
                        ForEach(AvatarShape.allCases) { shape in
                            Text(shape.displayName).tag(shape)
                        }
                    }
                    .pickerStyle(.menu)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private func chooseCustomWallpaper() {
        let panel = NSOpenPanel()
        panel.title = "Select Custom Wallpaper"
        panel.message = "Choose an image to use as the environmental Liquid Glass background."
        panel.prompt = "Set Wallpaper"
        panel.allowedContentTypes = [.png, .jpeg, .heic, .webP, .gif]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            preferences.setCustomWallpaper(from: url)
        }
    }

    // MARK: Chat

    private var chatPane: some View {
        ScrollView {
            settingsSection(
                footer: "Chat behaviour settings on Character.AI's side would require backend " +
                    "contracts this app has not confirmed, so none are shown here."
            ) {
                Text("No local chat preferences yet.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
        }
    }

    // MARK: Characters

    private var charactersPane: some View {
        ScrollView {
            settingsSection(
                footer: "Hides or shows the curated Popular characters and Trending " +
                    "characters sections in Discover."
            ) {
                Toggle("Show Popular & Trending in Discover", isOn: $preferences.showPopularTrending)
                    .padding(.vertical, 6)
            }
        }
    }

    // MARK: Notifications

    private var notificationsPane: some View {
        ScrollView {
            settingsSection(
                footer: "No confirmed Character.AI notification contract exists, so this app " +
                    "does not register for or display notifications."
            ) {
                Text("Notifications are not available in this app.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
        }
    }

    // MARK: Privacy & Security

    private var privacyPane: some View {
        ScrollView {
            settingsSection(
                title: "On this Mac",
                footer: "The session token is kept in the macOS Keychain and sent only as the " +
                    "Authorization header to Character.AI. Server-side privacy controls would " +
                    "require contracts this app has not confirmed."
            ) {
                HStack {
                    Text("Session storage")
                    Spacer()
                    Text("Keychain")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                Divider()
                HStack {
                    Text("Session token")
                    Spacer()
                    Text("Never displayed in the app")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: Advanced

    private func checkForUpdates() {
        isCheckingForUpdates = true
        releaseCheckMessage = nil

        Task {
            defer { isCheckingForUpdates = false }
            do {
                let release = try await GitHubReleaseService()
                    .latestRelease(includeBeta: includeBetaReleases)
                latestRelease = release
                let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                switch release.isNewerVersion(than: currentVersion ?? "") {
                case true:
                    releaseCheckMessage = "A newer version is available."
                case false:
                    releaseCheckMessage = "You already have the latest version."
                case nil:
                    releaseCheckMessage = "Release found. Current app version could not be compared."
                }
            } catch is CancellationError {
                releaseCheckMessage = nil
            } catch {
                latestRelease = nil
                releaseCheckMessage = error.localizedDescription
            }
        }
    }

    private var advancedPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                settingsSection(
                    title: "Updates",
                    footer: "Checks GitHub for the latest official release. Enable beta releases to include newer releases marked as pre-release. This works when the repository is public."
                ) {
                    Toggle("Include beta releases", isOn: $includeBetaReleases)
                        .padding(.vertical, 4)

                    Button {
                        checkForUpdates()
                    } label: {
                        if isCheckingForUpdates {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.trailing, 4)
                            Text("Checking for Updates…")
                        } else {
                            Label("Check for Updates", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(isCheckingForUpdates)
                    .padding(.vertical, 4)

                    if let releaseCheckMessage {
                        Text(releaseCheckMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    if let latestRelease {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(latestRelease.displayVersion)
                                    .font(.subheadline.weight(.medium))
                                if latestRelease.isBeta {
                                    Text("Beta")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.caiPrimary.opacity(0.18), in: Capsule())
                                }
                            }

                            if let notes = latestRelease.body, !notes.isEmpty {
                                Text(notes)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(8)
                                    .textSelection(.enabled)
                            }

                            Link(destination: latestRelease.htmlURL) {
                                Label("View Release on GitHub", systemImage: "arrow.up.right.square")
                            }
                        }
                        .padding(.top, 4)
                    }
                }

                settingsSection(
                    footer: "Restores all local preferences to their defaults. " +
                        "Your signed-in session is not affected."
                ) {
                    Button("Reset Preferences", role: .destructive) {
                        isConfirmingReset = true
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .confirmationDialog(
            "Reset all preferences to their defaults?",
            isPresented: $isConfirmingReset,
            titleVisibility: .visible
        ) {
            Button("Reset Preferences", role: .destructive) {
                preferences.resetToDefaults()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
