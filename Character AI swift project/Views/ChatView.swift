import SwiftUI

struct ChatView: View {
    @StateObject private var viewModel: ChatViewModel
    @State private var messageText = ""
    @State private var turnToRewind: Turn?
    @State private var turnToStartConversationFrom: Turn?
    @State private var selectedModelType: String?

    let chatID: String
    let characterID: String
    let onConversationCreated: ((String) -> Void)?

    init(
        chatID: String,
        characterID: String,
        authStore: AuthStore,
        onConversationCreated: ((String) -> Void)? = nil
    ) {
        self.chatID = chatID
        self.characterID = characterID
        self.onConversationCreated = onConversationCreated

        _viewModel = StateObject(
            wrappedValue: ChatViewModel(
                authStore: authStore
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            characterHeader

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(
                            viewModel.turns,
                            id: \.turnID
                        ) { turn in
                            MessageView(
                                turn: turn,
                                character: viewModel.character,
                                onRegenerate: turn.isHuman
                                    ? nil
                                    : {
                                        guard viewModel.rewindingFromTurnID == nil else {
                                            return
                                        }
                                        Task {
                                            await viewModel.regenerateResponse(
                                                turnID: turn.turnID,
                                                chatID: chatID
                                            )
                                        }
                                    },
                                onEdit: { newContent in
                                    guard let candidate = turn.candidates.first(where: {
                                        $0.candidateId == turn.primaryCandidateID
                                    }) else {
                                        return
                                    }

                                    Task {
                                        await viewModel.editMessage(
                                            turnID: turn.turnID,
                                            chatID: chatID,
                                            candidateID: candidate.candidateId,
                                            newContent: newContent
                                        )
                                    }
                                },
                                isPinning: viewModel.pinningTurnIDs.contains(turn.turnID),
                                onPin: {
                                    Task {
                                        await viewModel.togglePin(
                                            turnID: turn.turnID,
                                            chatID: chatID
                                        )
                                    }
                                },
                                isRewinding: viewModel.rewindingFromTurnID != nil,
                                onRewind: !viewModel.isGenerating && !viewModel.isLoading
                                    ? { turnToRewind = turn }
                                    : nil,
                                onStartNewConversation: !viewModel.isGenerating && !viewModel.isLoading
                                    ? {
                                        selectedModelType = nil
                                        turnToStartConversationFrom = turn
                                        Task {
                                            await viewModel.loadAvailableModels()
                                        }
                                    }
                                    : nil
                            )
                            .id(turn.turnID)
                        }
                    }
                    .padding()
                }
                .onChange(of: viewModel.turns.count) {
                    scrollToBottom(using: proxy)
                }
                .onChange(of: viewModel.turns.last?.turnID) {
                    scrollToBottom(using: proxy)
                }
            }

            Divider()

