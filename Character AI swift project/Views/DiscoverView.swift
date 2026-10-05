import SwiftUI

struct DiscoverView: View {
    @StateObject private var viewModel: DiscoverViewModel
    @ObservedObject private var preferences = AppPreferences.shared
    let onSelectCharacter: (String) -> Void

    init(
        authStore: AuthStore,
        onSelectCharacter: @escaping (String) -> Void
    ) {
        self.onSelectCharacter = onSelectCharacter
        _viewModel = StateObject(wrappedValue: DiscoverViewModel(
            service: DiscoverService(authStore: authStore),
            searchService: CharacterSearchService(authStore: authStore),
            popularTrendingService: PopularTrendingService(authStore: authStore)
        ))
    }

    var body: some View {
        Group {
            if viewModel.hasActiveSearch {
                searchSection
            } else {
                browseSection
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                searchBar
                    .frame(minWidth: 180, idealWidth: 360, maxWidth: 520)
            }
        }
        // Place search within the native toolbar rather than below its wash.
        .scrollEdgeEffectHidden()
        // Inherits MainView's full-window ShellEnvironmentalBackground.
        .navigationTitle("Discover")
        .task {
            await viewModel.loadInitialPages()
        }
        .task {
            await viewModel.loadCuratedLists()
        }
    }

    // MARK: Search bar (persistent above scrolling content)

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(
                "Search characters",
                text: $viewModel.searchQuery
            )
            .textFieldStyle(.plain)
            .onSubmit {
                Task { await viewModel.submitSearch() }
            }
            if viewModel.hasActiveSearch {
                Button {
                    viewModel.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(QuietHoverButtonStyle())
                .help("Clear search")
                .keyboardShortcut(.cancelAction)

                Button {
                    Task { await viewModel.submitSearch() }
                } label: {
                    Image(systemName: "arrow.right.circle")
                }
                .buttonStyle(QuietHoverButtonStyle())
                .help("Search")
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Browse (existing Discover content, unchanged)

    private var browseSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                recommendedSection
                if preferences.showPopularTrending {
                    popularTrendingSection
                }
                scenesSection
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Popular / Trending (curated lists, no pagination)

    private var popularTrendingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = viewModel.curatedError, viewModel.popularCharacters.isEmpty,
               viewModel.trendingCharacters.isEmpty {
                errorView(error) {
                    Task { await viewModel.retryCuratedLists() }
                }
            } else {
                curatedListSection(
                    title: "Popular characters",
                    systemImage: "flame",
                    characters: viewModel.popularCharacters
                )
                curatedListSection(
                    title: "Trending characters",
                    systemImage: "chart.line.uptrend.xyaxis",
                    characters: viewModel.trendingCharacters
                )
                if viewModel.isLoadingCurated,
                   viewModel.popularCharacters.isEmpty,
                   viewModel.trendingCharacters.isEmpty {
                    ProgressView("Loading popular & trending…")
                }
            }
        }
    }

    @ViewBuilder
    private func curatedListSection(
        title: String,
        systemImage: String,
        characters: [DiscoverFeedCharacter]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.title3.weight(.semibold))

