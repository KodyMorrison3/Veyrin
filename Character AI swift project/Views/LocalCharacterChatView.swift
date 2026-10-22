import SwiftUI

struct LocalCharacterChatView: View {
    @StateObject private var library = LocalCharacterLibrary.shared
    @ObservedObject private var preferences = AppPreferences.shared
    @State private var conversation: LocalCharacterConversation?
    @State private var models: [String] = []
    @State private var selectedModel = ""
    @State private var message = ""
    @State private var errorMessage: String?
    @State private var isLoadingModels = false
    @State private var isGenerating = false
    @FocusState private var composerFocused: Bool
    @ObservedObject private var environmentalPaletteStore = EnvironmentalPaletteStore.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isDark: Bool { colorScheme == .dark }

    let character: LocalCharacter

    private var ollama: LocalOllamaService {
        try! LocalOllamaService(startsApplicationWhenUnavailable: preferences.startOllamaAutomatically)
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            Color.clear
                                .frame(height: 52)

                            if let conversation {
                                ForEach(conversation.messages) { item in
                                    messageRow(item)
                                        .id(item.id)
                                }
                            }
                            if isGenerating {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .controlSize(.small)
                                        .accessibilityLabel("Generating response")
                                    Text("\(character.name) is typing…")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Color.caiMuted)
                                    Spacer()
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                        .frame(maxWidth: GlassMetrics.contentWidth)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollEdgeEffectHidden()
                    .onChange(of: conversation?.messages.last?.id) {
                        guard let lastID = conversation?.messages.last?.id else { return }
                        withAnimation(reduceMotion ? nil : GlassMetrics.interaction) {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: min(GlassMetrics.contentWidth, 680), alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 4)
                }
                composer
            }

