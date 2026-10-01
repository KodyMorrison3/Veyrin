import Foundation
import Combine

@MainActor
final class DiscoverViewModel: ObservableObject {
    @Published private(set) var feedItems: [DiscoverFeedItem] = []
    @Published private(set) var scenes: [CuratedScene] = []
    @Published private(set) var isLoadingFeed = false
    @Published private(set) var isLoadingScenes = false
    @Published private(set) var isLoadingMoreFeed = false
    @Published private(set) var isLoadingMoreScenes = false
    @Published private(set) var feedError: String?
    @Published private(set) var scenesError: String?
    @Published private(set) var canLoadMoreFeed = false
    @Published private(set) var canLoadMoreScenes = false

    private let service: DiscoverService
    private var feedCursor: String?
    private var scenesCursor: String?
    private var didLoadInitialPages = false

    init(service: DiscoverService) {
        self.service = service
    }

    func loadInitialPages() async {
        guard !didLoadInitialPages else { return }
        didLoadInitialPages = true

        async let feed: Void = loadFirstFeedPage()
        async let scenes: Void = loadFirstScenesPage()
        _ = await (feed, scenes)
    }

    func retryFeed() async {
        await loadFirstFeedPage()
    }

    func retryScenes() async {
        guard !isLoadingScenes else { return }
        await loadFirstScenesPage()
    }

    func loadMoreFeed() async {
        guard canLoadMoreFeed, !isLoadingMoreFeed, let cursor = feedCursor else { return }
        isLoadingMoreFeed = true
        feedError = nil
        defer { isLoadingMoreFeed = false }

        do {
            let page = try await service.loadRecommendedFeed(cursor: cursor)
            feedItems.append(contentsOf: page.contents)
            feedCursor = page.nextCursor
            canLoadMoreFeed = page.nextCursor != nil
        } catch {
            feedError = error.localizedDescription
        }
    }

    func loadMoreScenes() async {
        guard canLoadMoreScenes, !isLoadingMoreScenes, let cursor = scenesCursor else { return }
        isLoadingMoreScenes = true
        scenesError = nil
        defer { isLoadingMoreScenes = false }

        do {
            let page = try await service.loadCuratedScenes(cursor: cursor)
            scenes.append(contentsOf: page.scenes)
            scenesCursor = page.nextCursor
            canLoadMoreScenes = page.hasNext == true && page.nextCursor != nil
        } catch {
            scenesError = error.localizedDescription
        }
    }

    private func loadFirstFeedPage() async {
        guard !isLoadingFeed else { return }
        isLoadingFeed = true
        feedError = nil
        defer { isLoadingFeed = false }

        do {
            let page = try await service.loadRecommendedFeed(cursor: nil)
            feedItems = page.contents
            feedCursor = page.nextCursor
            canLoadMoreFeed = page.nextCursor != nil
        } catch {
            feedError = error.localizedDescription
        }
    }

    private func loadFirstScenesPage() async {
        guard !isLoadingScenes else { return }
        isLoadingScenes = true
        scenesError = nil
        defer { isLoadingScenes = false }

        do {
            let page = try await service.loadCuratedScenes(cursor: nil)
            scenes = page.scenes
            scenesCursor = page.nextCursor
            canLoadMoreScenes = page.hasNext == true && page.nextCursor != nil
        } catch {
            scenesError = error.localizedDescription
        }
    }
}
