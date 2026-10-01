//
//  UserProfileView.swift
//  Character AI swift project
//
//  The User Profile section: a compact account control at the bottom-left of
//  the main sidebar (Discord / character.ai web placement) that opens a
//  profile popover. Shows only public profile data; the session token is
//  never displayed or exposed.
//

import SwiftUI

/// Compact control pinned to the bottom of the sidebar.
struct UserProfileControl: View {
    @ObservedObject var viewModel: UserProfileViewModel

    var body: some View {
        HStack(spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text("@\(username)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.up")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var username: String {
        if case .loaded(let profile) = viewModel.state, let name = profile.username {
            return name
        }
        return viewModel.username
    }

    private var displayName: String {
        if case .loaded(let profile) = viewModel.state, let name = profile.name, !name.isEmpty {
            return name
        }
        return viewModel.username
    }

    private var avatar: some View {
        Group {
            if case .loaded(let profile) = viewModel.state,
               let fileName = profile.avatarFileName,
               !fileName.isEmpty,
               let url = CharacterImageURL.makeURL(avatarFileName: fileName) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(Circle())
    }

    private var fallback: some View {
        ZStack {
            Circle().fill(.secondary.opacity(0.15))
            Text(String(viewModel.username.prefix(1)).uppercased())
                .font(.headline)
        }
    }
}

/// Popover content: the loaded public profile.
struct UserProfileDetailView: View {
    @ObservedObject var viewModel: UserProfileViewModel
    let onSelectCharacter: (String) -> Void

    var body: some View {
        Group {
            switch viewModel.state {
            case .idle:
                Color.clear.onAppear { Task { await viewModel.load() } }
            case .loading:
                ProgressView("Loading profile…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                VStack(spacing: 10) {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Button("Retry") {
                        Task { await viewModel.load() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let profile):
                profileContent(profile)
            }
        }
        .padding(20)
        .frame(width: 380, height: 460)
    }

    @ViewBuilder
    private func profileContent(_ profile: UserProfile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    avatar(for: profile)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name.nonEmpty ?? profile.username.nonEmpty ?? "Character.AI User")
                            .font(.title3.bold())
                            .lineLimit(1)
                        Text("@\(profile.username.nonEmpty ?? viewModel.username)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let subscription = profile.subscriptionType.nonEmpty {
                            Text(subscription)
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.tint.opacity(0.15), in: Capsule())
                        }
                    }
                }

                if let bio = profile.bio.nonEmpty {
                    Text(bio)
                        .font(.callout)
                        .textSelection(.enabled)
                }

                HStack(spacing: 16) {
                    Label("\(profile.followerCount ?? 0)", systemImage: "person.2")
                    Label("\(profile.followingCount ?? 0)", systemImage: "person.badge.plus")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if !profile.publicCharacters.isEmpty {
                    Divider()
                    Text("Public characters")
                        .font(.headline)
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 150), spacing: 10)],
                        spacing: 10
                    ) {
                        ForEach(
                            Array(profile.publicCharacters.enumerated()),
                            id: \.offset
                        ) { _, character in
                            if let externalID = character.externalID,
                               !externalID.isEmpty {
                                Button {
                                    onSelectCharacter(externalID)
                                } label: {
                                    userCharacterCard(character)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func avatar(for profile: UserProfile) -> some View {
        Group {
            if let fileName = profile.avatarFileName.nonEmpty,
               let url = CharacterImageURL.makeURL(avatarFileName: fileName) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        fallbackAvatar
                    }
                }
            } else {
                fallbackAvatar
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(Circle())
    }

    private var fallbackAvatar: some View {
        ZStack {
            Circle().fill(.secondary.opacity(0.15))
            Text(String(viewModel.username.prefix(1)).uppercased())
                .font(.title3.bold())
        }
    }

    /// Compact variant of the shared character-card idiom, sized for the
    /// popover grid.
    private func userCharacterCard(_ character: DiscoverFeedCharacter) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            avatar(fileName: character.avatarFileName, name: character.name)
            Text(character.name ?? character.participantName ?? "Character")
                .font(.caption.bold())
                .lineLimit(1)
            if let count = character.interactionCount {
                Text("\(count) chats")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func avatar(fileName: String?, name: String?) -> some View {
        if let fileName = fileName.nonEmpty,
           let url = CharacterImageURL.makeURL(avatarFileName: fileName) {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    fallbackAvatar(fileName: fileName, name: name)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            fallbackAvatar(fileName: fileName, name: name)
        }
    }

    private func fallbackAvatar(fileName: String?, name: String?) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.15))
            Text(String((name ?? "?").prefix(1)).uppercased())
                .font(.headline)
        }
        .frame(width: 44, height: 44)
    }
}

extension Optional where Wrapped == String {
    fileprivate var nonEmpty: String? {
        guard let self, !self.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return self
    }
}
