import Foundation
import Combine

@MainActor
final class CharacterViewModel: ObservableObject {
    enum LoadState<Value> {
        case idle
        case loading
        case loaded(Value)
        case failed(String)
    }

    @Published private(set) var profileState: LoadState<CharacterProfile> = .idle
    @Published private(set) var similarState: LoadState<[SimilarCharacter]> = .idle

    private let service: CharacterService

    init(authStore: AuthStore) {
        service = CharacterService(
            httpClient: AuthenticatedHTTPClient(authStore: authStore)
        )
    }

    func load(externalID: String) async {
        profileState = .loading
        similarState = .loading

        let profileTask = Task {
            try await service.loadProfile(externalID: externalID)
        }
        let similarTask = Task {
            try await service.loadSimilarCharacters(externalID: externalID)
        }

        do {
            profileState = .loaded(try await profileTask.value)
        } catch {
            profileState = .failed(error.localizedDescription)
        }

        do {
            similarState = .loaded(try await similarTask.value)
        } catch {
            similarState = .failed(error.localizedDescription)
        }
    }
}
