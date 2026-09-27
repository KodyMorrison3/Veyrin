//
//  AuthStore.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 26/09/2026.
//

import Foundation
import Combine

@MainActor
final class AuthStore: ObservableObject {
    @Published private(set) var session: AuthSession?

    private let keychainStore: KeychainStore
    private let sessionKey = "authSession"

    var isAuthenticated: Bool {
        session != nil
    }

    init(keychainStore: KeychainStore = KeychainStore()) {
        self.keychainStore = keychainStore
    }

    func setSession(_ session: AuthSession) {
        self.session = session

        do {
            let data = try JSONEncoder().encode(session)

            try keychainStore.save(
                data,
                forKey: sessionKey
            )

            print("AUTH SESSION SAVED")
        } catch {
            print("FAILED TO SAVE AUTH SESSION:", error)
        }
    }

    func loadStoredSession() {
        print("LOADING STORED SESSION")

        do {
            guard let data = try keychainStore.loadData(
                forKey: sessionKey
            ) else {
                print("NO STORED AUTH SESSION")
                return
            }

            let session = try JSONDecoder().decode(
                AuthSession.self,
                from: data
            )

            self.session = session

            print("STORED AUTH SESSION LOADED")
        } catch {
            print("FAILED TO LOAD STORED AUTH SESSION:", error)
        }
    }

    func clearSession() {
        session = nil

        do {
            try keychainStore.delete(
                forKey: sessionKey
            )

            print("AUTH SESSION CLEARED")
        } catch {
            print("FAILED TO CLEAR AUTH SESSION:", error)
        }
    }
}
