import SwiftUI

/// Compact Liquid Glass popover for conversation memory, recent chats,
/// copied-chat model selection, and server-backed persona overrides.
struct ComposerPersonaMenu: View {
    @ObservedObject var personaStore = PersonaStore.shared
    let currentCharacterID: String?
    let authenticatedHTTPClient: AuthenticatedHTTPClient?
    let availableModels: [ModelSelectionOption]
    let selectedModelType: String?
    let canStartModelConversation: Bool
    let recentChats: [ChatPreview]
    let isLoadingHistory: Bool
    let historyErrorMessage: String?
    let isCreatingConversation: Bool
    let isPersonaSelectionInProgress: Bool
    let isLoadingPersonas: Bool
    let currentPersonaID: String?
    let onSelectModel: (String) -> Void
    let onSelectPersona: (Persona) async -> Bool
    let onOpenMemory: () -> Void
    let onOpenHistory: (ChatPreview) -> Void
    let onRefreshHistory: () -> Void
    let dismiss: () -> Void

    @State private var showingPersonaPicker = false
    @State private var showingStylePicker = false
    @State private var showingHistoryPicker = false
    @State private var hasStartedHistoryLoad = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                personaIcon(currentPersona, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(currentPersona.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.caiText)
                    Text(currentPersonaID == nil || currentPersonaID == "default_user"
                         ? "No Character.AI persona selected" : "Current persona")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.caiMuted)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider().padding(.vertical, 2)

