//
//  LoginView.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 26/09/2026.
//

import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var authStore: AuthStore

    @State private var sessionToken = ""
    @State private var username = ""
    @State private var userID = ""

    var body: some View {
        VStack(spacing: 20) {
            Text("Character.AI")
                .font(.largeTitle)
                .fontWeight(.semibold)

            Text("Development login")
                .foregroundStyle(.secondary)

            SecureField(
                "Session token",
                text: $sessionToken
            )
            .textFieldStyle(.roundedBorder)

            TextField(
                "Username",
                text: $username
            )
            .textFieldStyle(.roundedBorder)

            TextField(
                "User ID",
                text: $userID
            )
            .textFieldStyle(.roundedBorder)

            Button("Sign In") {
                signIn()
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                sessionToken.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
            )
        }
        .frame(width: 350)
        .padding(30)
    }

    private func signIn() {
        let token = sessionToken.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        let session = AuthSession(
            sessionToken: token,
            userID: userID,
            username: username
        )

        authStore.setSession(session)
    }
}