            HStack(spacing: 8) {
                TextField(
                    "Message...",
                    text: $messageText
                )
                .textFieldStyle(.plain)
                .disabled(viewModel.isGenerating || viewModel.rewindingFromTurnID != nil)
                .onSubmit {
                    sendMessage()
                }

                Button {
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(
                            .system(
                                size: 12,
                                weight: .semibold
                            )
                        )
                        .frame(
                            width: 24,
                            height: 24
                        )
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .disabled(
                    viewModel.isGenerating ||
                    viewModel.rewindingFromTurnID != nil ||
                    messageText
                        .trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                        .isEmpty
                )
                .keyboardShortcut(
                    .return,
                    modifiers: []
                )
            }
            .padding(.leading, 12)
            .padding(.trailing, 5)
            .padding(.vertical, 5)
            .glassEffect(
                .regular,
                in: .capsule
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .confirmationDialog(
            "Rewind conversation?",
            isPresented: Binding(
                get: { turnToRewind != nil },
                set: { isPresented in
                    if !isPresented {
                        turnToRewind = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Rewind from this message", role: .destructive) {
                guard let turn = turnToRewind else {
                    return
                }
                turnToRewind = nil
                Task {
                    await viewModel.rewind(
                        fromTurnID: turn.turnID,
                        chatID: chatID
                    )
                }
            }
            Button("Cancel", role: .cancel) {
                turnToRewind = nil
            }
        } message: {
            Text("This message and every later turn will be permanently removed from this conversation.")
        }
        .alert(
            "Unable to Rewind Conversation",
            isPresented: Binding(
                get: { viewModel.rewindErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.rewindErrorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                viewModel.rewindErrorMessage = nil
            }
        } message: {
            Text(viewModel.rewindErrorMessage ?? "Please try again.")
        }
        .sheet(isPresented: Binding(
            get: { turnToStartConversationFrom != nil },
            set: { if !$0 { turnToStartConversationFrom = nil } }
        )) {
            modelSelectionSheet
        }
        .alert(
            "Unable to Start New Conversation",
            isPresented: Binding(
                get: { viewModel.startConversationErrorMessage != nil },
                set: { if !$0 { viewModel.startConversationErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                viewModel.startConversationErrorMessage = nil
            }
        } message: {
            Text(viewModel.startConversationErrorMessage ?? "Please try again.")
        }
        .alert(
            "Unable to Update Pin",
            isPresented: Binding(
                get: { viewModel.pinErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.pinErrorMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                viewModel.pinErrorMessage = nil
            }
        } message: {
            Text(viewModel.pinErrorMessage ?? "Please try again.")
        }
        .task {
            await viewModel.loadCharacter(
                externalID: characterID
            )

            await viewModel.loadRealTurns(
                chatID: chatID
            )
        }
        .onChange(of: viewModel.availableModels.map(\.modelType)) {
            guard selectedModelType == nil,
                  let firstModel = viewModel.availableModels.first else {
                return
            }
            selectedModelType = firstModel.modelType
        }
        .onDisappear {
            viewModel.disconnect()
        }
    }

    private var modelSelectionSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Select AI model")
                .font(.title2.weight(.semibold))

            if viewModel.isLoadingAvailableModels {
                ProgressView("Loading available models…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.availableModels.isEmpty {
                ContentUnavailableView(
                    "Models Unavailable",
                    systemImage: "sparkles",
                    description: Text(
                        viewModel.availableModelsErrorMessage ??
                            "Available models could not be loaded."
                    )
                )
                Spacer(minLength: 0)
            } else {
                List(viewModel.availableModels) { model in
                    Button {
                        selectedModelType = model.modelType
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selectedModelType == model.modelType
                                  ? "largecircle.fill.circle"
                                  : "circle")
                                .foregroundStyle(.tint)
                                .frame(width: 20, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.displayName)
                                    .foregroundStyle(.primary)
                                Text(model.modelType)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if model.isPlusOnly {
                                Text("Plus")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            if model.isBeta {
                                Text("Beta")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            if model.isLegacy {
                                Text("Legacy")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            if model.isFeatured {
                                Text("Featured")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }

            HStack {
                Button("Cancel") {
                    turnToStartConversationFrom = nil
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create conversation") {
                    guard let turn = turnToStartConversationFrom,
                          let selectedModelType else {
                        return
                    }
                    Task {
                        guard let newChatID = await viewModel.createConversation(
                            from: turn,
                            modelType: selectedModelType
                        ) else {
                            return
                        }
                        turnToStartConversationFrom = nil
                        onConversationCreated?(newChatID)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    selectedModelType == nil ||
                    viewModel.isLoadingAvailableModels ||
                    viewModel.isCreatingConversationFromTurn ||
                    viewModel.availableModels.isEmpty
                )
                if viewModel.isCreatingConversationFromTurn {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 400, minHeight: 460)
    }

    private func sendMessage() {
        let trimmedMessage = messageText
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard !trimmedMessage.isEmpty else {
            return
        }

        messageText = ""

        Task {
            await viewModel.sendMessage(
                trimmedMessage,
                chatID: chatID
            )
        }
    }
    
    private func scrollToBottom(
        using proxy: ScrollViewProxy
    ) {
        guard let lastTurn = viewModel.turns.last else {
            return
        }

        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(
                lastTurn.turnID,
                anchor: .bottom
            )
        }
    }
    
    private var characterHeader: some View {
        HStack(spacing: 12) {
            if let character = viewModel.character {
                characterHeaderAvatar(character: character)

                VStack(alignment: .leading, spacing: 2) {
                    Text(character.name)
                        .font(.headline)

                    Text(character.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                ProgressView()
                    .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Loading character...")
                        .font(.headline)

                    Text("Connecting...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding()
    }

    @ViewBuilder
    private func characterHeaderAvatar(
        character: Character
    ) -> some View {
        if let avatarURL = CharacterImageURL.makeURL(
            avatarFileName: character.avatarFileName
        ) {
            AsyncImage(url: avatarURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()

                case .failure:
                    fallbackHeaderAvatar(
                        character: character
                    )

                case .empty:
                    ProgressView()

                @unknown default:
                    fallbackHeaderAvatar(
                        character: character
                    )
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())
        } else {
            fallbackHeaderAvatar(
                character: character
            )
        }
    }

    private func fallbackHeaderAvatar(
        character: Character
    ) -> some View {
        ZStack {
            Circle()
                .fill(.secondary.opacity(0.15))

            Text(character.name.prefix(1))
                .font(.title3)
                .fontWeight(.semibold)
        }
        .frame(width: 44, height: 44)
    }
}
