import SwiftUI

/// Persona avatar button embedded in the message composer.
/// Displays active persona avatar, subtle hover effect, and presents `ComposerPersonaMenu`.
struct ComposerPersonaAvatarButton: View {
    @ObservedObject var personaStore = PersonaStore.shared
    let currentCharacterID: String?
    let authenticatedHTTPClient: AuthenticatedHTTPClient?
    let availableModels: [ModelSelectionOption]
    let selectedModelType: String?
    let recentChats: [RecentChat]
    let onSelectModel: (String) -> Void
    let isLoadingFacts: Bool
    let factsErrorMessage: String?
    let onOpenMemory: () -> Void
    let onOpenHistory: (RecentChat) -> Void

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
                    .strokeBorder(
                        Color.primary.opacity(isHovering ? 0.35 : 0.15),
                        lineWidth: 1
                    )
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
                currentCharacterID: currentCharacterID,
                authenticatedHTTPClient: authenticatedHTTPClient,
                availableModels: availableModels,
                selectedModelType: selectedModelType,
                currentModelType: selectedModelType,
                recentChats: recentChats,
                onSelectModel: onSelectModel,
                isLoadingFacts: isLoadingFacts,
                factsErrorMessage: factsErrorMessage,
                onOpenMemory: onOpenMemory,
                onOpenHistory: onOpenHistory,
                dismiss: { isShowingMenu = false }
            )
        }
    }

    private var fallbackAvatar: some View {
        ZStack {
            Circle()
                .fill(Color.caiPrimary.opacity(0.35))
            Text(activePersonaForCharacter.displayName.prefix(1).uppercased())
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.caiText)
        }
        .frame(width: 30, height: 30)
    }
}
