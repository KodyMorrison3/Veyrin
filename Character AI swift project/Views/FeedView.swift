import AVKit
import SwiftUI

struct FeedView: View {
    @StateObject private var viewModel: FeedViewModel
    let onSelectCharacter: (String) -> Void
    let onSelectCreator: (String) -> Void

    init(
        authStore: AuthStore,
        onSelectCharacter: @escaping (String) -> Void,
        onSelectCreator: @escaping (String) -> Void
    ) {
        self.onSelectCharacter = onSelectCharacter
        self.onSelectCreator = onSelectCreator
        _viewModel = StateObject(wrappedValue: FeedViewModel(
            service: FeedService(authStore: authStore)
        ))
    }

    var body: some View {
        Group {
            if let response = viewModel.response {
                feedContent(response)
            } else if viewModel.isLoading {
                ProgressView("Loading Feed…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = viewModel.errorMessage {
                ContentUnavailableView {
                    Label("Unable to Load Feed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Retry") {
                        Task { await viewModel.retry() }
                    }
                }
            } else {
                ProgressView("Loading Feed…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Feed")
        .task {
            if viewModel.shouldLoad { await viewModel.load() }
        }
    }

    private func feedContent(_ response: FeedResponse) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if response.contents.isEmpty {
                    ContentUnavailableView(
                        "Your Feed Is Empty",
                        systemImage: "rectangle.stack",
                        description: Text("There are no feed items to show right now.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    LazyVStack(spacing: 16) {
                        ForEach(response.contents) { item in
                            if item.componentType == 10, let module = item.recommendedCreatorModule {
                                recommendedCreators(module)
                            } else if let post = item.post {
                                FeedPostCard(
                                    item: item,
                                    post: post,
                                    onSelectCharacter: onSelectCharacter,
                                    onSelectCreator: onSelectCreator
                                )
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
        }
    }

    private func recommendedCreators(_ module: FeedRecommendedCreatorModule) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recommended creators")
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(module.creators) { creator in
                        Button {
                            onSelectCreator(creator.username)
                        } label: {
                            VStack(spacing: 6) {
                                feedAvatar(
                                    fileName: creator.avatarFilename,
                                    url: nil,
                                    name: creator.displayName ?? creator.username,
                                    size: 56
                                )
                                Text(creator.displayName ?? creator.username)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 92)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct FeedPostCard: View {
    let item: FeedItem
    let post: FeedPost
    let onSelectCharacter: (String) -> Void
    let onSelectCreator: (String) -> Void

    private var isCharacterPost: Bool { item.componentType == 8 }
    private var isMultiCharacterPost: Bool { item.componentType == 7 }
    private var isMediaPost: Bool { item.componentType == 11 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            authorHeader

            if let caption = nonempty(post.caption) {
                Text(caption)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            participants

            if let media = post.mediaURLs.first, let url = URL(string: media) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else if phase.error != nil {
                        ContentUnavailableView("Media Unavailable", systemImage: "photo")
                            .frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 180)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            if isMultiCharacterPost, let content = nonempty(post.content) {
                Label("Conversation post", systemImage: "bubble.left.and.bubble.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(content)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let reactions = post.reactions, !reactions.isEmpty {
                Text(reactions.sorted { $0.key < $1.key }
                    .map { "\($0.key) \($0.value)" }
                    .joined(separator: "  ·  "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let dateString = post.createdAt,
               let date = ISO8601DateFormatter().date(from: dateString) {
                Text(date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 14))
    }

    private var authorHeader: some View {
        HStack(spacing: 10) {
            feedAvatar(
                fileName: nil,
                url: post.authorInfo?.avatarURL,
                name: post.authorInfo?.name ?? post.authorInfo?.username ?? "Creator",
                size: 38
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(post.authorInfo?.name ?? post.authorInfo?.username ?? "Character.AI creator")
                    .font(.subheadline.weight(.semibold))
                if let username = nonempty(post.authorInfo?.username) {
                    Button("@\(username)") { onSelectCreator(username) }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(componentLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var participants: some View {
        if !post.participants.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(isCharacterPost ? "Character" : isMultiCharacterPost ? "Characters" : "In this post")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                ForEach(post.participants) { participant in
                    Button {
                        onSelectCharacter(participant.id)
                    } label: {
                        HStack(spacing: 9) {
                            feedAvatar(
                                fileName: nil,
                                url: participant.avatarURL,
                                name: participant.name ?? "Character",
                                size: 32
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(participant.name ?? "Character")
                                    .font(.subheadline.weight(.medium))
                                if let creator = nonempty(participant.creatorInfo?.username) {
                                    Text("by @\(creator)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var componentLabel: String {
        switch item.componentType {
        case 7: "Group post"
        case 8: "Character post"
        case 11: "Media post"
        default: "Post"
        }
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}

@ViewBuilder
private func feedAvatar(fileName: String?, url: String?, name: String, size: CGFloat) -> some View {        let imageURL: URL? = {
            if let url, url.hasPrefix("https://"), let parsed = URL(string: url), parsed.host != nil {
                return parsed
            }
            if let fileName {
                return CharacterImageURL.makeURL(avatarFileName: fileName)
            }
            return nil
        }()
    if let imageURL {
        AsyncImage(url: imageURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                feedAvatarFallback(name: name, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    } else {
        feedAvatarFallback(name: name, size: size)
    }
}

private func feedAvatarFallback(name: String, size: CGFloat) -> some View {
    ZStack {
        Circle().fill(.secondary.opacity(0.15))
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.42, weight: .semibold))
    }
    .frame(width: size, height: size)
}
