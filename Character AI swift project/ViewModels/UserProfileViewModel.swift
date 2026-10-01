//
//  UserProfileViewModel.swift
//  Character AI swift project
//
//  Feature-local state for the User Profile section. Deliberately separate
//  from ChatViewModel; holds only public profile data — never the session
//  token.
//

import Foundation
import Combine

@MainActor
final class UserProfileViewModel: ObservableObject {
    enum LoadState {
        case idle
        case loading
        case loaded(UserProfile)
        case failed(String)
    }

    @Published private(set) var state: LoadState = .idle

    private let service: UserProfileService
    /// The signed-in username (typed session metadata — never the token).
    let username: String

    init(service: UserProfileService, username: String) {
        self.service = service
        self.username = username
    }

    func load() async {
        guard !username.isEmpty else {
            state = .failed("No signed-in username to load a profile for.")
            return
        }
        state = .loading
        do {
            state = .loaded(try await service.loadProfile(username: username))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
