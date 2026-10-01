import SwiftUI

struct DiscoverView: View {
    @StateObject private var viewModel: DiscoverViewModel
    let onSelectCharacter: (String) -> Void

    init(
        authStore: AuthStore,
        onSelectCharacter: @escaping (String) -> Void
    ) {
        self.onSelectCharacter = onSelectCharacter
        _viewModel = StateObject(wrappedValue: DiscoverViewModel(
            service: DiscoverService(authStore: authStore)
        ))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                recommendedSection
                scenesSection
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Discover")
        .task {
            await viewModel.loadInitialPages()
        }
    }

    private var recommendedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recommended characters")
                .font(.title2.bold())

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
                            .buttonStyle(.plain)
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
                .font(.title2.bold())

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
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
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
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
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
            .clipShape(RoundedRectangle(cornerRadius: 10))
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
