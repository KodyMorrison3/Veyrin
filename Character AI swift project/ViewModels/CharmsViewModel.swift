//
//  CharmsViewModel.swift
//  Character AI swift project
//
//  Read-only Charms state for Settings. Network calls stay in CharmsService.
//

import Foundation
import Combine

@MainActor
final class CharmsViewModel: ObservableObject {
    enum LoadState {
        case idle
        case loading
        case loaded(transactions: [CharmTransaction], quests: [CharmQuest])
        case empty
        case failed(String)
    }

    @Published private(set) var state: LoadState = .idle

    private let authStore: AuthStore
    private let service: CharmsService

    init(authStore: AuthStore, service: CharmsService? = nil) {
        self.authStore = authStore
        self.service = service ?? CharmsService(authStore: authStore)
    }

    func load() async {
        await load(force: false)
    }

    func refresh() async {
        await load(force: true)
    }

    private func load(force: Bool) async {
        if !force, case .loading = state { return }

        guard let userID = authStore.session?.userID, !userID.isEmpty else {
            state = .failed("Sign in to load Charms.")
            return
        }

        state = .loading
        do {
            async let transactions = service.loadTransactions(userID: userID)
            async let quests = service.loadQuests(userID: userID)
            let (loadedTransactions, loadedQuests) = try await (transactions, quests)

            if loadedTransactions.isEmpty && loadedQuests.isEmpty {
                state = .empty
            } else {
                state = .loaded(
                    transactions: loadedTransactions,
                    quests: loadedQuests
                )
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
