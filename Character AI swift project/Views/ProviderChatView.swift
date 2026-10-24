import SwiftUI

struct ProviderChatView: View {
    @ObservedObject var viewModel: ProviderChatViewModel
    @ObservedObject var accountPersonas: PersonaStore
    @StateObject private var roleplayPersona: RoleplayPersonaContext
    @State private var pendingCharacter: LocalCharacter?
    @State private var confirmingCharacterChange = false
    let onSwitch: () -> Void
    @State private var draft = ""
    @State private var editingMessageID: UUID?
    @State private var editedText = ""
    @State private var pendingRewind: ProviderChatMessage?
    @State private var pendingFork: ProviderChatMessage?
    @State private var hoveredMessageID: UUID?
    @State private var actionsMessageID: UUID?
    @State private var confirmingNewChat = false
    @State private var isShowingLibrary = false
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(viewModel: ProviderChatViewModel, accountPersonas: PersonaStore, onSwitch: @escaping () -> Void) {
        self.viewModel = viewModel
        self.accountPersonas = accountPersonas
        self.onSwitch = onSwitch
        _roleplayPersona = StateObject(wrappedValue: RoleplayPersonaContext(characterID: viewModel.character?.id,
                                                                          account: accountPersonas))
    }

    private var displayName: String {
        viewModel.character?.name ?? viewModel.provider.descriptor.name
    }

