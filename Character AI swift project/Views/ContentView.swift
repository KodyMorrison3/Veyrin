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

    @ObservedObject private var preferences = AppPreferences.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @StateObject private var viewModel: ChatViewModel
    @State private var selectedChatID: String?
    @State private var conversationSearchText = ""
    @FocusState private var isConversationSearchFocused: Bool
    @State private var pendingCreatedChat: ConversationSummary?
    @State private var pendingCopiedConversation: ConversationSummary?
    @State private var profileCharacterID: String?
    @State private var hideErrorMessage: String?
    @State private var isShowingDiscover = false
    @State private var isShowingFeed = false
    @State private var feedProfileUsername: String?
    @State private var isShowingFeedCreatorProfile = false

    init(authStore: AuthStore) {
        self.authStore = authStore

        _viewModel = StateObject(
            wrappedValue: ChatViewModel(
                authStore: authStore
            )
        )
        _userProfileViewModel = StateObject(
            wrappedValue: UserProfileViewModel(
                service: UserProfileService(authStore: authStore),
                username: authStore.session?.username ?? ""
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
        if pendingCreatedChat?.chatID == selectedChatID {
            return pendingCreatedChat
        }
        return pendingCopiedConversation?.chatID == selectedChatID
            ? pendingCopiedConversation
            : nil
    }

    private var filteredRecentChats: [ConversationSummary] {
        ConversationSummary.matchingCharacterName(
            conversationSearchText,
            in: viewModel.recentChats
        )
    }

    var body: some View {
        ZStack {
            // Atmospheric character artwork background behind the window.
            // Extends under the title bar so the window toolbar area reads as
            // translucent glass over the environment, not an opaque slab.
            ShellEnvironmentalBackground(
                avatarURL: selectedConversation.flatMap {
                    CharacterImageURL.makeURL(avatarFileName: $0.characterAvatarURI)
                }
            )
            .ignoresSafeArea()

            NavigationSplitView {
                sidebar
            } detail: {
                detailView
            }
            .toolbar {
                navigationToolbar
            }
            // Keep the native toolbar items interactive, but remove its default
            // window-wide material shelf.
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        }
        .containerBackground(.clear, for: .window)
        .background {
            WindowTransparencyBridge(
                transparency: preferences.windowTransparency,
                reduceTransparency: reduceTransparency
            )
        }
        .task {
            await viewModel.loadRecentChats()
        }
        // macOS sheets are modal and cannot be dismissed by clicking outside, so the
        // profile uses a transient popover, which is dismissed by an outside click.
        .sheet(isPresented: $isShowingFeedCreatorProfile) {
            if let feedProfileUsername {
                PublicFeedCreatorProfileView(
                    username: feedProfileUsername,
                    authStore: authStore
                )
                .frame(minWidth: 460, minHeight: 520)
            }
        }
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

    @ToolbarContentBuilder
    private var navigationToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                isConversationSearchFocused = true
            } label: {
                Label("Search conversations", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: .command)
            .help("Search conversations")
        }

        ToolbarItem(placement: .navigation) {
            Button {
                selectedChatID = nil
                isShowingFeed = false
                isShowingDiscover = true
            } label: {
                Label("Discover", systemImage: "sparkles")
            }
            .help("Discover")
        }

        ToolbarItem(placement: .navigation) {
            Button {
                selectedChatID = nil
                isShowingDiscover = false
                isShowingFeed = true
            } label: {
                Label("Feed", systemImage: "text.bubble")
            }
            .help("Feed")
        }

        ToolbarItem(placement: .primaryAction) {
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
                Label("New Conversation", systemImage: "square.and.pencil")
            }
            .disabled(viewModel.isLoading || selectedConversation == nil)
            .help("New Conversation")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                guard let selectedConversation else {
                    return
                }
                profileCharacterID = selectedConversation.characterID
            } label: {
                Label("Character Profile", systemImage: "info.circle")
            }
            .disabled(selectedConversation == nil)
            .help("Character Profile")
        }
    }

    @discardableResult
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
        isShowingDiscover = false
        isShowingFeed = false

        await viewModel.loadRecentChats()

        if viewModel.recentChats.contains(where: { $0.chatID == newChatID }) {
            pendingCreatedChat = nil
        }

        return true
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
                        isShowingFeed = false
                    }
                }
            )
        ) { conversation in
            ConversationRow(
                conversation: conversation,
                avatarCornerRadius: preferences.listAvatarCornerRadius,
                isSelected: selectedChatID == conversation.chatID
            )
            .tag(conversation.chatID)
            .listItemTint(.monochrome)
            .foregroundStyle(.primary)
            .background { NativeListSelectionAppearance().allowsHitTesting(false) }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(
                EdgeInsets(
                    top: 2,
                    leading: 6,
                    bottom: 2,
                    trailing: 6
                )
            )
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
        }
        // Native `.searchable(placement: .sidebar)` reserves a blurred shelf
        // across every split-view column. Keep the search local to navigation
        // so it cannot obscure the character identity or first message.
        .safeAreaInset(edge: .top, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.caiMuted)
                TextField("Search characters…", text: $conversationSearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.caiText)
                    .focused($isConversationSearchFocused)
                    .accessibilityLabel("Search characters")
                    .onKeyPress(.escape) {
                        conversationSearchText = ""
                        isConversationSearchFocused = false
                        return .handled
                    }
                if !conversationSearchText.isEmpty {
                    Button {
                        conversationSearchText = ""
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
            .padding(.top, 8)
        }
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
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        .scrollContentBackground(.hidden)
        .navigationTitle("Conversations")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 6) {
                Button {
                    guard let selectedConversation else { return }
                    Task {
                        await startConversation(
                            characterID: selectedConversation.characterID,
                            name: selectedConversation.characterName,
                            avatarFileName: selectedConversation.characterAvatarURI
                        )
                    }
                } label: {
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
                .disabled(viewModel.isLoading || selectedConversation == nil)
                .padding(.horizontal, 10)

                userProfileControl
            }
        }
        .glassSurface(.navigation, cornerRadius: 14)
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
    }
    
    // MARK: User Profile (bottom-left control, account menu, profile popover)

    @StateObject private var userProfileViewModel: UserProfileViewModel
    @State private var isShowingUserProfile = false
    @State private var isShowingAccountMenu = false
    @State private var isConfirmingSignOut = false
    @Environment(\.openSettings) private var openSettings

    private var userProfileControl: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                isShowingAccountMenu = true
            } label: {
                UserProfileControl(
            viewModel: userProfileViewModel,
            menuAction: {
                isShowingAccountMenu = true
            },
            profileAction: { externalID in
                isShowingUserProfile = false
                profileCharacterID = externalID
            }
        )
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isShowingAccountMenu, arrowEdge: .bottom) {
                accountMenu
            }
            .popover(isPresented: $isShowingUserProfile, arrowEdge: .bottom) {
                UserProfileDetailView(
                    viewModel: userProfileViewModel,
                    onSelectCharacter: { externalID in
                        isShowingUserProfile = false
                        profileCharacterID = externalID
                    }
                )
            }
            .sheet(isPresented: $isShowingFeedCreatorProfile) {
                if let feedProfileUsername {
                    PublicFeedCreatorProfileView(
                        username: feedProfileUsername,
                        authStore: authStore
                    )
                    .frame(minWidth: 460, minHeight: 520)
                }
            }
        }
    }

    private var accountMenu: some View {
        VStack(spacing: 2) {
            if isConfirmingSignOut {
                // Inline two-step confirmation: dialogs/sheets are unreliable
                // inside popovers on macOS.
                VStack(spacing: 8) {
                    Text("Sign out of Character.AI?")
                        .font(.callout.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text("You will need to paste your session token again to sign back in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 8) {
                        Button("Cancel") {
                            isConfirmingSignOut = false
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))

                        Button("Sign Out", role: .destructive) {
                            isShowingAccountMenu = false
                            isConfirmingSignOut = false
                            authStore.clearSession()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                    }
                }
                .padding(12)
            } else {
                if let username = authStore.session?.username {
                    Text("@\(username)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                        .padding(.bottom, 2)
                }

                GlassActionRow(
                    title: "View Profile",
                    systemImage: "person.crop.circle"
                ) {
                    isShowingAccountMenu = false
                    isShowingUserProfile = true
                }

                Divider()

                GlassActionRow(
                    title: "Preferences…",
                    systemImage: "gear"
                ) {
                    isShowingAccountMenu = false
                    openSettings()
                }

                Divider()

                GlassActionRow(
                    title: "Sign Out",
                    systemImage: "rectangle.portrait.and.arrow.right",
                    role: .destructive
                ) {
                    isConfirmingSignOut = true
                }
            }
        }
        .padding(8)
        .frame(width: 220)
        .background { ShellEnvironmentalBackground() }
        .presentationBackground(.regularMaterial)
    }

    private struct ConversationRow: View {
        let conversation: ConversationSummary
        let avatarCornerRadius: CGFloat
        let isSelected: Bool

        @Environment(\.colorScheme) private var colorScheme
        @State private var isHovering = false
        @ObservedObject private var preferences = AppPreferences.shared

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        private let rowCornerRadius: CGFloat = 10

        var body: some View {
            HStack(spacing: 10) {
                avatar

                VStack(
                    alignment: .leading,
                    spacing: 3
                ) {
                    HStack(spacing: 6) {
                        Text(conversation.characterName)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(Color.caiText)
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        Text(relativeDate)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.caiMuted)
                    }

                    if let lastMessage = conversation.lastMessage,
                       !lastMessage.isEmpty {
                        Text(lastMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.caiMuted)
                            .lineLimit(1)
                    } else {
                        Text(
                            conversation.state == "STATE_ACTIVE"
                                ? "Active"
                                : "Archived"
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(
                            conversation.state == "STATE_ACTIVE"
                                ? Color.caiMuted
                                : Color.caiMuted.opacity(0.6)
                        )
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(rowBackground)
            .contentShape(Rectangle())
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .onHover { isHovering = $0 }
            .animation(reduceMotion ? nil : GlassMetrics.interaction, value: isSelected)
            .animation(reduceMotion ? nil : GlassMetrics.interaction, value: isHovering)
            .opacity(
                conversation.state == "STATE_ACTIVE"
                    ? 1
                    : 0.72
            )
        }

        @ViewBuilder
        private var rowBackground: some View {
            let shape = RoundedRectangle(
                cornerRadius: rowCornerRadius,
                style: .continuous
            )

            if isSelected {
                EnvironmentalSelectionBackground(cornerRadius: rowCornerRadius)
            } else if isHovering {
                shape.fill(Color.white.opacity(0.04))
            } else {
                shape.fill(Color.clear)
            }
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
                                .controlSize(.small)

                        @unknown default:
                            fallbackAvatar
                        }
                    }
                } else {
                    fallbackAvatar
                }            }

            .frame(
                width: 36,
                height: 36
            )
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        }

        private var fallbackAvatar: some View {
            ZStack {                Circle()
                    .fill(ShellEnvironmentalBackground.environmentalSurfaceTint(isDark: colorScheme == .dark))

                Text(
                    conversation.characterName
                        .prefix(1)
                        .uppercased()
                )

                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.caiText)
            }
            .frame(
                width: 36,
                height: 36
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
        } else if isShowingFeed {
            FeedView(
                authStore: authStore,
                onSelectCharacter: { characterID in
                    profileCharacterID = characterID
                },
                onSelectCreator: { username in
                    feedProfileUsername = username
                    isShowingFeedCreatorProfile = true
                }
            )
        } else if let selectedChat = selectedConversation {
            ChatView(
                chatID: selectedChat.chatID,
                characterID: selectedChat.characterID,
                avatarFileName: selectedChat.characterAvatarURI,
                authStore: authStore,
                onConversationCreated: { newChatID in
                    pendingCopiedConversation = ConversationSummary(
                        id: newChatID,
                        chatID: newChatID,
                        characterID: selectedChat.characterID,
                        characterName: selectedChat.characterName,
                        characterAvatarURI: selectedChat.characterAvatarURI,
                        lastUpdated: ISO8601DateFormatter().string(from: Date()),
                        state: "STATE_ACTIVE",
                        lastMessage: nil
                    )
                    selectedChatID = newChatID
                    Task {
                        await viewModel.loadRecentChats()
                        if viewModel.recentChats.contains(where: { $0.chatID == newChatID }) {
                            pendingCopiedConversation = nil
                        }
                    }
                }
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
