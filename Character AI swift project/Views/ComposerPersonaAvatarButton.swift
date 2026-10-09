import SwiftUI

/// Persona avatar button embedded in the message composer.
struct ComposerPersonaAvatarButton: View {
    @ObservedObject var personaStore: PersonaStore
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
    let onSelectModel: (String) -> Void
    let onSelectPersona: (Persona) async -> Bool
    let onOpenMemory: () -> Void
    let onOpenHistory: (ChatPreview) -> Void
    let onRefreshHistory: () -> Void

    @State private var isShowingMenu = false
    @State private var isHovering = false

    private var activePersonaForCharacter: Persona {
        personaStore.resolvePersona(forCharacterID: currentCharacterID)
    }

    var body: some View {
        Button {
            isShowingMenu = true
        } label: {
            Group {
                if let url = activePersonaForCharacter.avatarURL {
                    CachedAvatarView(url: url) {
                        fallbackAvatar
                    }
                } else {
                    fallbackAvatar
                }
            }
            .frame(width: 30, height: 30)
            .clipShape(Circle())
            .overlay(
                Circle()
                    .strokeBorder(Color.primary.opacity(isHovering ? 0.35 : 0.15), lineWidth: 1)
            )
            .scaleEffect(isHovering ? 1.05 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isHovering)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Current persona, \(activePersonaForCharacter.displayName)")
        .accessibilityHint("Opens memory, history, chat style, and persona options")
        .help("Persona menu: switch persona, memory, history, chat style")
        .onHover { isHovering = $0 }
        .popover(isPresented: $isShowingMenu, arrowEdge: .top) {
            ComposerPersonaMenu(
                personaStore: personaStore,
                currentCharacterID: currentCharacterID,
                authenticatedHTTPClient: authenticatedHTTPClient,
                availableModels: availableModels,
                selectedModelType: selectedModelType,
                canStartModelConversation: canStartModelConversation,
                recentChats: recentChats,
                isLoadingHistory: isLoadingHistory,
                historyErrorMessage: historyErrorMessage,
                isCreatingConversation: isCreatingConversation,
                isPersonaSelectionInProgress: isPersonaSelectionInProgress,
                isLoadingPersonas: isLoadingPersonas,
                currentPersonaID: activePersonaForCharacter.externalID,
                onSelectModel: onSelectModel,
                onSelectPersona: onSelectPersona,
                onOpenMemory: onOpenMemory,
                onOpenHistory: onOpenHistory,
                onRefreshHistory: onRefreshHistory,
                dismiss: { isShowingMenu = false }
            )
        }
    }

    private var fallbackAvatar: some View {
        ZStack {
            Circle().fill(Color.caiPrimary.opacity(0.35))
            Text(activePersonaForCharacter.displayName.prefix(1).uppercased())
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.caiText)
        }
        .frame(width: 30, height: 30)
    }
}
