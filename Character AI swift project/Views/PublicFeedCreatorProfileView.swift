import SwiftUI

struct PublicFeedCreatorProfileView: View {
    @StateObject private var viewModel: UserProfileViewModel
    let username: String

    init(username: String, authStore: AuthStore) {
        self.username = username
        _viewModel = StateObject(wrappedValue: UserProfileViewModel(
            service: UserProfileService(authStore: authStore),
            username: username
        ))
    }

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle:
                ProgressView("Loading creator…")
            case .loading:
                ProgressView("Loading creator…")
            case .failed(let message):
                ContentUnavailableView {
                    Label("Unable to Load Creator", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") { Task { await viewModel.load() } }
                }
            case .loaded(let profile):
                creatorProfile(profile)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { ShellEnvironmentalBackground() }
        .presentationBackground(.regularMaterial)
        .task {
            if case .idle = viewModel.state { await viewModel.load() }
        }
    }

    private func creatorProfile(_ profile: UserProfile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    if let avatarFileName = profile.avatarFileName,
                       let url = CharacterImageURL.makeURL(avatarFileName: avatarFileName) {
                        CachedAvatarView(url: url) {
                    creatorAvatar(profile.name ?? username)
                }
                        .frame(width: 60, height: 60)
                        .clipShape(Circle())
                    } else {
                        creatorAvatar(profile.name ?? username)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.name ?? username).font(.title3.bold())
                        Text("@\(profile.username ?? username)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let bio = profile.bio, !bio.isEmpty {
                    Text(bio).textSelection(.enabled)
                }
                HStack(spacing: 16) {
                    Label("\(profile.followerCount ?? 0)", systemImage: "person.2")
                    Label("\(profile.followingCount ?? 0)", systemImage: "person.badge.plus")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !profile.publicCharacters.isEmpty {
                    Divider()
                    Text("Public characters").font(.headline)
                    ForEach(Array(profile.publicCharacters.enumerated()), id: \.offset) { _, character in
                        HStack {
                            Text(character.name ?? character.title ?? "Character")
                            Spacer()
                            if let count = character.interactionCount { Text("\(count) chats") }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func creatorAvatar(_ name: String) -> some View {
        ZStack {
            Circle().fill(.secondary.opacity(0.15))
            Text(String(name.prefix(1)).uppercased())
                .font(.title3.bold())
        }
        .frame(width: 60, height: 60)
    }
}
