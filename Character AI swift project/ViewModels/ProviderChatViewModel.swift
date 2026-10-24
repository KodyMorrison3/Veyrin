import Combine
import Foundation

@MainActor
final class ProviderChatViewModel: ObservableObject {
    @Published private(set) var messages: [ProviderChatMessage] = []
    @Published private(set) var streamingText = ""
    @Published private(set) var isGenerating = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var wasInterrupted = false
    /// Persona attached to subsequent requests. Changing it does not rewrite
    /// the visible transcript.
    @Published private var transientPersona: Persona?
    private var roleplayPersona: RoleplayPersonaContext?
    var persona: Persona? {
        if let roleplayPersona { return roleplayPersona.persona }
        return transientPersona
    }
    @Published private(set) var character: LocalCharacter?
    let provider: any ChatProvider
    let model: String
    private var generation: Task<Void, Never>?
    private var generationID = UUID()
    private var pendingText = ""
    private var publication: Task<Void, Never>?
    private var retryMessage: String?

    init(provider: any ChatProvider, model: String, persona: Persona? = nil, character: LocalCharacter? = nil) {
        self.provider = provider
        self.model = model
        self.transientPersona = persona
        self.character = character
        seedGreeting()
    }

    /// A different character always starts a separate conversation. The view
    /// confirms discarding an existing transcript before calling this method.
    func setCharacter(_ character: LocalCharacter?) {
        self.character = character
        roleplayPersona?.setCharacter(character?.id)
        newConversation()
    }

    private func seedGreeting() {
        guard let greeting = character?.greeting,
              !greeting.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        messages = [ProviderChatMessage(role: .assistant, content: greeting)]
    }

    func setPersona(_ persona: Persona?) {
        self.transientPersona = persona
    }

    func usePersonaContext(_ context: RoleplayPersonaContext) {
        roleplayPersona = context
        context.setCharacter(character?.id)
    }

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return }
        retryMessage = text
        messages.append(ProviderChatMessage(role: .user, content: text))
        generate()
    }

    func retry() {
        guard !isGenerating, retryMessage != nil else { return }
        if messages.last?.role == .assistant { messages.removeLast() }
        generate()
    }

    private func generate() {
        generationID = UUID()
        let id = generationID
        errorMessage = nil
        wasInterrupted = false
        streamingText = ""
        pendingText = ""
        isGenerating = true
        let prompts = [character?.characterPrompt, persona?.portableSystemPrompt].compactMap { $0 }
        let history = prompts.isEmpty ? messages
            : [ProviderChatMessage(role: .system, content: prompts.joined(separator: "\n\n"))] + messages
        let provider = provider
        let model = model
        generation = Task { [weak self] in
            do {
                try await provider.stream(model: model, messages: history) { [weak self] event in
                    try Task.checkCancellation()
                    await self?.receive(event, generation: id)
                }
                self?.finish(id: id, interrupted: false)
            } catch is CancellationError {
                self?.finish(id: id, interrupted: true)
            } catch {
                guard let self, self.generationID == id else { return }
                self.errorMessage = (error as? ProviderError ?? .unavailable).localizedDescription
                self.finish(id: id, interrupted: true)
            }
        }
    }

    private func receive(_ event: ChatStreamEvent, generation id: UUID) {
        guard generationID == id, isGenerating else { return }
        if case .text(let text) = event {
            pendingText += text
            guard publication == nil else { return }
            publication = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(40)) }
                catch { return }
                guard let self, self.generationID == id else { return }
                self.flush()
            }
        }
    }

    private func flush() {
        publication?.cancel()
        publication = nil
        if !pendingText.isEmpty { streamingText += pendingText; pendingText = "" }
    }

    private func finish(id: UUID, interrupted: Bool) {
        guard generationID == id else { return }
        flush()
        if !streamingText.isEmpty {
            messages.append(ProviderChatMessage(role: .assistant, content: streamingText))
        }
        streamingText = ""
        isGenerating = false
        wasInterrupted = interrupted
        if !interrupted { retryMessage = nil }
        generation = nil
    }

    func cancel() {
        guard isGenerating else { return }
        generation?.cancel()
        finish(id: generationID, interrupted: true)
        // A provider ignoring cancellation still cannot publish into a new chat.
        generationID = UUID()
    }

    func newConversation() {
        cancel()
        messages = []
        seedGreeting()
        errorMessage = nil
        wasInterrupted = false
        retryMessage = nil
    }
}

@MainActor
final class ProviderCoordinator: ObservableObject {
    enum Screen: Equatable {
        case selector, characterAI, local, cloud, textChat
    }
    @Published private(set) var screen: Screen = .selector
    @Published private(set) var chat: ProviderChatViewModel?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRestoring = false
    private var hasLaunched = false
    private var restoreTask: Task<Void, Never>?
    private var revision = UUID()

    func show(_ screen: Screen) {
        revision = UUID()
        restoreTask?.cancel()
        restoreTask = nil
        chat?.cancel()
        chat = nil
        isRestoring = false
        errorMessage = nil
        self.screen = screen
    }

    func start(provider: any ChatProvider, selection: ProviderSelection, store: ProviderStore) {
        show(.textChat)
        chat = ProviderChatViewModel(provider: provider, model: selection.model)
        store.remember(selection)
    }

    func enteredCharacterAI(store: ProviderStore) {
        guard screen == .characterAI else { return }
        store.remember(ProviderSelection(kind: .characterAI))
    }

    func authenticationChanged(authenticated: Bool, store: ProviderStore) {
        guard screen == .characterAI else { return }
        if authenticated { enteredCharacterAI(store: store) }
        else { show(.selector) }
    }

    func launch(store: ProviderStore,
                makeProvider: ((ProviderSelection) throws -> any ChatProvider)? = nil) {
        guard !hasLaunched else { return }
        hasLaunched = true
        guard let selection = store.lastSelection else { return }
        if selection.kind == .characterAI { show(.characterAI); return }
        isRestoring = true
        let current = revision
        restoreTask = Task { [weak self] in
            do {
                let provider = try makeProvider?(selection) ?? store.provider(for: selection)
                let models = try await provider.models()
                try Task.checkCancellation()
                guard let self, self.revision == current else { return }
                guard models.contains(where: { $0.id == selection.model }) else { throw ProviderError.missingModel }
                self.start(provider: provider, selection: selection, store: store)
            } catch is CancellationError { }
            catch {
                guard let self, self.revision == current else { return }
                self.isRestoring = false
                self.errorMessage = (error as? ProviderError ?? .unavailable).localizedDescription
                self.screen = .selector
            }
        }
    }
}
