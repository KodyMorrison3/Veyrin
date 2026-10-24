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
    private let characterService: CharacterService
    /// The signed-in username (typed session metadata - never the token).
    let username: String

    init(service: UserProfileService, username: String, library: LocalCharacterLibrary = .shared,
         characterService: CharacterService) {
        self.service = service
        self.username = username
        self.library = library
        self.characterService = characterService
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

    func savePublicCharactersToLibrary() async throws -> Int {
        guard case .loaded(let profile) = state else {
            throw LocalCharacterLibraryError.profileUnavailable
        }
        let characters = profile.publicCharacters.filter { character in
            guard let id = character.externalID else { return false }
            return !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return try await library.saveFromDiscover(characters, service: characterService)
    }
}
