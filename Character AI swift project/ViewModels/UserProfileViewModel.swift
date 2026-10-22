//
//  UserProfileViewModel.swift
//  Character AI swift project
//
//  Feature-local state for the User Profile section. Deliberately separate
//  from ChatViewModel; holds only public profile data - never the session
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
    private let library: LocalCharacterLibrary
    /// The signed-in username (typed session metadata - never the token).
    let username: String

    init(service: UserProfileService, username: String, library: LocalCharacterLibrary = .shared) {
        self.service = service
        self.username = username
        self.library = library
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

    func savePublicCharactersToLibrary() throws -> Int {
        guard case .loaded(let profile) = state else {
            throw LocalCharacterLibraryError.profileUnavailable
        }
        let characters = profile.publicCharacters.filter { character in
            guard let id = character.externalID else { return false }
            return !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return try library.saveFromDiscover(characters)
    }
}
