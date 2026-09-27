//
//  AuthService.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 26/09/2026.
//

import Foundation

struct AuthService {
    private let authStore: AuthStore

    init(authStore: AuthStore) {
        self.authStore = authStore
    }

    func signOut() {
        authStore.clearSession()
    }
}