            if characters.isEmpty {
                if !viewModel.isLoadingCurated {
                    Text("Nothing here right now.")
                        .foregroundStyle(.secondary)
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)], spacing: 14) {
                    ForEach(Array(characters.enumerated()), id: \.offset) { _, character in
                        if let externalID = character.externalID, !externalID.isEmpty {
                            Button {
                                onSelectCharacter(externalID)
                            } label: {
                                characterCard(character)
                            }
                            .buttonStyle(QuietHoverButtonStyle())
                        }
                    }
                }
            }
        }
    }

    // MARK: Search (suggestions / results / honest blocked state)

    private var searchSection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if viewModel.showsSuggestions {
                    suggestionsList
                }

                if viewModel.isSearchingResults {
                    ProgressView("Searching…")
                } else if viewModel.searchNeedsWebSession {
                    // Expected condition while the results endpoint requires a
                    // web-session credential. Retry stays available: upstream
                    // behavior at this boundary has varied before.
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            "Character search needs a web session — unavailable in the native app yet.",
                            systemImage: "globe"
                        )
                        .foregroundStyle(.secondary)
                        Button("Retry") {
                            Task { await viewModel.submitSearch() }
                        }
                    }
                } else if let searchError = viewModel.searchError {
                    errorView(searchError) {
                        Task { await viewModel.submitSearch() }
                    }
                } else if viewModel.searchResults.isEmpty {
                    Text("No results for \(viewModel.searchQuery).")
                        .foregroundStyle(.secondary)
                } else {
                    resultsGrid
                }
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var suggestionsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(viewModel.suggestions, id: \.self) { suggestion in
                Button {
                    viewModel.selectSuggestion(suggestion)
                } label: {
                    Label(suggestion, systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(QuietHoverButtonStyle())
            }
        }
        .padding(8)
        .glassSurface(.popover, cornerRadius: GlassMetrics.popoverRadius)
    }

    private var resultsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)], spacing: 14) {
            ForEach(Array(viewModel.searchResults.enumerated()), id: \.offset) { _, result in
                if let externalID = result.externalID, !externalID.isEmpty {
                    Button {
                        onSelectCharacter(externalID)
                    } label: {
                        searchResultCard(result)
                    }
                    .buttonStyle(QuietHoverButtonStyle())
                }
            }
        }
    }

    private func searchResultCard(_ result: CharacterSearchResult) -> some View {
        HStack(alignment: .top, spacing: 12) {
            avatar(fileName: result.avatarFileName, name: result.name)
            VStack(alignment: .leading, spacing: 5) {
                Text(result.name ?? result.title ?? "Character")
                    .font(.headline)
                    .lineLimit(2)
                if let tag = nonempty(result.tagLabel) {
                    Text(tag).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let description = nonempty(result.description) {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                HStack(spacing: 4) {
                    if let creator = nonempty(result.creatorUsername) {
                        Text("@\(creator)")
                    }
                    if let count = result.interactionCount {
                        Text("· \(count) chats")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .contentSurface()
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    private var recommendedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recommended characters")
                .font(.title2.weight(.semibold))

            if viewModel.isLoadingFeed && viewModel.feedItems.isEmpty {
                ProgressView("Loading recommendations…")
            } else if let error = viewModel.feedError, viewModel.feedItems.isEmpty {
                errorView(error) {
                    Task { await viewModel.retryFeed() }
                }
            } else if viewModel.feedItems.isEmpty {
                Text("No recommendations available.")
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)], spacing: 14) {
                    ForEach(Array(viewModel.feedItems.enumerated()), id: \.offset) { _, item in
                        if let character = item.characterItem,
                           let externalID = character.externalID,
                           !externalID.isEmpty {
                            Button {
                                onSelectCharacter(externalID)
                            } label: {
                                characterCard(character)
                            }
                            .buttonStyle(QuietHoverButtonStyle())
                        }
                    }
                }

                if let error = viewModel.feedError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if viewModel.canLoadMoreFeed {
                    Button {
                        Task { await viewModel.loadMoreFeed() }
                    } label: {
                        if viewModel.isLoadingMoreFeed {
                            ProgressView()
                        } else {
                            Text("Load more recommendations")
                        }
                    }
                    .disabled(viewModel.isLoadingMoreFeed)
                }
            }
        }
    }

    private var scenesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Curated scenes")
                .font(.title2.weight(.semibold))

            if viewModel.isLoadingScenes && viewModel.scenes.isEmpty {
                ProgressView("Loading scenes…")
            } else if let error = viewModel.scenesError, viewModel.scenes.isEmpty {
                errorView(error) {
                    Task { await viewModel.retryScenes() }
                }
            } else if viewModel.scenes.isEmpty {
                Text("No curated scenes available.")
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                    ForEach(Array(viewModel.scenes.enumerated()), id: \.offset) { _, scene in
                        sceneCard(scene)
                    }
                }
                if let error = viewModel.scenesError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if viewModel.canLoadMoreScenes {
                    Button {
                        Task { await viewModel.loadMoreScenes() }
                    } label: {
                        if viewModel.isLoadingMoreScenes {
                            ProgressView()
                        } else {
                            Text("Load more scenes")
                        }
                    }
                    .disabled(viewModel.isLoadingMoreScenes)
                }
            }
        }
    }

    private func characterCard(_ character: DiscoverFeedCharacter) -> some View {
        HStack(alignment: .top, spacing: 12) {
            avatar(fileName: character.avatarFileName, name: character.name)
            VStack(alignment: .leading, spacing: 5) {
                Text(character.name ?? character.participantName ?? character.title ?? "Character")
                    .font(.headline)
                    .lineLimit(2)
                if let title = nonempty(character.title), title != character.name {
                    Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let description = nonempty(character.description) {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .contentSurface()
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    private func sceneCard(_ scene: CuratedScene) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let urlString = scene.backgroundImageURL, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Rectangle().fill(.secondary.opacity(0.12))
                            .overlay { Image(systemName: "sparkles").foregroundStyle(.secondary) }
                    }
                }
                .frame(height: 140)
                .clipped()
            }
            Text(scene.title ?? "Scene")
                .font(.headline)
                .lineLimit(2)
            if let description = nonempty(scene.description) {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            if let creator = nonempty(scene.creatorUsername) {
                Text("by \(creator)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentSurface()
    }

    @ViewBuilder
    private func avatar(fileName: String?, name: String?) -> some View {
        if let fileName = nonempty(fileName),
           let url = CharacterImageURL.makeURL(avatarFileName: fileName) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    avatarFallback(name: name)
                }
            }
            .frame(width: 58, height: 58)
            .clipShape(RoundedRectangle(
                cornerRadius: preferences.avatarShape == .circle ? 29 : 10
            ))
        } else {
            avatarFallback(name: name)
        }
    }

    private func avatarFallback(name: String?) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(.secondary.opacity(0.15))
            Text(String((name ?? "?").prefix(1)).uppercased())
                .font(.headline)
        }
        .frame(width: 58, height: 58)
        .clipShape(RoundedRectangle(
            cornerRadius: preferences.avatarShape == .circle ? 29 : 10
        ))
    }

    private func errorView(_ message: String, retry: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            Button("Retry", action: retry)
        }
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}
