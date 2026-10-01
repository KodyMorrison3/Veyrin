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

    // MARK: Character search (additive — feed/scenes state above is untouched)

    /// Two-way binding target for Discover's search field.
    @Published var searchQuery = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            searchQueryChanged()
        }
    }
    @Published private(set) var suggestions: [String] = []
    @Published private(set) var isSearchingSuggestions = false
    @Published private(set) var searchResults: [CharacterSearchResult] = []
    @Published private(set) var isSearchingResults = false
    /// Set when a submitted query reached the web-session-only results endpoint
    /// and was refused — an expected condition, shown as an honest notice
    /// (suggestions keep working), not a generic error.
    @Published private(set) var searchNeedsWebSession = false
    @Published private(set) var searchError: String?

    private let service: DiscoverService
    private let searchService: CharacterSearchService?
    private let popularTrendingService: PopularTrendingService?
    private var feedCursor: String?
    private var scenesCursor: String?
    private var didLoadInitialPages = false
    private var suggestionsGeneration = 0
    private var resultsGeneration = 0
    private var lastSearchedQuery: String?

    /// - Parameters:
    ///   - service: feed/scenes service, as before.
    ///   - searchService: character-search service; the view builds it from the
    ///     shared auth store. Tests that don't exercise search may omit it —
    ///     search state then stays inert.
    ///   - popularTrendingService: curated-list service; same injection story.
    init(
        service: DiscoverService,
        searchService: CharacterSearchService? = nil,
        popularTrendingService: PopularTrendingService? = nil
    ) {
        self.service = service
        self.searchService = searchService
        self.popularTrendingService = popularTrendingService
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

    // MARK: - Character search

    var hasActiveSearch: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Suggestions are useful while composing a query; once that exact query
    /// has been submitted (results shown, or its outcome shown) they hide.
    var showsSuggestions: Bool {
        guard hasActiveSearch, !isSearchingResults else { return false }
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed != lastSearchedQuery && !suggestions.isEmpty
    }

    /// Debounces autocomplete while typing; stale responses are dropped by
    /// generation counter. Results from a previous search are kept visible
    /// until a new submit replaces them.
    private func searchQueryChanged() {
        suggestionsGeneration += 1
        resultsGeneration += 1
        searchNeedsWebSession = false
        searchError = nil
        // Editing the query invalidates any previous outcome — stale results
        // or a stale empty state must never linger under the new text.
        searchResults = []

        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            suggestions = []
            isSearchingSuggestions = false
            searchResults = []
            isSearchingResults = false
            lastSearchedQuery = nil
            return
        }

        guard trimmed.count >= 2 else { return }

        // Autocomplete as-you-type (works live with the app's Token auth).
        let generation = suggestionsGeneration
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, generation == self.suggestionsGeneration else { return }
            await self.loadSuggestions(for: trimmed, generation: generation)
        }
    }

    private func loadSuggestions(for query: String, generation: Int) async {
        guard let searchService else { return }
        isSearchingSuggestions = true
        defer { isSearchingSuggestions = false }

        do {
            let fetched = try await searchService.fetchAutocomplete(queryPrefix: query)
            guard generation == suggestionsGeneration else { return }
            suggestions = fetched
        } catch {
            guard generation == suggestionsGeneration else { return }
            // Suggestions are a nicety; failures stay quiet but honest.
            suggestions = []
        }
    }

    /// Submit (Return) or suggestion tap: attempts the real results request.
    /// The known web-session refusal is surfaced as `searchNeedsWebSession`;
    /// every other failure is a plain `searchError`.
    func submitSearch() async {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        resultsGeneration += 1
        let generation = resultsGeneration
        lastSearchedQuery = trimmed
        isSearchingResults = true
        searchNeedsWebSession = false
        searchError = nil
        defer { isSearchingResults = false }

        guard let searchService else { return }
        do {
            let results = try await searchService.searchCharacters(query: trimmed)
            guard generation == resultsGeneration else { return }
            searchResults = results
        } catch is CancellationError {
            return
        } catch SearchError.resultsRequireWebSession {
            guard generation == resultsGeneration else { return }
            searchResults = []
            searchNeedsWebSession = true
        } catch {
            guard generation == resultsGeneration else { return }
            searchResults = []
            searchError = error.localizedDescription
        }
    }

    /// Tap a suggestion: fill the field and run the results attempt.
    func selectSuggestion(_ suggestion: String) {
        searchQuery = suggestion
        Task { await submitSearch() }
    }

    /// Clearing search restores the plain Discover UI (feed/scenes state was
    /// never modified by searching).
    func clearSearch() {
        searchQuery = ""
    }

    // MARK: - Popular / Trending curated lists (additive)

    @Published private(set) var popularCharacters: [DiscoverFeedCharacter] = []
    @Published private(set) var trendingCharacters: [DiscoverFeedCharacter] = []
    @Published private(set) var isLoadingCurated = false
    @Published private(set) var curatedError: String?

    private var didLoadCuratedLists = false

    /// One GET returns both curated lists; there is no pagination.
    func loadCuratedLists() async {
        guard !didLoadCuratedLists, !isLoadingCurated else { return }
        didLoadCuratedLists = true
        isLoadingCurated = true
        curatedError = nil
        defer { isLoadingCurated = false }

        guard let popularTrendingService else { return }
        do {
            let lists = try await popularTrendingService.loadCuratedLists()
            // A list id the server omits counts as empty, not an error.
            popularCharacters = lists.characters(
                forListID: PopularTrendingService.ListID.popular
            )
            trendingCharacters = lists.characters(
                forListID: PopularTrendingService.ListID.trending
            )
        } catch {
            curatedError = error.localizedDescription
        }
    }

    func retryCuratedLists() async {
        didLoadCuratedLists = false
        await loadCuratedLists()
    }
}