    private var isSendDisabled: Bool {
        viewModel.isGenerating || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Group {
            if isShowingLibrary {
                // The library the Character.AI window shows, plus Start chat and
                // Edit, so a character is chosen here rather than from a dropdown.
                LocalCharacterLibraryView(onStartChat: { chooseCharacter($0) })
            } else {
                conversation
            }
        }
        .background { ShellEnvironmentalBackground().ignoresSafeArea() }
        // The floating pill carries the identity; a title here would duplicate it.
        .navigationTitle(Text(verbatim: ""))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Switch Provider", systemImage: "arrow.triangle.swap") {
                    viewModel.cancel()
                    onSwitch()
                }
            }
            // Saved characters live in the same My Library screen the Character.AI
            // window uses, so a character is picked from a grid with Start chat and
            // Edit instead of from a dropdown of names.
            ToolbarItem(placement: .navigation) {
                Button("My Library", systemImage: "books.vertical") {
                    isShowingLibrary.toggle()
                }
                .help("Saved characters: start a chat, or edit About and the greeting")
                .accessibilityAddTraits(isShowingLibrary ? .isSelected : [])
            }
            ToolbarItem {
                Button("New Chat", systemImage: "square.and.pencil") {
                    if viewModel.messages.contains(where: { $0.role == .user }) {
                        confirmingNewChat = true
                    } else {
                        viewModel.newConversation()
                    }
                }
            }
            ToolbarItem { SettingsLink { Label("Settings", systemImage: "gearshape") } }
        }
        .confirmationDialog("Start a new conversation?",
                            isPresented: $confirmingNewChat,
                            titleVisibility: .visible) {
            Button("Start New Conversation", role: .destructive) { viewModel.newConversation() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces the saved conversation for this provider, model and character. It cannot be undone.")
        }
        .confirmationDialog("Rewind conversation?",
                            isPresented: Binding(
                                get: { pendingRewind != nil },
                                set: { if !$0 { pendingRewind = nil } }
                            ),
                            titleVisibility: .visible) {
            Button("Rewind from this message", role: .destructive) {
                guard let message = pendingRewind else { return }
                pendingRewind = nil
                viewModel.rewind(through: message.id)
            }
            Button("Cancel", role: .cancel) { pendingRewind = nil }
        } message: {
            Text("This message will remain. Every later message is removed from this chat and from its saved transcript, so the removed text cannot be recovered.")
        }
        .confirmationDialog("Start a new conversation from here?",
                            isPresented: Binding(
                                get: { pendingFork != nil },
                                set: { if !$0 { pendingFork = nil } }
                            ),
                            titleVisibility: .visible) {
            Button("Start New Conversation") {
                guard let message = pendingFork else { return }
                pendingFork = nil
                viewModel.fork(through: message.id)
            }
            Button("Cancel", role: .cancel) { pendingFork = nil }
        } message: {
            Text("The conversation continues from this message and every later message is removed from the saved transcript. This cannot be undone.")
        }
        .confirmationDialog("Start a new conversation with this character?", isPresented: $confirmingCharacterChange,
                            titleVisibility: .visible) {
            Button("Start New Conversation") {
                viewModel.setCharacter(pendingCharacter)
                pendingCharacter = nil
            }
            Button("Cancel", role: .cancel) { pendingCharacter = nil }
        } message: {
            Text("Each character keeps its own saved conversation for this provider and model. This one stays saved; the selected character's chat opens in its place, and nothing is sent until you send a message.")
        }
        .onAppear {
            viewModel.usePersonaContext(roleplayPersona)
            focused = !isShowingLibrary
        }
        .onChange(of: viewModel.character?.id) { roleplayPersona.setCharacter(viewModel.character?.id) }
        // The composer is off screen behind the library, so it must not hold the
        // keyboard while a character is being picked.
        .onChange(of: isShowingLibrary) { focused = !isShowingLibrary }
        .onDisappear { viewModel.cancel() }
    }

    /// The chat column, shown unless My Library is open in the same column.
    private var conversation: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            // Clear spacer so the first message scrolls under the floating header.
                            Color.clear
                                .frame(height: 52)

                            if viewModel.messages.isEmpty {
                                ContentUnavailableView("Start a Conversation", systemImage: "bubble.left.and.bubble.right",
                                                       description: Text("Messages go only to \(viewModel.provider.descriptor.name). This chat is saved on this Mac and resumes when you open the same provider, model and character again."))
                                    .frame(maxWidth: .infinity, minHeight: 280)
                            }
                            ForEach(viewModel.messages) { message in
                                row(message.content, message: message, streaming: false).id(message.id)
                            }
                            if viewModel.isGenerating {
                                row(viewModel.streamingText.isEmpty ? "…" : viewModel.streamingText, message: nil, streaming: true)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                        .frame(maxWidth: GlassMetrics.contentWidth)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollEdgeEffectHidden()
                    .onChange(of: viewModel.messages.count) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                        // A rewind can remove the row currently being edited.
                        if let editingMessageID,
                           !viewModel.messages.contains(where: { $0.id == editingMessageID }) {
                            self.editingMessageID = nil
                        }
                    }
                    .onChange(of: viewModel.streamingText) { proxy.scrollTo("bottom", anchor: .bottom) }
                }

                if let storageError = viewModel.storageErrorMessage {
                    Label(storageError, systemImage: "externaldrive.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: min(GlassMetrics.contentWidth, 680), alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 4)
                }
                if let error = viewModel.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: min(GlassMetrics.contentWidth, 680), alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 4)
                }
                if viewModel.wasInterrupted {
                    HStack(spacing: 8) {
                        Text("Response interrupted. Partial text has been kept.")
                            .font(.caption)
                            .foregroundStyle(Color.caiMuted)
                        Button("Retry Response") { viewModel.retry() }
                            .disabled(viewModel.isGenerating)
                    }
                    .frame(maxWidth: min(GlassMetrics.contentWidth, 680), alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 4)
                }

                composer
            }

            floatingHeader
                .padding(.top, 10)
        }
    }

    private var floatingHeader: some View {
        HStack(spacing: 10) {
            headerAvatar

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.caiText)
                    .lineLimit(1)
                Text(viewModel.model)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.caiMuted)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .frame(height: 44)
        // The pill hugs the identity instead of stretching across the window.
        .fixedSize(horizontal: true, vertical: false)
        .glassSurface(.characterHeader, cornerRadius: 22)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(displayName), \(viewModel.model)")
    }

    private var headerAvatar: some View {
        Group {
            if let fileName = viewModel.character?.avatarFileName,
               let url = CharacterImageURL.makeURL(avatarFileName: fileName) {
                CachedAvatarView(url: url) { headerFallbackAvatar }
            } else {
                headerFallbackAvatar
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }

    private var headerFallbackAvatar: some View {
        ZStack {
            Circle().fill(Color.caiPrimary.opacity(0.28))
            Image(systemName: viewModel.character == nil ? "cloud" : "person.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.caiText)
        }
    }

    private var composer: some View {
        HStack(alignment: .center, spacing: 8) {
            RoleplayPersonaControl(context: roleplayPersona, isGenerating: viewModel.isGenerating)
                .buttonStyle(.borderless)

            TextField("Message \(displayName)…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .font(.system(size: 14))
                .textFieldStyle(.plain)
                .foregroundStyle(Color.caiText)
                .focused($focused)
                .disabled(viewModel.isGenerating)
                .onSubmit(send)

            if viewModel.isGenerating {
                Button { viewModel.cancel() } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: GlassMetrics.sendDiameter, height: GlassMetrics.sendDiameter)
                }
                .buttonStyle(SendCircleButtonStyle())
                .keyboardShortcut(".", modifiers: .command)
                .accessibilityLabel("Stop generating")
            } else {
                Button { send() } label: {
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
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: GlassMetrics.composerHeight)
        .glassSurface(.characterHeader, cornerRadius: GlassMetrics.composerRadius, isFocused: focused)
        .frame(maxWidth: min(GlassMetrics.contentWidth, 680))
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 16)
    }

    /// Also the library's Start chat action and its "without a character" entry.
    private func chooseCharacter(_ character: LocalCharacter?) {
        isShowingLibrary = false
        guard character?.id != viewModel.character?.id else { return }
        if viewModel.messages.contains(where: { $0.role == .user }) {
            pendingCharacter = character
            confirmingCharacterChange = true
        } else {
            viewModel.setCharacter(character)
        }
    }

    private func send() {
        guard !isSendDisabled else { return }
        viewModel.send(draft)
        draft = ""
    }

    /// Mirrors MessageView: the assistant gets an avatar and name, the user just
    /// gets a right-aligned bubble, and both share the same glass shape.
    private func row(_ content: String, message: ProviderChatMessage?, streaming: Bool) -> some View {
        let isUser = message?.role == .user
        return HStack(alignment: .top, spacing: 10) {
            if isUser { Spacer(minLength: 40) }

            if !isUser { avatar }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                if !isUser {
                    Text(displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.caiText)
                        .padding(.leading, 4)
                }

                if let message, editingMessageID == message.id {
                    editor(for: message)
                } else {
                    // The actions button is an overlay beside the bubble, not a
                    // row under it, so showing it on hover cannot change this
                    // message's height and shove the rest of the transcript
                    // around. Same construction as MessageView in the
                    // Character.AI chat.
                    ZStack(alignment: isUser ? .bottomLeading : .bottomTrailing) {
                        bubble(content, isUser: isUser, streaming: streaming, message: message)

                        if let message, hoveredMessageID == message.id || actionsMessageID == message.id {
                            actionsButton(message)
                                // Sit just outside the bubble instead of on top of
                                // its last words. An offset cannot change layout.
                                .offset(x: isUser ? -32 : 32)
                                .transition(.opacity)
                        }
                    }
                }
            }
            .frame(maxWidth: isUser ? 480 : 520, alignment: isUser ? .trailing : .leading)

            if !isUser { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
        .transition(.opacity)
        .onHover { isHovering in
            guard let id = message?.id else { return }
            if isHovering {
                hoveredMessageID = id
            } else if hoveredMessageID == id {
                hoveredMessageID = nil
            }
        }
    }

    private func actionsButton(_ message: ProviderChatMessage) -> some View {
        Button {
            actionsMessageID = message.id
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.caiMuted)
                .frame(width: 22, height: 22)
                .background(Circle().fill(ShellEnvironmentalBackground.environmentalSurfaceTint(isDark: colorScheme == .dark)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Message actions")
        .popover(
            isPresented: Binding(
                get: { actionsMessageID == message.id },
                set: { if !$0 { actionsMessageID = nil } }
            ),
            arrowEdge: .top
        ) {
            VStack(alignment: .leading, spacing: 2) {
                messageActions(message)
            }
            .padding(8)
            .frame(width: 260)
            .presentationBackground(.regularMaterial)
        }
        .animation(reduceMotion ? nil : GlassMetrics.interaction, value: actionsMessageID)
        .padding(4)
    }

    @ViewBuilder
    private func bubble(_ content: String, isUser: Bool, streaming: Bool,
                        message: ProviderChatMessage?) -> some View {
        let styled = CharacterMessageFormattingView(content: content, expandsToFill: false, isStreaming: streaming)
            .font(.system(size: 14))
            .textSelection(.enabled)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassSurface(isUser ? .userMessage : .characterMessage, cornerRadius: GlassMetrics.messageRadius)
            .foregroundStyle(Color.caiText)
            .clipShape(RoundedRectangle(cornerRadius: GlassMetrics.messageRadius, style: .continuous))

        // The streaming reply is not a transcript message, so it has no actions.
        if let message {
            styled.contextMenu { messageActions(message) }
        } else {
            styled
        }
    }

    /// A provider chat has no candidate list or server copy, so the menu offers
    /// only actions that can be honoured against the in-memory transcript.
    @ViewBuilder
    private func messageActions(_ message: ProviderChatMessage) -> some View {
        GlassActionRow(title: "Copy message", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.content, forType: .string)
        }

        GlassActionRow(title: "Edit message", systemImage: "pencil",
                       isDisabled: viewModel.isGenerating) {
            editedText = message.content
            editingMessageID = message.id
        }

        if message.role == .assistant {
            Divider()

            GlassActionRow(title: "Regenerate response", systemImage: "arrow.clockwise",
                           isDisabled: !viewModel.canRegenerate(message.id)) {
                viewModel.regenerateMessage(message.id)
            }
        }

        Divider()

        GlassActionRow(title: "Rewind from here…", systemImage: "backward.end",
                       role: .destructive, isDisabled: viewModel.isGenerating) {
            pendingRewind = message
        }

        GlassActionRow(title: "Start new conversation from here…", systemImage: "plus.message",
                       isDisabled: viewModel.isGenerating) {
            pendingFork = message
        }
    }

    private func editor(for message: ProviderChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $editedText)
                .font(.system(size: 14))
                .frame(minHeight: 80)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .disabled(viewModel.isGenerating)

            HStack(spacing: 10) {
                Text("Editing drops every later message.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.caiMuted)

                Spacer(minLength: 8)

                Button("Cancel") { editingMessageID = nil }

                Button("Save") {
                    guard viewModel.editMessage(message.id, newContent: editedText) else { return }
                    editingMessageID = nil
                    editedText = ""
                }
                .buttonStyle(GlassProminentButtonStyle())
                .disabled(editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(10)
        .glassSurface(message.role == .user ? .userMessage : .characterMessage,
                      cornerRadius: GlassMetrics.messageRadius)
    }

    private var avatar: some View {
        Group {
            if let fileName = viewModel.character?.avatarFileName,
               let url = CharacterImageURL.makeURL(avatarFileName: fileName) {
                CachedAvatarView(url: url) { fallbackAvatar }
            } else {
                fallbackAvatar
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }

    private var fallbackAvatar: some View {
        ZStack {
            Circle().fill(Color.caiPrimary.opacity(0.28))
            Text(displayName.prefix(1).uppercased())
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.caiText)
        }
    }
}
