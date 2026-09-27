import SwiftUI

struct ChatView: View {
    @StateObject private var viewModel: ChatViewModel
    @State private var messageText = ""

    let chatID: String
    let characterID: String

    init(
        chatID: String,
        characterID: String,
        authStore: AuthStore
    ) {
        self.chatID = chatID
        self.characterID = characterID

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
                                character: viewModel.character
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
                .disabled(viewModel.isGenerating)
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
        .task {
            await viewModel.loadCharacter(
                externalID: characterID
            )

            await viewModel.loadRealTurns(
                chatID: chatID
            )
        }
        .onDisappear {
            viewModel.disconnect()
        }
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
