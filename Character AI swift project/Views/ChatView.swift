import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @StateObject private var viewModel: ChatViewModel
    @ObservedObject private var preferences = AppPreferences.shared
    @State private var messageText = ""
    @State private var attachments: [ComposerAttachment] = []
    @State private var attachmentNotice: String?
    @FocusState private var isMessageFieldFocused: Bool
    @State private var turnToRewind: Turn?
    @State private var turnToStartConversationFrom: Turn?
    @State private var selectedModelType: String?
    @State private var isLoadingPersonaControls = false
    @State private var activeChatModelType: String?
    @State private var isShowingMemory = false
    @State private var personaSelectionErrorMessage: String?
    @State private var environmentalArtwork: Image?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isDark: Bool { colorScheme == .dark }

    let chatID: String
    let characterID: String
    let avatarFileName: String?
    let onConversationCreated: ((String) -> Void)?
    let onSelectHistoryChat: ((ChatPreview) -> Void)?

    init(
        chatID: String,
        characterID: String,
        avatarFileName: String? = nil,
        authStore: AuthStore,
        onConversationCreated: ((String) -> Void)? = nil,
        onSelectHistoryChat: ((ChatPreview) -> Void)? = nil
    ) {
        self.chatID = chatID
        self.characterID = characterID
        self.avatarFileName = avatarFileName
        self.onConversationCreated = onConversationCreated
        self.onSelectHistoryChat = onSelectHistoryChat

        _viewModel = StateObject(
            wrappedValue: ChatViewModel(
                authStore: authStore
            )
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            // Clear spacer so top turns scroll underneath the floating toolbar
                            Color.clear
                                .frame(height: 52)

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
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                        .frame(maxWidth: GlassMetrics.contentWidth)
                        .frame(maxWidth: .infinity)
                        .animation(reduceMotion ? nil : GlassMetrics.interaction, value: viewModel.turns.count)
                    }
                    .scrollEdgeEffectHidden()
                    .onChange(of: viewModel.turns.count) {
                        scrollToBottom(using: proxy)
                    }
                    .onChange(of: viewModel.turns.last?.turnID) {
                        scrollToBottom(using: proxy)
                    }
                }

                attachmentTray

                composer
            }

            // Compact Floating Character Toolbar from Image 1
            floatingCharacterToolbar
                .padding(.top, 10)
        }
        // MainView owns the full-window environment, including this column.
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
            Text("This message will remain. Every later turn will be permanently removed from this conversation.")
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
        .sheet(isPresented: $isShowingMemory) {
            MemoryFactsSheet(
                facts: viewModel.conversationFacts,
                isLoading: viewModel.isLoadingFacts,
                errorMessage: viewModel.conversationFactsErrorMessage,
                dismiss: { isShowingMemory = false }
            )
            .frame(width: 520, height: 460)
            .background { ShellEnvironmentalBackground(vignetteStrength: 0.35) }
            .presentationBackground(.regularMaterial)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
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
                set: { if !$0 { viewModel.pinErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                viewModel.pinErrorMessage = nil
            }
        } message: {
            Text(viewModel.pinErrorMessage ?? "Please try again.")
        }
        .task {
            isLoadingPersonaControls = true
            defer { isLoadingPersonaControls = false }
            await viewModel.loadCharacter(
                externalID: characterID
            )

            await viewModel.loadChat(
                chatID: chatID
            )
            activeChatModelType = viewModel.chat?.preferredModelType

            await viewModel.loadRealTurns(
                chatID: chatID
            )

            await viewModel.loadCharacterVotedStatus(
                characterID: characterID
            )

            await viewModel.loadRecentCharacterChats(
                characterID: characterID
            )

            await viewModel.loadAvailableModels()

            await PersonaStore.shared.fetchRemotePersonas(
                authenticatedClient: viewModel.authenticatedHTTPClient,
                currentCharacterID: characterID
            )
        }
        .onChange(of: viewModel.chat?.preferredModelType) {
            activeChatModelType = viewModel.chat?.preferredModelType
            if let modelType = viewModel.chat?.preferredModelType, !modelType.isEmpty {
                selectedModelType = modelType
            }
        }
        .alert(
            "Unable to Continue Conversation",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                viewModel.errorMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? "Please try again.")
        }
        .alert(
            "Unable to Update Persona",
            isPresented: Binding(
                get: { personaSelectionErrorMessage != nil },
                set: { if !$0 { personaSelectionErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                personaSelectionErrorMessage = nil
            }
        } message: {
            Text(personaSelectionErrorMessage ?? "Please try again.")
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
        .navigationTitle(Text(verbatim: ""))
    }

    private var floatingCharacterToolbar: some View {
        HStack(spacing: 10) {
            if let character = viewModel.character {
                characterHeaderAvatar(character: character)

                VStack(alignment: .leading, spacing: 2) {
                    Text(character.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.caiText)
                        .lineLimit(1)

                    Text(character.title.isEmpty ? "By @CharacterAI" : character.title)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.caiMuted)
                        .lineLimit(1)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Loading character…")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.caiText)

                    Text("Connecting…")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.caiMuted)
                }
            }

            Spacer(minLength: 16)

        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .frame(height: 44)
        .frame(maxWidth: 440)
        .glassSurface(.characterHeader, cornerRadius: 22)
        .animation(reduceMotion ? nil : GlassMetrics.interaction, value: viewModel.character != nil)
    }

    /// Unified capsule composer: persona, staged image picker, input, and send
    /// share one continuous Liquid Glass capsule.
    /// Behaviour — FocusState, Return-to-send, generating and disabled
    /// states — is unchanged.
    private var composer: some View {
        HStack(alignment: .center, spacing: 8) {
            // Persona avatar entry point on the left
            ComposerPersonaAvatarButton(
                currentCharacterID: viewModel.character?.externalID,
                authenticatedHTTPClient: viewModel.authenticatedHTTPClient,
                availableModels: viewModel.availableModels,
                selectedModelType: selectedModelType,
                canStartModelConversation: !viewModel.turns.isEmpty
                    && !viewModel.isGenerating
                    && !viewModel.isLoading
                    && viewModel.rewindingFromTurnID == nil
                    && !viewModel.isCreatingConversationFromTurn,
                recentChats: viewModel.recentCharacterChats.filter { $0.chatID != chatID },
                isLoadingHistory: viewModel.isLoadingCharacterHistory,
                historyErrorMessage: viewModel.characterHistoryErrorMessage,
                isCreatingConversation: viewModel.isCreatingConversationFromTurn,
                isPersonaSelectionInProgress: PersonaStore.shared.isSelectingPersona,
                isLoadingPersonas: isLoadingPersonaControls || PersonaStore.shared.isLoadingPersonas,
                onSelectModel: { modelType in
                    guard let turn = viewModel.turns.last(where: { $0.chatID == chatID }) else { return }
                    Task {
                        guard let newChatID = await viewModel.createConversation(from: turn, modelType: modelType) else {
                            return
                        }
                        onConversationCreated?(newChatID)
                    }
                },
                onSelectPersona: { persona in
                    let didSelect = await PersonaStore.shared.selectPersona(
                        persona,
                        forCharacterID: viewModel.character?.externalID,
                        authenticatedClient: viewModel.authenticatedHTTPClient
                    )
                    if !didSelect {
                        personaSelectionErrorMessage = PersonaStore.shared.personaSelectionErrorMessage
                    }
                    return didSelect
                },
                onOpenMemory: {
                    isShowingMemory = true
                    Task { await viewModel.loadFacts(chatID: chatID) }
                },
                onOpenHistory: { recentChat in
                    onSelectHistoryChat?(recentChat)
                },
                onRefreshHistory: {
                    Task {
                        await viewModel.loadRecentCharacterChats(characterID: characterID)
                    }
                }
            )

            Button {
                presentImageOpenPanel()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.caiMuted)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(ShellEnvironmentalBackground.environmentalSurfaceTint(isDark: isDark)))
            }
            .buttonStyle(.plain)
            .help("Stage images for preview; images are not sent")
            .accessibilityLabel("Stage images for preview; images are not sent")

            if viewModel.isGenerating {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Generating response")
                    Text("\(viewModel.character?.name ?? "Character") is typing…")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.caiMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(
                    viewModel.character?.name != nil ? "Message \(viewModel.character!.name)..." : "Message...",
                    text: $messageText,
                    axis: .vertical
                )
                .lineLimit(1...4)
                .font(.system(size: 14))
                .textFieldStyle(.plain)
                .foregroundStyle(Color.caiText)
                .focused($isMessageFieldFocused)
                .disabled(isComposerInputDisabled)
                .onSubmit { sendMessage() }
                .onKeyPress(keys: [.return], phases: .down) { press in
                    guard !press.modifiers.contains(.shift) else { return .ignored }
                    if !isSendDisabled { sendMessage() }
                    return .handled
                }
            }

            Button { sendMessage() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: GlassMetrics.sendDiameter, height: GlassMetrics.sendDiameter)
            }
            .buttonStyle(SendCircleButtonStyle())
            .disabled(isSendDisabled)
            .keyboardShortcut(.return, modifiers: [])
            .accessibilityLabel("Send message")
            .opacity(isSendDisabled ? 0.40 : 1)
            .animation(reduceMotion ? nil : GlassMetrics.interaction, value: isSendDisabled)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: GlassMetrics.composerHeight)
        // Same Liquid Glass recipe as the character banner: translucent
        // system glass over the environment, no opaque fill, no shadow.
        .glassSurface(
            .characterHeader,
            cornerRadius: GlassMetrics.composerRadius,
            isFocused: isMessageFieldFocused
        )
        .frame(maxWidth: min(GlassMetrics.contentWidth, 680))
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 16)
        .animation(reduceMotion ? nil : GlassMetrics.interaction, value: isComposerInputDisabled)
    }

    private var modelSelectionSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Conversation")
                .font(.title2.weight(.semibold))
            if let character = viewModel.character {
                HStack(spacing: 10) {
                    if let environmentalArtwork {
                        environmentalArtwork.resizable().scaledToFill()
                            .frame(width: 32, height: 32)
                            .clipShape(Circle())
                    } else {
                        fallbackHeaderAvatar(character: character)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(character.name).font(.headline)
                        Text(character.title).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Select AI model")
                .font(.headline)

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
                .scrollContentBackground(.hidden)
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
        .background {
            ShellEnvironmentalBackground()
        }
        .presentationBackground(.regularMaterial)
    }

    private var isComposerInputDisabled: Bool {
        viewModel.isGenerating || viewModel.rewindingFromTurnID != nil
    }

    private var isSendDisabled: Bool {
        isComposerInputDisabled ||
            messageText.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
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

        if !attachments.isEmpty {
            // No confirmed upload protocol: the text sends exactly as
            // before and staged images are kept, never silently dropped.
            attachmentNotice =
                "Image sending isn't available yet — text sent, attachments kept."
        }

        Task {
            await viewModel.sendMessage(
                trimmedMessage,
                chatID: chatID
            )
        }
    }

    // MARK: - Image attachments (picker + preview UI only)

    /// An image staged in the composer. Bytes are copied into memory at
    /// pick time (sandbox-safe), so the selection survives send attempts
    /// and is only ever removed by the explicit remove button.
    private struct ComposerAttachment: Identifiable {
        let id = UUID()
        let fileName: String
        let image: NSImage
        let data: Data
    }

    /// Staged-attachment strip above the composer: thumbnails with remove
    /// controls plus an honest notice line. Hidden entirely when empty.
    @ViewBuilder
    private var attachmentTray: some View {
        if !attachments.isEmpty || attachmentNotice != nil {
            VStack(alignment: .leading, spacing: 6) {
                if !attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(attachments) { attachment in
                                attachmentThumbnail(attachment)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                if let attachmentNotice {
                    Label(attachmentNotice, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: min(GlassMetrics.contentWidth, 680))
            .padding(.horizontal, 24)
            .padding(.top, 8)
        }
    }

    private func attachmentThumbnail(
        _ attachment: ComposerAttachment
    ) -> some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: attachment.image)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                }
                .help(attachment.fileName)
            Button {
                attachments.removeAll { $0.id == attachment.id }
                if attachments.isEmpty {
                    attachmentNotice = nil
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .background(Circle().fill(ShellEnvironmentalBackground.environmentalSurfaceTint(isDark: isDark)))
            }
            .buttonStyle(.plain)
            .help("Remove attachment")
            .offset(x: 6, y: -6)
        }
        .padding(.top, 6)
        .padding(.trailing, 6)
    }

    /// Native macOS image picker (app-modal NSOpenPanel, no binding to
    /// lose). Only image types are selectable; cancelling leaves staged
    /// attachments untouched.
    private func presentImageOpenPanel() {
        let panel = NSOpenPanel()
        panel.message = "Choose images to attach"
        panel.prompt = "Attach"
        panel.allowedContentTypes = [.png, .jpeg, .gif, .heic, .heif, .webP]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else {
                return
            }
            handlePickedImages(.success(panel.urls))
        }
    }

    /// Native file-import result: copy each readable image into memory
    /// under scoped access. Failures report a notice; staged attachments
    /// already present are never touched.
    private func handlePickedImages(
        _ result: Result<[URL], Error>
    ) {
        guard case .success(let urls) = result, !urls.isEmpty else {
            // Picker cancelled or failed: keep everything already staged.
            return
        }
        var failures = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            guard let data = try? Data(contentsOf: url),
                  let nsImage = NSImage(data: data) else {
                failures += 1
                continue
            }
            attachments.append(
                ComposerAttachment(
                    fileName: url.lastPathComponent,
                    image: nsImage,
                    data: data
                )
            )
        }
        if failures > 0 {
            attachmentNotice = failures == 1
                ? "One image couldn't be attached."
                : "\(failures) images couldn't be attached."
        } else {
            attachmentNotice = nil
        }
    }
    
    private func scrollToBottom(
        using proxy: ScrollViewProxy
    ) {
        guard let lastTurn = viewModel.turns.last else {
            return
        }

        withAnimation(reduceMotion ? nil : GlassMetrics.interaction) {
            proxy.scrollTo(
                lastTurn.turnID,
                anchor: .bottom
            )
        }
    }

    @ViewBuilder
    private func characterHeaderAvatar(
        character: Character
    ) -> some View {
        if let avatarURL = CharacterImageURL.makeURL(
            avatarFileName: character.avatarFileName
        ) {
            CachedAvatarView(url: avatarURL) {
                fallbackHeaderAvatar(character: character)
            }
            .frame(width: 30, height: 30)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
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
                .fill(ShellEnvironmentalBackground.environmentalSurfaceTint(isDark: isDark))

            Text(character.name.prefix(1))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.caiText)
        }
        .frame(width: 30, height: 30)
    }
}
