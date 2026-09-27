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
            id: \.chatID,
            selection: $selectedChatID
        ) { chat in
            VStack(alignment: .leading, spacing: 3) {
                Text(chat.characterName)
                    .font(.headline)

                Text("Conversation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .tag(chat.chatID)
        }
        .navigationTitle("Conversations")
        .toolbar {
            ToolbarItem {
                Button {
                    guard let currentChatID = selectedChatID,
                          let selectedChat = viewModel.recentChats.first(where: {
                              $0.chatID == currentChatID
                          }) else {
                        return
                    }

                    Task {
                        if let newChatID = await viewModel.createRealChat(
                            characterID: selectedChat.characterID
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
