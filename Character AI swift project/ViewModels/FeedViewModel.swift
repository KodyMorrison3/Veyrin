import Combine
import Foundation

@MainActor
final class FeedViewModel: ObservableObject {
    @Published private(set) var response: FeedResponse?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let service: FeedService
    private var didLoad = false

    init(service: FeedService) {
        self.service = service
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            response = try await service.loadSocialFeed()
            didLoad = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func retry() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            response = try await service.loadSocialFeed(forceRefresh: true)
            didLoad = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var shouldLoad: Bool { !didLoad && !isLoading }
}
