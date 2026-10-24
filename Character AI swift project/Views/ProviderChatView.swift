import SwiftUI

struct ProviderChatView: View {
    @ObservedObject var viewModel: ProviderChatViewModel
    @ObservedObject var accountPersonas: PersonaStore
    @StateObject private var roleplayPersona: RoleplayPersonaContext
    @StateObject private var library = LocalCharacterLibrary.shared
    @State private var pendingCharacter: LocalCharacter?
    @State private var confirmingCharacterChange = false
    let onSwitch: () -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

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
                                                       description: Text("Messages go only to \(viewModel.provider.descriptor.name). This chat is kept in memory until you start a new chat, switch providers or close the window."))
                                    .frame(maxWidth: .infinity, minHeight: 280)
                            }
                            ForEach(viewModel.messages) { message in
                                row(message.content, user: message.role == .user, streaming: false).id(message.id)
                            }
                            if viewModel.isGenerating {
                                row(viewModel.streamingText.isEmpty ? "…" : viewModel.streamingText, user: false, streaming: true)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                        .frame(maxWidth: GlassMetrics.contentWidth)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollEdgeEffectHidden()
                    .onChange(of: viewModel.messages.count) { proxy.scrollTo("bottom", anchor: .bottom) }
                    .onChange(of: viewModel.streamingText) { proxy.scrollTo("bottom", anchor: .bottom) }
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
            ToolbarItem {
                Button("New Chat", systemImage: "square.and.pencil") { viewModel.newConversation() }
            }
            ToolbarItem {
                Menu {
                    Button {
                        chooseCharacter(nil)
                    } label: {
                        if viewModel.character == nil { Label("No Character", systemImage: "checkmark") }
                        else { Text("No Character") }
                    }
                    Section("Saved Characters") {
                        if library.characters.isEmpty {
                            Text("Save characters from Character.AI → My Library first.")
                        }
                        ForEach(library.characters) { character in
                            Button { chooseCharacter(character) } label: {
                                if viewModel.character?.id == character.id {
                                    Label(character.name, systemImage: "checkmark")
                                } else { Text(character.name) }
                            }
                        }
                    }
                } label: {
                    Label(viewModel.character?.name ?? "Character", systemImage: "theatermasks")
                }
                .disabled(viewModel.isGenerating)
                .help("Choose a saved character and start with its greeting")
            }
            ToolbarItem { SettingsLink { Label("Settings", systemImage: "gearshape") } }
        }
        .confirmationDialog("Start a new conversation with this character?", isPresented: $confirmingCharacterChange,
                            titleVisibility: .visible) {
            Button("Start New Conversation") {
                viewModel.setCharacter(pendingCharacter)
                pendingCharacter = nil
            }
            Button("Cancel", role: .cancel) { pendingCharacter = nil }
        } message: {
            Text("The current in-memory chat will be discarded. Saved local-character history is not changed, and nothing is sent until you send a message.")
        }
        .onAppear {
            viewModel.usePersonaContext(roleplayPersona)
            focused = true
        }
        .onChange(of: viewModel.character?.id) { roleplayPersona.setCharacter(viewModel.character?.id) }
        .onDisappear { viewModel.cancel() }
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

    private func chooseCharacter(_ character: LocalCharacter?) {
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
    private func row(_ content: String, user: Bool, streaming: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if user { Spacer(minLength: 40) }

            if !user { avatar }

            VStack(alignment: .leading, spacing: 4) {
                if !user {
                    Text(displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.caiText)
                        .padding(.leading, 4)
                }
                CharacterMessageFormattingView(content: content, expandsToFill: false, isStreaming: streaming)
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .glassSurface(user ? .userMessage : .characterMessage, cornerRadius: GlassMetrics.messageRadius)
                    .foregroundStyle(Color.caiText)
                    .clipShape(RoundedRectangle(cornerRadius: GlassMetrics.messageRadius, style: .continuous))
                    .contextMenu {
                        Button("Copy Message", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(content, forType: .string)
                        }
                    }
            }
            .frame(maxWidth: user ? 480 : 520, alignment: user ? .trailing : .leading)

            if !user { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
        .transition(.opacity)
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
