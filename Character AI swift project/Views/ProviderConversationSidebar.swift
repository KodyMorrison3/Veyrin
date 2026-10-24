import SwiftUI

/// Recent conversations for imported characters, matching the Character.AI
/// conversation sidebar: search above, then one row per saved chat with the
/// character's avatar, name, last message and when it was updated. Rows come
/// from the saved provider transcripts, so local and cloud chats sit together.
struct ProviderConversationSidebar: View {
    @ObservedObject var store: ProviderTranscriptStore
    @ObservedObject var library: LocalCharacterLibrary
    @ObservedObject var chat: ProviderChatViewModel
    var errorMessage: String?
    let onOpen: (ProviderTranscriptSummary) -> Void
    let onNewChat: () -> Void

    @State private var query = ""

    private var currentID: String {
        ProviderTranscriptKey(
            providerID: chat.provider.descriptor.id,
            kind: chat.provider.descriptor.kind,
            model: chat.model,
            characterID: chat.character?.id
        ).identity
    }

    private var rows: [ProviderTranscriptSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return store.summaries }
        return store.summaries.filter { summary in
            summary.title.localizedCaseInsensitiveContains(trimmed)
                || (summary.preview?.localizedCaseInsensitiveContains(trimmed) ?? false)
                || summary.key.model.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// Opens a saved chat. Rows are buttons rather than `List` selection: a
    /// selection binding can write a stale row back (or rewrite the row for the
    /// chat already on screen) and reopen the wrong provider's conversation.
    private func open(_ summary: ProviderTranscriptSummary) {
        guard summary.id != currentID else { return }
        onOpen(summary)
    }

    /// Same column as the Character.AI conversation sidebar: search inset at the
    /// top, the list, and New chat pinned at the bottom over navigation glass.
    var body: some View {
        List {
            ForEach(rows) { summary in
                Button { open(summary) } label: {
                    ProviderConversationRow(
                        summary: summary,
                        character: library.characters.first { $0.id == summary.key.characterID },
                        isSelected: summary.id == currentID
                    )
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
            }
        }
        // Keep search local to navigation, like the Character.AI sidebar, so it
        // cannot obscure the transcript in the detail column.
        .safeAreaInset(edge: .top, spacing: 8) {
            VStack(spacing: 6) {
                searchField
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 8)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            newChatBar
        }
        .overlay {
            if store.summaries.isEmpty {
                ContentUnavailableView(
                    "No Conversations Yet",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Local and cloud chats with your imported characters are saved here as soon as you send a message.")
                )
                .allowsHitTesting(false)
            } else if rows.isEmpty {
                ContentUnavailableView(
                    "No Matching Conversations",
                    systemImage: "magnifyingglass",
                    description: Text("Try a different search term.")
                )
                .allowsHitTesting(false)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        .glassSurface(.navigation, cornerRadius: 14)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(Color.caiMuted)
            TextField("Search characters…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Color.caiText)
                .accessibilityLabel("Search characters")
                .onKeyPress(.escape) {
                    query = ""
                    return .handled
                }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.caiMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .glassSurface(.searchField, cornerRadius: 16)
        .padding(.horizontal, 10)
    }

    private var newChatBar: some View {
        Button(action: onNewChat) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                Text("New chat")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(Color.caiText)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .glassSurface(.characterHeader, cornerRadius: 10)
        }
        .buttonStyle(QuietHoverButtonStyle())
        .help("Start a new chat with this provider, model and character")
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .padding(.top, 4)
    }
}

/// One saved conversation, in the Character.AI row shape: a circular avatar,
/// the character name and relative time, then the last message underneath.
private struct ProviderConversationRow: View {
    let summary: ProviderTranscriptSummary
    let character: LocalCharacter?
    let isSelected: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private let rowCornerRadius: CGFloat = 10
    private let avatarDiameter: CGFloat = 36

    /// A chat without a character is titled by its provider, so a local chat
    /// and a cloud chat with no character are not two identical "Provider chat"
    /// rows that open different providers.
    private var title: String { character?.name ?? summary.title }

    var body: some View {
        HStack(spacing: 10) {
            avatar

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(Color.caiText)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    // The name truncates first: a clipped "41 minutes…" reads as
                    // a bug, a clipped character name reads as a long name.
                    Text(summary.updatedAt, format: .relative(presentation: .named))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.caiMuted)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }

                if let preview = summary.preview {
                    Text(preview)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.caiMuted)
                        .lineLimit(1)
                } else {
                    Text(summary.key.kind.title)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.caiMuted.opacity(0.6))
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : GlassMetrics.interaction, value: isSelected)
        .animation(reduceMotion ? nil : GlassMetrics.interaction, value: isHovering)
        .help("\(summary.key.kind.title) · \(summary.key.model)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(summary.preview ?? summary.key.kind.title)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous)
        if isSelected {
            EnvironmentalSelectionBackground(cornerRadius: rowCornerRadius)
        } else if isHovering {
            shape.fill(Color.primary.opacity(0.04))
        } else {
            shape.fill(Color.clear)
        }
    }

    private var avatar: some View {
        Group {
            if let fileName = character?.avatarFileName ?? summary.avatarFileName,
               let url = CharacterImageURL.makeURL(avatarFileName: fileName) {
                CachedAvatarView(url: url) { fallbackAvatar }
            } else {
                fallbackAvatar
            }
        }
        .frame(width: avatarDiameter, height: avatarDiameter)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }

    private var fallbackAvatar: some View {
        ZStack {
            Circle()
                .fill(ShellEnvironmentalBackground.environmentalSurfaceTint(isDark: colorScheme == .dark))
            Text(String(title.prefix(1)).uppercased())
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.caiText)
        }
        .frame(width: avatarDiameter, height: avatarDiameter)
    }
}
