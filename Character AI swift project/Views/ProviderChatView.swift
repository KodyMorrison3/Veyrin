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

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
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
                    .padding(24)
                    .frame(maxWidth: GlassMetrics.contentWidth)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: viewModel.messages.count) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: viewModel.streamingText) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).padding(.horizontal, 24)
            }
            if viewModel.wasInterrupted {
                HStack {
                    Text("Response interrupted. Partial text has been kept.").font(.caption).foregroundStyle(.secondary)
                    Button("Retry Response") { viewModel.retry() }.disabled(viewModel.isGenerating)
                }.padding(8)
            }
            HStack(alignment: .bottom, spacing: 12) {
                TextField("Message \(viewModel.provider.descriptor.name)…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($focused)
                    .disabled(viewModel.isGenerating)
                    .onSubmit(send)
                if viewModel.isGenerating {
                    Button("Stop", systemImage: "stop.fill") { viewModel.cancel() }
                        .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button("Send", systemImage: "arrow.up") { send() }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(14)
            .glassSurface(.characterHeader, cornerRadius: GlassMetrics.composerRadius, isFocused: focused)
            .frame(maxWidth: min(GlassMetrics.contentWidth, 680))
            .padding(20)
        }
        .background { ShellEnvironmentalBackground().ignoresSafeArea() }
        .navigationTitle(viewModel.character?.name ?? viewModel.provider.descriptor.name)
        .navigationSubtitle(viewModel.model)
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
            ToolbarItem {
                RoleplayPersonaControl(context: roleplayPersona, isGenerating: viewModel.isGenerating)
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
        guard !viewModel.isGenerating, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        viewModel.send(draft)
        draft = ""
    }

    private func row(_ content: String, user: Bool, streaming: Bool) -> some View {
        HStack(alignment: .top) {
            if user { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 5) {
                Text(user ? "You" : (viewModel.character?.name ?? viewModel.provider.descriptor.name)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                CharacterMessageFormattingView(content: content, expandsToFill: false, isStreaming: streaming)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .glassSurface(user ? .userMessage : .characterMessage, cornerRadius: GlassMetrics.messageRadius)
            }
            .frame(maxWidth: 560, alignment: user ? .trailing : .leading)
            if !user { Spacer(minLength: 40) }
        }
    }
}