            floatingCharacterToolbar
                .padding(.top, 10)
        }
        .task {
            do { conversation = try library.conversation(for: character) }
            catch { errorMessage = error.localizedDescription }
            await loadModels()
        }
        .navigationTitle(Text(verbatim: ""))
    }

    private var floatingCharacterToolbar: some View {
        HStack(spacing: 10) {
            headerAvatar

            VStack(alignment: .leading, spacing: 2) {
                Text(character.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.caiText)
                    .lineLimit(1)

                Text(character.tagline.isEmpty ? "Local character · \(character.sourcePlatform)" : character.tagline)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.caiMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 16)

            if isLoadingModels {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
                    .accessibilityLabel("Loading local models")
                    .transition(.opacity)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .frame(height: 44)
        .frame(maxWidth: 440)
        .glassSurface(.characterHeader, cornerRadius: 22)
        .animation(reduceMotion ? nil : GlassMetrics.interaction, value: isLoadingModels)
    }

    @ViewBuilder
    private var headerAvatar: some View {
        if let avatarFileName = character.avatarFileName,
           let avatarURL = CharacterImageURL.makeURL(avatarFileName: avatarFileName) {
            CachedAvatarView(url: avatarURL) {
                fallbackHeaderAvatar
            }
            .frame(width: 30, height: 30)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        } else {
            fallbackHeaderAvatar
        }
    }

    private var fallbackHeaderAvatar: some View {
        ZStack {
            Circle()
                .fill(ShellEnvironmentalBackground.environmentalSurfaceTint(isDark: isDark))
            Text(character.name.prefix(1))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.caiText)
        }
        .frame(width: 30, height: 30)
    }

    private func messageRow(_ item: LocalChatMessage) -> some View {
        let isUser = item.role == "user"
        return HStack(alignment: .top, spacing: 10) {
            if isUser {
                Spacer(minLength: 40)
            } else {
                messageAvatar
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                if !isUser {
                    Text(character.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.caiText)
                        .padding(.leading, 4)
                }
                CharacterMessageFormattingView(content: item.content, expandsToFill: false)
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .glassSurface(isUser ? .userMessage : .characterMessage,
                                  cornerRadius: GlassMetrics.messageRadius)
                    .foregroundStyle(Color.caiText)
                    .clipShape(RoundedRectangle(cornerRadius: GlassMetrics.messageRadius, style: .continuous))
                    .contextMenu {
                        Button("Copy Message", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(item.content, forType: .string)
                        }
                    }
            }
            .frame(maxWidth: isUser ? 480 : 520, alignment: isUser ? .trailing : .leading)

            if !isUser {
                Spacer(minLength: 40)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
        .transition(.opacity)
    }

    private var messageAvatar: some View {
        Group {
            if let avatarFileName = character.avatarFileName,
               let avatarURL = CharacterImageURL.makeURL(avatarFileName: avatarFileName) {
                CachedAvatarView(url: avatarURL) {
                    fallbackMessageAvatar
                }
            } else {
                fallbackMessageAvatar
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }

    private var fallbackMessageAvatar: some View {
        ZStack {
            Circle()
                .fill(environmentalPaletteStore.palette.atmosphericBase.opacity(isDark ? 0.85 : 0.55))
            Text(character.name.prefix(1))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.caiText)
        }
    }

    private var composer: some View {
        HStack(alignment: .center, spacing: 8) {
            Menu {
                ForEach(models, id: \.self) { model in
                    Button {
                        selectedModel = model
                    } label: {
                        if selectedModel == model {
                            Label(model, systemImage: "checkmark")
                        } else {
                            Text(model)
                        }
                    }
                }
                if models.isEmpty {
                    Button("Retry Ollama", systemImage: "arrow.clockwise") {
                        Task { await loadModels() }
                    }
                }
            } label: {
                Image(systemName: "cpu")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.caiMuted)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(ShellEnvironmentalBackground.environmentalSurfaceTint(isDark: isDark)))
            }
            .menuStyle(.borderlessButton)
            .help(models.isEmpty ? "Retry local Ollama" : "Model: \(selectedModel)")
            .accessibilityLabel(models.isEmpty ? "Retry Ollama" : "Select local model, currently \(selectedModel)")

            if isGenerating {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Generating response")
                    Text("\(character.name) is typing…")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.caiMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("Message \(character.name)...", text: $message, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.system(size: 14))
                    .textFieldStyle(.plain)
                    .foregroundStyle(Color.caiText)
                    .focused($composerFocused)
                    .disabled(isGenerating)
                    .onSubmit { Task { await send() } }
                    .onKeyPress(keys: [.return], phases: .down) { press in
                        guard !press.modifiers.contains(.shift) else { return .ignored }
                        if !isSendDisabled { Task { await send() } }
                        return .handled
                    }
            }

            Button { Task { await send() } } label: {
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
        .glassSurface(.characterHeader,
                      cornerRadius: GlassMetrics.composerRadius,
                      isFocused: composerFocused)
        .frame(maxWidth: min(GlassMetrics.contentWidth, 680))
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 16)
    }

    private var isSendDisabled: Bool {
        isGenerating || selectedModel.isEmpty ||
            message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func loadModels() async {
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            models = try await ollama.models()
            if models.isEmpty { errorMessage = LocalOllamaError.noModels.localizedDescription }
            if !models.contains(selectedModel) { selectedModel = models.first ?? "" }
            if !models.isEmpty { errorMessage = nil }
        } catch { errorMessage = error.localizedDescription }
    }

    private func send() async {
        let content = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, !selectedModel.isEmpty, !isGenerating else { return }
        message = ""
        errorMessage = nil
        do {
            let userMessage = LocalChatMessage(role: "user", content: content)
            try library.append(userMessage, characterID: character.id)
            guard let current = library.conversations[character.id] else { return }
            conversation = current
            isGenerating = true
            defer { isGenerating = false }
            let answer = try await ollama.reply(model: selectedModel, character: character, messages: current.messages)
            try library.append(LocalChatMessage(role: "assistant", content: answer), characterID: character.id)
            conversation = library.conversations[character.id]
        } catch { errorMessage = error.localizedDescription }
    }
}
