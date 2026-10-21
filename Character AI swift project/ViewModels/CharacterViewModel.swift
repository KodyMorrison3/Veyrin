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
    private var loadID: UUID?
    private var sessionGeneration: UUID?

    init(service: CharacterService) {
        self.service = service
    }

    convenience init(authStore: AuthStore) {
        self.init(service: CharacterService(
            httpClient: AuthenticatedHTTPClient(authStore: authStore)
        ))
    }

    func load(externalID: String) async {
        let id = UUID()
        let session = service.sessionGeneration
        loadID = id
        sessionGeneration = session
        profileState = .loading
        similarState = .loading

        async let profile = service.loadProfile(externalID: externalID)
        async let similar = service.loadSimilarCharacters(externalID: externalID)

        // Task cancellation is best-effort; the generation guard also prevents
        // a late response from replacing state for a newer navigation target.
        do {
            let loaded = try await profile
            guard loadID == id, sessionGeneration == session, !Task.isCancelled else { return }
            profileState = .loaded(loaded)
        } catch is CancellationError {
            return
        } catch {
            guard loadID == id, sessionGeneration == session, !Task.isCancelled else { return }
            profileState = .failed(error.localizedDescription)
        }

        do {
            let loaded = try await similar
            guard loadID == id, sessionGeneration == session, !Task.isCancelled else { return }
            similarState = .loaded(loaded)
        } catch is CancellationError {
            return
        } catch {
            guard loadID == id, sessionGeneration == session, !Task.isCancelled else { return }
            similarState = .failed(error.localizedDescription)
        }
    }
}
