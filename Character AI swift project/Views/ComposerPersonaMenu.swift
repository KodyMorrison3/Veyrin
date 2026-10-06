import SwiftUI

/// Compact Liquid Glass popover menu presented when clicking the composer's persona avatar.
/// Provides access to Persona switching (with server-side persistence), Memory (live conversation facts),
/// History (recent character chats), and Chat Style / Models (dynamic model selector).
struct ComposerPersonaMenu: View {
    @ObservedObject var personaStore = PersonaStore.shared
    let currentCharacterID: String?
    let authenticatedHTTPClient: AuthenticatedHTTPClient?
    let availableModels: [ModelSelectionOption]
    let selectedModelType: String?
    let currentModelType: String?
    let recentChats: [RecentChat]
    let onSelectModel: (String) -> Void
    let isLoadingFacts: Bool
    let factsErrorMessage: String?
    let onOpenMemory: () -> Void
    let onOpenHistory: (RecentChat) -> Void
    let dismiss: () -> Void

    @State private var showingPersonaPicker = false
    @State private var showingStylePicker = false
    @State private var showingHistoryPicker = false

    private var currentPersona: Persona {
        personaStore.resolvePersona(forCharacterID: currentCharacterID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header: Current Persona
            HStack(spacing: 8) {
                personaIcon(currentPersona, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(currentPersona.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.caiText)
                    Text(currentPersona.isDefaultUser ? "No Character.AI persona selected" : "Current persona")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.caiMuted)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()
                .padding(.vertical, 2)

            if showingPersonaPicker {
                // Nested Persona Selector
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Button {
                            showingPersonaPicker = false
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                                .font(.caption)
                        }
                        .buttonStyle(QuietHoverButtonStyle())
                        Spacer()
                        Text("Personas")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.caiMuted)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)

                    if personaStore.personas.isEmpty {
                        Text("No Character.AI personas are available.")
                            .font(.caption)
                            .foregroundStyle(Color.caiMuted)
                            .padding(8)
                    } else {
                        ScrollView {
                            VStack(spacing: 2) {
                                ForEach(personaStore.personas) { persona in
                                    Button {
                                        Task {
                                            await personaStore.selectPersona(
                                                persona,
                                                forCharacterID: currentCharacterID,
                                                authenticatedClient: authenticatedHTTPClient
                                            )
                                            showingPersonaPicker = false
                                        }
                                    } label: {
                                        HStack(spacing: 8) {
                                            personaIcon(persona, size: 20)
                                            Text(persona.displayName)
                                                .font(.callout)
                                                .foregroundStyle(Color.caiText)
                                                .lineLimit(1)
                                            Spacer()
                                            if persona.id == currentPersona.id || persona.externalID == currentPersona.externalID {
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
                                    .accessibilityLabel("Select persona \(persona.displayName)")
                                    .accessibilityAddTraits(persona.externalID == currentPersona.externalID ? .isSelected : [])
                                }
                            }
                        }
                        .frame(maxHeight: 200)
                    }
                }
            } else if showingStylePicker {
                // Nested Chat Style / Model Picker
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Button {
                            showingStylePicker = false
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                                .font(.caption)
                        }
                        .buttonStyle(QuietHoverButtonStyle())
                        Spacer()
                        Text("Chat Style / Model")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.caiMuted)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)

                    Text("Current: \(currentModelType ?? "Character.AI default")")
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
                                    .accessibilityLabel("Select chat style \(model.displayName)")
                                    .accessibilityAddTraits(model.modelType == currentModelType ? .isSelected : [])
                                }
                            }
                        }
                        .frame(maxHeight: 220)
                    }
                }
            } else if showingHistoryPicker {
                // Character History Submenu
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Button {
                            showingHistoryPicker = false
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                                .font(.caption)
                        }
                        .buttonStyle(QuietHoverButtonStyle())
                        Spacer()
                        Text("Recent History")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.caiMuted)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)

                    if recentChats.isEmpty {
                        Text("No other chats found for this character.")
                            .font(.caption)
                            .foregroundStyle(Color.caiMuted)
                            .padding(8)
                    } else {
                        ScrollView {
                            VStack(spacing: 2) {
                                ForEach(recentChats, id: \.chatID) { recent in
                                    Button {
                                        let selectedChat = recent
                                        dismiss()
                                        onOpenHistory(selectedChat)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(recent.characterName)
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(Color.caiText)
                                            Text(recent.createTime.prefix(10))
                                                .font(.system(size: 9))
                                                .foregroundStyle(Color.caiMuted)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                    }
                                    .buttonStyle(QuietHoverButtonStyle())
                                }
                            }
                        }
                        .frame(maxHeight: 180)
                    }
                }
            } else {
                GlassActionRow(
                    title: "Memory",
                    systemImage: "brain"
                ) {
                    dismiss()
                    onOpenMemory()
                }

                GlassActionRow(
                    title: "History",
                    systemImage: "clock.arrow.circlepath"
                ) {
                    showingHistoryPicker = true
                }

                GlassActionRow(
                    title: "Chat Style",
                    systemImage: "sparkles"
                ) {
                    showingStylePicker = true
                }

                GlassActionRow(
                    title: "Persona",
                    systemImage: "person.crop.circle"
                ) {
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
            Circle()
                .fill(Color.caiPrimary.opacity(0.35))
            Text(persona.displayName.prefix(1).uppercased())
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(Color.caiText)
        }
        .frame(width: size, height: size)
    }
}

/// Clean native macOS sheet displaying confirmed read-only conversation facts from
/// `GET https://neo.character.ai/chat/{chatID}/conversation-facts/`.
/// Fact editing/mutation is isolated as unconfirmed on the backend.
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
                    ProgressView()
                        .controlSize(.regular)
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

            Text("Memory facts are read directly from Character.AI's server-side memory extraction. Editing and deletion are not captured in current network traffic.")
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
