//
//  LoginView.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 26/09/2026.
//

import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var authStore: AuthStore
    @ObservedObject private var preferences = AppPreferences.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @FocusState private var focusedField: Field?

    @State private var sessionToken = ""
    @State private var keychainError: String?
    @State private var isSigningIn = false
    @State private var webSessionCookie = ""
    @State private var isShowingWebSession = false
    @State private var webSessionError: String?
    @State private var hasSavedWebSessionCookie = false

    /// Sign-in needs only the token; the account ID and username are resolved
    /// from the validated session. The optional web session cookie is used
    /// solely for character search.
    private enum Field: Hashable {
        case token
    }

    private var trimmedToken: String {
        sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedWebSessionCookie: String {
        webSessionCookie.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                identity
                    .padding(.bottom, 26)

                Text("Welcome back")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)

                Text("Sign in to continue to Character.AI.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 5)
                    .padding(.bottom, 24)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        Text("Session token")
                            .font(.subheadline.weight(.semibold))
                        Text("Required")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    SecureField("Paste your session token", text: $sessionToken)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .token)
                        .submitLabel(.go)
                        .onSubmit(signIn)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Session token")
                        .accessibilityHint("Required to sign in. Press Return to continue.")
                }
                .padding(.bottom, 14)

                DisclosureGroup(isExpanded: $isShowingWebSession) {
                    VStack(alignment: .leading, spacing: 8) {
                        SecureField(
                            "Paste name=value or Cookie header",
                            text: $webSessionCookie
                        )
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .accessibilityLabel("Web session cookie")
                        .accessibilityHint("Optional. Used only for character search.")

                        Text("Optional. Character search needs a Character.AI web session cookie; other features use your session token. It is stored in the Keychain, sent only to character.ai, and should be treated like a password.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let webSessionError {
                            Label(webSessionError, systemImage: "exclamationmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if hasSavedWebSessionCookie {
                            HStack(spacing: 8) {
                                Label("Saved in Keychain", systemImage: "checkmark.seal.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 8)
                                Button("Remove") {
                                    do {
                                        try authStore.clearWebSessionCookie()
                                        hasSavedWebSessionCookie = false
                                        webSessionError = nil
                                    } catch {
                                        webSessionError = "Couldn't remove the saved cookie from Keychain."
                                    }
                                }
                                .buttonStyle(.plain)
                                .font(.caption)
                            }
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    HStack(spacing: 5) {
                        Text("Web session cookie")
                            .font(.subheadline.weight(.semibold))
                        Text("Optional")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.bottom, 20)

                if let errorMessage = keychainError ?? authStore.authMessage {
                    Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .combine)
                        .padding(.bottom, 12)
                }

                Button(action: signIn) {
                    Text("Sign In")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(GlassProminentButtonStyle())
                .controlSize(.large)
                .disabled(trimmedToken.isEmpty || isSigningIn)
                .accessibilityLabel("Sign in with session token")
                .padding(.bottom, 16)

                Label("Session token is stored in your macOS Keychain.", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityElement(children: .combine)
            }
            .frame(maxWidth: 410, alignment: .leading)
            .padding(28)
            .glassSurface(.sheet, cornerRadius: 18)
            .frame(maxWidth: .infinity, minHeight: 420, alignment: .center)
            .padding(24)
        }
        .scrollIndicators(.hidden)
        // Same shell as the main window and Settings: the environmental
        // background extends under the title bar and the window backing stays
        // clear so the background is not covered by a material slab.
        .background {
            ShellEnvironmentalBackground(vignetteStrength: 0.6)
                .ignoresSafeArea()
        }
        .containerBackground(.clear, for: .window)
        .background {
            WindowTransparencyBridge(
                transparency: preferences.windowTransparency,
                reduceTransparency: reduceTransparency
            )
        }
        .onAppear {
            focusedField = .token
            hasSavedWebSessionCookie = authStore.hasWebSessionCookie
        }
    }

    private var identity: some View {
        HStack(spacing: 11) {
            GlassIconTile(systemName: "bubble.left.and.bubble.right.fill")

            Text("Character.AI")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Character.AI")
    }

    /// The session is validated before it is saved or authenticated. On failure
    /// the token stays in the field so it can be corrected.
    private func signIn() {
        guard !trimmedToken.isEmpty, !isSigningIn else { return }
        isSigningIn = true
        keychainError = nil
        webSessionError = nil
        let cookie = trimmedWebSessionCookie

        Task {
            defer { isSigningIn = false }
            do {
                // Validate and store the optional search credential before
                // signing in, so a malformed paste is reported on this screen
                // instead of disappearing behind the authenticated UI.
                if !cookie.isEmpty {
                    try authStore.saveWebSessionCookie(cookie)
                    webSessionCookie = ""
                    hasSavedWebSessionCookie = true
                }
                try await authStore.signIn(sessionToken: trimmedToken)
                sessionToken = ""
            } catch let error as WebSessionCookieError {
                webSessionError = error.errorDescription
            } catch is CancellationError {
                // A newer sign-in attempt replaced this one.
            } catch SessionValidationError.invalidSession {
                keychainError = "Character.AI rejected this session token. Check that you copied the complete token and try again."
            } catch SessionValidationError.unavailable {
                keychainError = "Couldn't verify the session with Character.AI. Check your connection and try again."
            } catch SessionValidationError.accountIDUnavailable {
                keychainError = "Character.AI accepted the token but didn't return your account ID. Try signing in again."
            } catch {
                keychainError = "Couldn't save your credentials to Keychain. Please try again."
            }
        }
    }
}
