import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var authStore: AuthStore

    var body: some View {
        if authStore.isAuthenticated {
            MainView(authStore: authStore)
        } else {
            LoginView()
        }
    }
}

private struct MainView: View {
    let authStore: AuthStore

    @StateObject private var viewModel: ChatViewModel
    @State private var selectedChatID: String?
    @State private var conversationSearchText = ""
    @State private var pendingCreatedChat: ConversationSummary?
    @State private var profileCharacterID: String?
    @State private var hideErrorMessage: String?
    @State private var isShowingDiscover = false

    init(authStore: AuthStore) {
        self.authStore = authStore

        _viewModel = StateObject(
            wrappedValue: ChatViewModel(
                authStore: authStore
            )
        )
    }

    private var selectedConversation: ConversationSummary? {
        guard let selectedChatID else {
            return nil
        }
        if let conversation = viewModel.recentChats.first(where: {
            $0.chatID == selectedChatID
        }) {
            return conversation
        }
        // Recent chats can lag creation, so keep the selected summary until it catches up.
        guard pendingCreatedChat?.chatID == selectedChatID else {
            return nil
        }
        return pendingCreatedChat
    }

    private var filteredRecentChats: [ConversationSummary] {
        ConversationSummary.matchingCharacterName(
            conversationSearchText,
            in: viewModel.recentChats
        )
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
        .task {
            await viewModel.loadRecentChats()
        }
        // macOS sheets are modal and cannot be dismissed by clicking outside, so the
        // profile uses a transient popover, which is dismissed by an outside click.
        .popover(isPresented: Binding(
            get: { profileCharacterID != nil },
            set: { if !$0 { profileCharacterID = nil } }
        )) {
            if let profileCharacterID {
                CharacterProfileView(
                    characterID: profileCharacterID,
                    authStore: authStore,
                    onStartConversation: { profile in
                        await startConversation(
                            characterID: profile.externalID,
                            name: profile.name ?? profile.title ?? "Character",
                            avatarFileName: profile.avatarFileName ?? ""
                        )
                    }
                )
                // Popovers size to the content's fitting size; pin it so flexible
                // profile content (scroll view, loading states) cannot balloon it.
                .frame(width: 480, height: 560)
            }
        }
    }

