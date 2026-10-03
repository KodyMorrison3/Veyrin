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

struct SettingsView: View {
    @ObservedObject private var preferences = AppPreferences.shared
    @State private var selectedPane: SettingsPane = .account
    @State private var isConfirmingReset = false
    @State private var isShowingCharms = false

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
            List(selection: $selectedPane) {
                ForEach(SettingsPane.allCases) { pane in
                    Label(pane.title, systemImage: pane.systemImage)
                        .font(.body.weight(selectedPane == pane ? .semibold : .regular))
                        .listItemTint(.monochrome)
                        .tag(pane)
                }
            }
            .listStyle(.sidebar)
            .tint(Color.secondary.opacity(0.18))
            .scrollContentBackground(.hidden)
            .glassSurface(.navigation, cornerRadius: 0)
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
            .navigationTitle(selectedPane.title)
            .frame(minWidth: 480, minHeight: 380)
        }
        .background { ShellEnvironmentalBackground() }
        .sheet(isPresented: $isShowingCharms) {
            CharmsView(authStore: authStore)
                .frame(minWidth: 560, minHeight: 620)
        }
    }

    // MARK: Account

    private var accountPane: some View {
        Form {
            Section {
                LabeledContent("Signed in as") {
                    Text(username.isEmpty ? "Not signed in" : "@\(username)")
                }
                Button {
                    isShowingCharms = true
                } label: {
                    Label("View Charms", systemImage: "sparkles")
                }
            } header: {
                Text("Profile")
            } footer: {
                Text(
                    "Public profile details are available from the account menu in the sidebar. " +
                    "Account changes (email, password, subscription, deletion) are not supported by this app."
                )
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: Appearance

    private var appearancePane: some View {
        Form {
            Section {
                Picker("List & card avatars", selection: $preferences.avatarShape) {
                    ForEach(AvatarShape.allCases) { shape in
                        Text(shape.displayName).tag(shape)
                    }
                }
            } header: {
                Text("Avatars")
            } footer: {
                Text(
                    "Applies to sidebar conversation rows and Discover cards. " +
                    "In-chat avatars and the account control keep the standard circular look."
                )
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: Chat

    private var chatPane: some View {
        Form {
            Section {
                Text("No local chat preferences yet.")
                    .foregroundStyle(.secondary)
            } footer: {
                Text(
                    "Chat behaviour settings on Character.AI's side would require backend " +
                    "contracts this app has not confirmed, so none are shown here."
                )
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: Characters

    private var charactersPane: some View {
        Form {
            Section {
                Toggle("Show Popular & Trending in Discover", isOn: $preferences.showPopularTrending)
            } footer: {
                Text(
                    "Hides or shows the curated Popular characters and Trending " +
                    "characters sections in Discover."
                )
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: Notifications

    private var notificationsPane: some View {
        Form {
            Section {
                Text("Notifications are not available in this app.")
                    .foregroundStyle(.secondary)
            } footer: {
                Text(
                    "No confirmed Character.AI notification contract exists, so this app " +
                    "does not register for or display notifications."
                )
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: Privacy & Security

    private var privacyPane: some View {
        Form {
            Section {
                LabeledContent("Session storage") {
                    Text("Keychain")
                }
                LabeledContent("Session token") {
                    Text("Never displayed in the app")
                }
            } header: {
                Text("On this Mac")
            } footer: {
                Text(
                    "The session token is kept in the macOS Keychain and sent only as the " +
                    "Authorization header to Character.AI. Server-side privacy controls would " +
                    "require contracts this app has not confirmed."
                )
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: Advanced

    private var advancedPane: some View {
        Form {
            Section {
                Button("Reset Preferences", role: .destructive) {
                    isConfirmingReset = true
                }
            } footer: {
                Text(
                    "Restores all local preferences to their defaults. " +
                    "Your signed-in session is not affected."
                )
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
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
