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

/**
 * Bottom sidebar user control: a compact, single-row profile button for the
 * sidebar bottom panel. It renders the avatar, display name and username and
 * opens an account-menu popover on tap.
 *
 * The sidebar owns the account-menu popover lifecycle through `menuAction`.
 */
struct UserProfileControl: View {
    @ObservedObject var viewModel: UserProfileViewModel
    @ObservedObject private var preferences = AppPreferences.shared
    let menuAction: () -> Void

    var body: some View {
        Button {
            menuAction()
        } label: {
            profileButton(
                name: displayName,
                subtitle: subtitle,
                avatar: avatar
            )
        }
        .buttonStyle(QuietHoverButtonStyle())
    }

    @ViewBuilder
    private func profileButton(name: String, subtitle: String?, avatar: some View) -> some View {
        HStack(spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.up")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassSurface(.floatingControl, cornerRadius: GlassMetrics.controlRadius)
        .contentShape(Rectangle())
    }

    private var displayName: String {
        if case .loaded(let profile) = viewModel.state, let name = profile.name, !name.isEmpty {
            return name
        }
        return viewModel.username
    }

    private var subtitle: String? {
        if case .loaded(let profile) = viewModel.state, let name = profile.username {
            guard !name.isEmpty else { return nil }
            return "@\(name)"
        }
        return nil
    }

    private var avatar: some View {
        Group {
            if case .loaded(let profile) = viewModel.state,
               let fileName = profile.avatarFileName,
               !fileName.isEmpty,
               let url = CharacterImageURL.makeURL(avatarFileName: fileName) {
                CachedAvatarView(url: url) {
                    fallback
                }
            } else {
                fallback
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(Circle())
    }

    private var fallback: some View {
        ZStack {
            Circle().fill(preferences.environmentalPalette.glassSurfaceTint)
            Text(String(viewModel.username.prefix(1)).uppercased())
                .font(.headline)
        }
    }
}

/// Popover content: the loaded public profile.
struct UserProfileDetailView: View {
    @ObservedObject var viewModel: UserProfileViewModel
    @ObservedObject private var preferences = AppPreferences.shared
    @Environment(\.openSettings) private var openSettings
    @State private var libraryNotice: String?
    @State private var isSavingCharacters = false
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
        .background { ShellEnvironmentalBackground() }
        .presentationBackground(.regularMaterial)
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
                    Spacer(minLength: 8)
                    Button {
                        openSettings()
                    } label: {
                        Image(systemName: "gear")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Circle())
                    }
                    .buttonStyle(QuietHoverButtonStyle())
                    .help("Preferences…")
                    .accessibilityLabel("Open Preferences")
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
                    HStack {
                        Text("Public characters")
                            .font(.headline)
                        Spacer()
                        Button("Save all", systemImage: "bookmark") {
                            isSavingCharacters = true
                            Task {
                                defer { isSavingCharacters = false }
                                do {
                                    let count = try await viewModel.savePublicCharactersToLibrary()
                                    libraryNotice = "Saved \(count) of your public characters to My Library."
                                } catch {
                                    libraryNotice = error.localizedDescription
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isSavingCharacters)
                    }
                    if let libraryNotice {
                        if libraryNotice.hasPrefix("Saved ") {
                            Text(libraryNotice)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Label(libraryNotice, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
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
                                .buttonStyle(QuietHoverButtonStyle())
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
                CachedAvatarView(url: url) {
                    fallbackAvatar
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
            Circle().fill(preferences.environmentalPalette.glassSurfaceTint)
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
        .contentSurface(cornerRadius: 10)
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func avatar(fileName: String?, name: String?) -> some View {
        if let fileName = fileName.nonEmpty,
           let url = CharacterImageURL.makeURL(avatarFileName: fileName) {
            CachedAvatarView(url: url) {
                    fallbackAvatar(fileName: fileName, name: name)
                }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            fallbackAvatar(fileName: fileName, name: name)
        }
    }

    @MainActor
    private func fallbackAvatar(fileName: String?, name: String?) -> some View {
        let initial = (name ?? fileName) ?? "?"
        return ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(preferences.environmentalPalette.glassSurfaceTint)
            Text(String(initial.prefix(1)).uppercased())
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