    private var sidebar: some View {
        List(
            filteredRecentChats,
            selection: Binding(
                get: { selectedChatID },
                set: { chatID in
                    selectedChatID = chatID
                    if chatID != nil {
                        isShowingDiscover = false
                    }
                }
            )
        ) { conversation in
            ConversationRow(
                conversation: conversation
            )
            .tag(conversation.chatID)
            .listRowSeparator(.hidden)
            .contextMenu {
                Button(
                    "Hide Character / Remove from Recents",
                    systemImage: "eye.slash",
                    role: .destructive
                ) {
                    Task {
                        let selectedWasHidden = selectedChatID.map { chatID in
                            viewModel.recentChats.contains(where: {
                                $0.chatID == chatID &&
                                $0.characterID == conversation.characterID
                            })
                        } ?? false

                        let didHide = await viewModel.hideCharacter(
                            externalID: conversation.characterID
                        )

                        if didHide && selectedWasHidden {
                            selectedChatID = nil
                        }

                        if let message = viewModel.hideErrorMessage {
                            hideErrorMessage = message
                        }
                    }
                }
                .disabled(
                    viewModel.hidingCharacterIDs.contains(
                        conversation.characterID
                    )
                )
            }
            .listRowBackground(
                selectedChatID == conversation.chatID
                    ? Color.accentColor.opacity(0.12)
                    : Color.clear
            )
        }
        .searchable(
            text: $conversationSearchText,
            placement: .sidebar,
            prompt: "Search conversations"
        )
        .overlay {
            if filteredRecentChats.isEmpty,
               !conversationSearchText.trimmingCharacters(
                    in: .whitespacesAndNewlines
               ).isEmpty {
                ContentUnavailableView(
                    "No Matching Conversations",
                    systemImage: "magnifyingglass",
                    description: Text("Try a different search term.")
                )
                .padding()
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Conversations")
        .alert(
            "Unable to Hide Character",
            isPresented: Binding(
                get: { hideErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        hideErrorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                hideErrorMessage = nil
            }
        } message: {
            Text(hideErrorMessage ?? "Please try again.")
        }
        .toolbar {
            ToolbarItem {
                Button {
                    selectedChatID = nil
                    isShowingDiscover = true
                } label: {
                    Label("Discover", systemImage: "sparkles")
                }
                .help("Discover")
            }

            ToolbarItem {
                Button {
                    guard let selectedConversation else {
                        return
                    }

                    Task {
                        await startConversation(
                            characterID: selectedConversation.characterID,
                            name: selectedConversation.characterName,
                            avatarFileName: selectedConversation.characterAvatarURI
                        )
                    }
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("New Conversation")
                .disabled(
                    viewModel.isLoading ||
                    selectedConversation == nil
                )
            }

            ToolbarItem {
                Button {
                    guard let selectedConversation else {
                        return
                    }
                    profileCharacterID = selectedConversation.characterID
                } label: {
                    Image(systemName: "info.circle")
                }
                .help("Character Profile")
                .disabled(selectedConversation == nil)
            }
        }
    }
    
    private func startConversation(
        characterID: String,
        name: String,
        avatarFileName: String
    ) async -> Bool {
        guard let newChatID = await viewModel.createRealChat(characterID: characterID) else {
            return false
        }

        pendingCreatedChat = ConversationSummary(
            id: newChatID,
            chatID: newChatID,
            characterID: characterID,
            characterName: name,
            characterAvatarURI: avatarFileName,
            lastUpdated: ISO8601DateFormatter().string(from: Date()),
            state: "STATE_ACTIVE",
            lastMessage: nil
        )
        selectedChatID = newChatID
        if viewModel.recentChats.contains(where: { $0.chatID == newChatID }) {
            pendingCreatedChat = nil
        }
        Task {
            await viewModel.loadRecentChats()
            if viewModel.recentChats.contains(where: { $0.chatID == newChatID }) {
                pendingCreatedChat = nil
            }
        }
        return true
    }

    private struct ConversationRow: View {
        let conversation: ConversationSummary

        var body: some View {
            HStack(spacing: 10) {
                avatar

                VStack(
                    alignment: .leading,
                    spacing: 4
                ) {
                    HStack(spacing: 6) {
                        Text(conversation.characterName)
                            .font(.headline)
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        Text(relativeDate)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let lastMessage = conversation.lastMessage,
                       !lastMessage.isEmpty {
                        Text(lastMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else {
                        Text(
                            conversation.state == "STATE_ACTIVE"
                                ? "Active"
                                : "Archived"
                        )
                        .font(.caption)
                        .foregroundStyle(
                            conversation.state == "STATE_ACTIVE"
                                ? .secondary
                                : .tertiary
                        )
                    }
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .opacity(
                conversation.state == "STATE_ACTIVE"
                    ? 1
                    : 0.72
            )
        }

        private var avatar: some View {
            Group {
                if let avatarURL = CharacterImageURL.makeURL(
                    avatarFileName: conversation.characterAvatarURI
                ) {
                    AsyncImage(url: avatarURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()

                        case .failure:
                            fallbackAvatar

                        case .empty:
                            ProgressView()

                        @unknown default:
                            fallbackAvatar
                        }
                    }
                } else {
                    fallbackAvatar
                }
            }
            .frame(
                width: 40,
                height: 40
            )
            .clipShape(Circle())
        }

        private var fallbackAvatar: some View {
            ZStack {
                Circle()
                    .fill(.secondary.opacity(0.15))

                Text(
                    conversation.characterName
                        .prefix(1)
                        .uppercased()
                )
                .font(.headline)
            }
            .frame(
                width: 40,
                height: 40
            )
        }

        private var relativeDate: String {
            let formatter = ISO8601DateFormatter()

            formatter.formatOptions = [
                .withInternetDateTime,
                .withFractionalSeconds
            ]

            guard let date = formatter.date(
                from: conversation.lastUpdated
            ) else {
                return ""
            }

            return date.formatted(
                .relative(
                    presentation: .named
                )
            )
        }
    }

    @ViewBuilder
    private var detailView: some View {
        if isShowingDiscover {
            DiscoverView(
                authStore: authStore,
                onSelectCharacter: { characterID in
                    profileCharacterID = characterID
                }
            )
        } else if let selectedChat = selectedConversation {
            ChatView(
                chatID: selectedChat.chatID,
                characterID: selectedChat.characterID,
                authStore: authStore
            )
            .id(selectedChat.chatID)
        } else {
            ContentUnavailableView(
                "No Conversation Selected",
                systemImage: "bubble.left.and.bubble.right",
                description: Text(
                    "Select a conversation from the sidebar."
                )
            )
        }
    }
}