            if showingPersonaPicker {
                personaPicker
            } else if showingStylePicker {
                stylePicker
            } else if showingHistoryPicker {
                historyPicker
            } else {
                GlassActionRow(title: "Memory", systemImage: "brain") {
                    dismiss()
                    onOpenMemory()
                }
                GlassActionRow(title: "History", systemImage: "clock.arrow.circlepath") {
                    showingHistoryPicker = true
                    if recentChats.isEmpty && historyErrorMessage == nil && !isLoadingHistory {
                        hasStartedHistoryLoad = true
                        onRefreshHistory()
                    }
                }
                GlassActionRow(title: "Chat Style", systemImage: "sparkles") {
                    showingStylePicker = true
                }
                GlassActionRow(title: "Persona", systemImage: "person.crop.circle") {
                    showingPersonaPicker = true
                }
            }
        }
        .padding(8)
        .frame(width: 250)
        .background { ShellEnvironmentalBackground() }
        .presentationBackground(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation controls")
        .onChange(of: personaStore.personaSelectionErrorMessage) {
            if personaStore.personaSelectionErrorMessage != nil {
                showingPersonaPicker = true
            }
        }
    }

    private var currentPersona: Persona {
        personaStore.resolvePersona(forCharacterID: currentCharacterID)
    }

    private var personaPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            submenuHeader("Personas") { showingPersonaPicker = false }
            if let error = personaStore.personaListErrorMessage {
                Text("Character.AI personas couldn't be loaded: \(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
            }
            if let error = personaStore.personaSettingsErrorMessage {
                Text("Persona settings couldn't be loaded: \(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
            }
            if let error = personaStore.personaSelectionErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
            }

            if personaStore.personas.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(isLoadingPersonas
                         ? "Loading Character.AI personas…"
                         : "No Character.AI personas are available.")
                        .font(.caption)
                        .foregroundStyle(Color.caiMuted)
                    if isLoadingPersonas {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(8)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(personaStore.personas) { persona in
                            Button {
                                Task {
                                    if await onSelectPersona(persona) {
                                        showingPersonaPicker = false
                                    }
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    personaIcon(persona, size: 20)
                                    Text(persona.displayName)
                                        .font(.callout)
                                        .foregroundStyle(Color.caiText)
                                        .lineLimit(1)
                                    Spacer()
                                    if persona.externalID == currentPersonaID {
                                        Image(systemName: "checkmark")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(Color.caiPrimary)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(QuietHoverButtonStyle())
                            .disabled(isPersonaSelectionInProgress)
                            .accessibilityLabel("Select persona \(persona.displayName)")
                            .accessibilityAddTraits(persona.externalID == currentPersonaID ? .isSelected : [])
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
    }

    private var stylePicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            submenuHeader("Chat Style / Model") { showingStylePicker = false }
            Text("Choose a style to create a copied chat from the latest message.")
                .font(.caption)
                .foregroundStyle(Color.caiMuted)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

            if availableModels.isEmpty {
                Text("Available styles couldn't be loaded.")
                    .font(.caption)
                    .foregroundStyle(Color.caiMuted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            } else if !canStartModelConversation {
                Text("To create a copied chat in another style, wait for messages to load and finish active updates.")
                    .font(.caption)
                    .foregroundStyle(Color.caiMuted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(availableModels) { model in
                            Button {
                                onSelectModel(model.modelType)
                                showingStylePicker = false
                                dismiss()
                            } label: {
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(model.displayName)
                                            .font(.callout)
                                            .foregroundStyle(Color.caiText)
                                        HStack(spacing: 4) {
                                            if model.isPlusOnly {
                                                Text("Plus")
                                                    .font(.system(size: 9, weight: .bold))
                                                    .foregroundStyle(Color.orange)
                                            }
                                            if model.isBeta {
                                                Text("Beta")
                                                    .font(.system(size: 9))
                                                    .foregroundStyle(Color.caiMuted)
                                            }
                                            if model.hasModelSteering {
                                                Text("Steering")
                                                    .font(.system(size: 9))
                                                    .foregroundStyle(Color.caiPrimary)
                                            }
                                        }
                                    }
                                    Spacer()
                                    if selectedModelType == model.modelType {
                                        Image(systemName: "checkmark")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(Color.caiPrimary)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(QuietHoverButtonStyle())
                            .disabled(isCreatingConversation)
                            .accessibilityLabel("Create copied chat using \(model.displayName)")
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
    }

    private var historyPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            submenuHeader("Recent History") { showingHistoryPicker = false }
            if isLoadingHistory && recentChats.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading recent chats…")
                        .font(.caption)
                        .foregroundStyle(Color.caiMuted)
                }
                .padding(8)
            } else if let historyErrorMessage, recentChats.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent chats couldn't be loaded: \(historyErrorMessage)")
                        .font(.caption)
                        .foregroundStyle(Color.caiMuted)
                    Button("Retry") {
                        onRefreshHistory()
                    }
                    .disabled(isLoadingHistory)
                }
                .padding(8)
            } else if recentChats.isEmpty && !isLoadingHistory && !hasStartedHistoryLoad {
                ProgressView("Loading recent chats…")
                    .controlSize(.small)
                    .padding(8)
            } else if recentChats.isEmpty {
                Text("No other chats found for this character.")
                    .font(.caption)
                    .foregroundStyle(Color.caiMuted)
                    .padding(8)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(recentChats, id: \.chatID) { recent in
                            Button {
                                dismiss()
                                onOpenHistory(recent)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(historyTitle(for: recent))
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(Color.caiText)
                                    Text(historyDate(for: recent.createTime))
                                        .font(.system(size: 9))
                                        .foregroundStyle(Color.caiMuted)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                            }
                            .buttonStyle(QuietHoverButtonStyle())
                            .accessibilityLabel(historyAccessibilityLabel(for: recent))
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
        }
    }

    private func submenuHeader(_ title: String, back: @escaping () -> Void) -> some View {
        HStack {
            Button(action: back) {
                Label("Back", systemImage: "chevron.left")
                    .font(.caption)
            }
            .buttonStyle(QuietHoverButtonStyle())
            Spacer()
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.caiMuted)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    private func historyDate(for value: String) -> String {
        let date = PresentationDate.parse(value)
        guard let date else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func historyTitle(for recent: ChatPreview) -> String {
        guard let message = recent.openingMessage else {
            return "Conversation"
        }
        let cleaned = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "Conversation" }
        let words = cleaned.split(whereSeparator: \.isWhitespace)
        let title = words.prefix(8).joined(separator: " ")
        let firstSentence: String
        if let end = title.firstIndex(where: { ".!?。！？".contains($0) }) {
            firstSentence = String(title[...end])
        } else {
            firstSentence = title
        }
        return words.count > 8 && firstSentence == title ? title + "…" : firstSentence
    }

    private func historyAccessibilityLabel(for recent: ChatPreview) -> String {
        "Open \(historyTitle(for: recent)), \(historyDate(for: recent.createTime))"
    }

    private func personaIcon(_ persona: Persona, size: CGFloat) -> some View {
        Group {
            if let url = persona.avatarURL {
                CachedAvatarView(url: url) {
                    fallbackPersonaIcon(persona, size: size)
                }
            } else {
                fallbackPersonaIcon(persona, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
    }

    private func fallbackPersonaIcon(_ persona: Persona, size: CGFloat) -> some View {
        ZStack {
            Circle().fill(Color.caiPrimary.opacity(0.35))
            Text(persona.displayName.prefix(1).uppercased())
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(Color.caiText)
        }
        .frame(width: size, height: size)
    }
}

/// Read-only conversation facts returned by Character.AI's conversation-memory endpoint.
struct MemoryFactsSheet: View {
    let facts: [String: [ConversationFact]]
    let isLoading: Bool
    let errorMessage: String?
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Conversation Memory", systemImage: "brain")
                    .font(.headline)
                    .foregroundStyle(Color.caiText)
                Spacer()
                Button("Done", action: dismiss)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.bottom, 4)

            if isLoading && facts.isEmpty {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.regular)
                    Text("Loading conversation memory…")
                        .font(.callout)
                        .foregroundStyle(Color.caiMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, facts.isEmpty {
                ContentUnavailableView {
                    Label("Memory Unavailable", systemImage: "brain")
                } description: {
                    Text(errorMessage)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if facts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundStyle(Color.caiMuted)
                    Text("No conversation facts recorded for this chat yet.")
                        .font(.callout)
                        .foregroundStyle(Color.caiMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(facts.keys.sorted()), id: \.self) { entity in
                        Section(header: Text(entity).font(.subheadline.weight(.semibold))) {
                            if let entityFacts = facts[entity] {
                                ForEach(entityFacts) { fact in
                                    HStack(alignment: .top) {
                                        Text(fact.category)
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(Color.caiMuted)
                                            .frame(width: 120, alignment: .leading)
                                        Text(fact.value)
                                            .font(.callout)
                                            .foregroundStyle(Color.caiText)
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }

            Text("Memory facts are read from Character.AI's server-side extraction. Editing and deletion are not confirmed.")
                .font(.caption2)
                .foregroundStyle(Color.caiMuted)
        }
        .padding(18)
        .frame(width: 520, height: 460)
        .background { ShellEnvironmentalBackground(vignetteStrength: 0.35) }
        .presentationBackground(.regularMaterial)
        .accessibilityLabel("Conversation memory facts")
    }
}
