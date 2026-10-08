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

    @Published private(set) var profileState: LoadState<CharacterProfile> = .idle {
        didSet { ProfileNavigationTrace.log("profile state=\(Self.describe(profileState))") }
    }
    @Published private(set) var similarState: LoadState<[SimilarCharacter]> = .idle

    private let service: CharacterService

    init(service: CharacterService) {
        self.service = service
    }

    convenience init(authStore: AuthStore) {
        self.init(service: CharacterService(
            httpClient: AuthenticatedHTTPClient(authStore: authStore)
        ))
    }

    private static func describe(_ state: LoadState<CharacterProfile>) -> String {
        switch state {
        case .idle: "idle"
        case .loading: "loading"
        case .loaded(let profile): "loaded:\(profile.externalID)"
        case .failed: "failed"
        }
    }

    func load(externalID: String) async {
        ProfileNavigationTrace.log("load start requested=\(externalID)")
        defer { ProfileNavigationTrace.log("load end requested=\(externalID) cancelled=\(Task.isCancelled)") }
        profileState = .loading
        similarState = .loading

        async let profile = service.loadProfile(externalID: externalID)
        async let similar = service.loadSimilarCharacters(externalID: externalID)

        // Navigating to another character cancels this load; a cancelled load must
        // not overwrite the state of the character that replaced it.
        do {
            let loaded = try await profile
            guard !Task.isCancelled else { return }
            profileState = .loaded(loaded)
        } catch {
            guard !Task.isCancelled else { return }
            profileState = .failed(error.localizedDescription)
        }

        do {
            let loaded = try await similar
            guard !Task.isCancelled else { return }
            similarState = .loaded(loaded)
        } catch {
            guard !Task.isCancelled else { return }
            similarState = .failed(error.localizedDescription)
        }
    }
}
