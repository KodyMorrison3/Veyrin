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
    @State private var hideErrorMessage: String?

    init(authStore: AuthStore) {
        self.authStore = authStore

        _viewModel = StateObject(
            wrappedValue: ChatViewModel(
                authStore: authStore
            )
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
    }

    private var sidebar: some View {
        List(
            viewModel.recentChats,
            selection: $selectedChatID
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
                    guard let currentChatID = selectedChatID,
                          let selectedConversation =
                            viewModel.recentChats.first(where: {
                                $0.chatID == currentChatID
                            }) else {
                        return
                    }

                    Task {
                        if let newChatID =
                            await viewModel.createRealChat(
                                characterID: selectedConversation.characterID
                            ) {
                            await viewModel.loadRecentChats()
                            selectedChatID = newChatID
                        }
                    }
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("New Conversation")
                .disabled(
                    viewModel.isLoading ||
                    selectedChatID == nil
                )
            }
        }
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
        if let currentChatID = selectedChatID,
           let selectedChat = viewModel.recentChats.first(where: {
               $0.chatID == currentChatID
           }) {
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
