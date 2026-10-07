//
//  LoginView.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 26/09/2026.
//

import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var authStore: AuthStore
    @FocusState private var focusedField: Field?

    @State private var sessionToken = ""
    @State private var username = ""
    @State private var userID = ""
    @State private var keychainError: String?

    private enum Field: Hashable {
        case token, username, userID
    }

    private var trimmedToken: String {
        sessionToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ZStack {
            ShellEnvironmentalBackground()
                .ignoresSafeArea()

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
                        fieldLabel("Session token", required: true)
                        SecureField("Paste your session token", text: $sessionToken)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .token)
                            .submitLabel(.go)
                            .onSubmit(signIn)
                            .autocorrectionDisabled()
                            .accessibilityLabel("Session token")
                            .accessibilityHint("Required to sign in. Press Return to continue.")
                    }
                    .padding(.bottom, 22)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Account details")
                                .font(.subheadline.weight(.semibold))
                            Text("Optional")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }

                        TextField("Username", text: $username)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .username)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .userID }
                            .autocorrectionDisabled()
                            .textContentType(.username)
                            .accessibilityLabel("Username, optional")

                        TextField("User ID", text: $userID)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .userID)
                            .submitLabel(.go)
                            .onSubmit(signIn)
                            .autocorrectionDisabled()
                            .accessibilityLabel("User ID, optional")
                    }
                    .padding(.bottom, 20)

                    if let keychainError {
                        Label(keychainError, systemImage: "exclamationmark.circle.fill")
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
                    .buttonStyle(.borderedProminent)
                    .tint(Color.caiPrimary)
                    .controlSize(.large)
                    .disabled(trimmedToken.isEmpty)
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
                .frame(maxWidth: .infinity, minHeight: 520, alignment: .center)
                .padding(24)
            }
            .scrollIndicators(.hidden)
        }
        .onAppear { focusedField = .token }
    }

    private var identity: some View {
        HStack(spacing: 11) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.caiPrimary)
                .frame(width: 34, height: 34)
                .background(Color.caiPrimary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)

            Text("Character.AI")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Character.AI")
    }

    private func fieldLabel(_ title: String, required: Bool) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            if required {
                Text("Required")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func signIn() {
        guard !trimmedToken.isEmpty else { return }
        let session = AuthSession(
            sessionToken: trimmedToken,
            userID: userID,
            username: username
        )

        do {
            try authStore.setSession(session)
            sessionToken = ""
            keychainError = nil
        } catch {
            keychainError = "Couldn't save the session to Keychain. Please try again."
        }
    }
}
