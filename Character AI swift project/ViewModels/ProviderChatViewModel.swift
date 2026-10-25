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
    /// Surfaced beside the transcript so a failed write is never silent.
    @Published private(set) var storageErrorMessage: String?
    let provider: any ChatProvider
    let model: String
    /// The open conversation's identity. Views use it to reset per-chat state
    /// (draft, dialogs, scroll) when the sidebar switches conversations.
    var identity: String { transcriptKey.identity }
    /// Nil keeps the chat in memory only, which is what checks and previews
    /// want; the app passes the shared store so a chat resumes on relaunch.
    private let transcripts: ProviderTranscriptStore?
    private var transcriptKey: ProviderTranscriptKey
    private var generation: Task<Void, Never>?
    private var generationID = UUID()
    private var pendingText = ""
    private var publication: Task<Void, Never>?
    private var retryMessage: String?
    private var transcriptIsAvailable = true

    init(provider: any ChatProvider, model: String, persona: Persona? = nil,
         character: LocalCharacter? = nil,
         transcripts: ProviderTranscriptStore? = nil) {
        self.provider = provider
        self.model = model
        self.transientPersona = persona
        self.character = character
        self.transcripts = transcripts
        self.transcriptKey = ProviderTranscriptKey(
            providerID: provider.descriptor.id,
            kind: provider.descriptor.kind,
            model: model,
            characterID: character?.id
        )
        restoreTranscript()
    }

    /// Each character has its own saved conversation for this provider and
    /// model, so switching characters resumes that character's chat.
    func setCharacter(_ character: LocalCharacter?) {
        cancel()
        self.character = character
        roleplayPersona?.setCharacter(character?.id)
        transcriptKey = ProviderTranscriptKey(
            providerID: provider.descriptor.id,
            kind: provider.descriptor.kind,
            model: model,
            characterID: character?.id
        )
        errorMessage = nil
        wasInterrupted = false
        retryMessage = nil
        storageErrorMessage = nil
        restoreTranscript()
    }

    private func restoreTranscript() {
        do {
            messages = try transcripts?.load(transcriptKey) ?? []
            transcriptIsAvailable = true
            storageErrorMessage = nil
            seedGreeting()
        } catch {
            messages = []
            transcriptIsAvailable = false
            storageErrorMessage = ProviderTranscriptError.unavailable.localizedDescription
        }
    }

    private func seedGreeting() {
        guard let greeting = character?.greeting,
              !greeting.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              messages.isEmpty else { return }
        messages = [ProviderChatMessage(role: .assistant, content: greeting)]
    }

    /// Providers keep no history, so every mutation rewrites the saved
    /// transcript. That is what makes rewind, edit and fork stick after a
    /// relaunch instead of leaving stale turns behind.
    private func persist() {
        guard let transcripts else { return }
        do {
            try transcripts.save(messages, for: transcriptKey,
                                 characterName: character?.name,
                                 avatarFileName: character?.avatarFileName,
                                 providerName: provider.descriptor.name)
            storageErrorMessage = nil
        } catch {
            storageErrorMessage = "This conversation could not be saved on this Mac. Copy anything you want to keep before closing the window."
        }
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
        guard !text.isEmpty, !isGenerating, transcriptIsAvailable else { return }
        retryMessage = text
        messages.append(ProviderChatMessage(role: .user, content: text))
        persist()
        generate()
    }

    func retry() {
        guard !isGenerating, retryMessage != nil else { return }
        if messages.last?.role == .assistant { messages.removeLast() }
        generate()
    }

    /// Providers keep no server-side turn model, so everything after an edited
    /// message answered text that was never sent and is dropped with it.
    @discardableResult
    func editMessage(_ messageID: UUID, newContent: String) -> Bool {
        let trimmed = newContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isGenerating,
              !trimmed.isEmpty,
              let index = messages.firstIndex(where: { $0.id == messageID }) else { return false }
        messages[index].content = trimmed
        removeMessages(after: index)
        retryMessage = lastPrompt()
        errorMessage = nil
        wasInterrupted = false
        persist()
        return true
    }

    /// A reply can be regenerated only when the prompt that produced it is
    /// still in the transcript; a seeded greeting has nothing to re-send.
    func canRegenerate(_ messageID: UUID) -> Bool {
        guard !isGenerating,
              let index = messages.firstIndex(where: { $0.id == messageID }),
              messages[index].role == .assistant else { return false }
        return messages[..<index].contains { $0.role == .user }
    }

    /// Replaces a reply with a fresh sample and drops the turns that followed
    /// it, because they answered the reply being replaced.
    @discardableResult
    func regenerateMessage(_ messageID: UUID) -> Bool {
        guard canRegenerate(messageID),
              let index = messages.firstIndex(where: { $0.id == messageID }) else { return false }
        messages.removeSubrange(index...)
        retryMessage = lastPrompt()
        persist()
        generate()
        return true
    }

    /// Keeps `messageID` and every earlier message, discarding the rest.
    @discardableResult
    func rewind(through messageID: UUID) -> Bool {
        guard !isGenerating,
              let index = messages.firstIndex(where: { $0.id == messageID }) else { return false }
        removeMessages(after: index)
        retryMessage = lastPrompt()
        errorMessage = nil
        wasInterrupted = false
        persist()
        return true
    }

    /// A provider chat lives only in this window, so there is no earlier
    /// conversation to preserve: the prefix becomes the whole conversation and
    /// the retry anchor is cleared, making the next send a new message.
    @discardableResult
    func fork(through messageID: UUID) -> Bool {
        guard rewind(through: messageID) else { return false }
        retryMessage = nil
        return true
    }

    private func removeMessages(after index: Int) {
        guard index + 1 < messages.count else { return }
        messages.removeSubrange((index + 1)...)
    }

    private func lastPrompt() -> String? {
        messages.last { $0.role == .user }?.content
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
        persist()
    }

    func cancel() {
        guard isGenerating else { return }
        generation?.cancel()
        finish(id: generationID, interrupted: true)
        // A provider ignoring cancellation still cannot publish into a new chat.
        generationID = UUID()
    }

    /// Starts an empty conversation in the same slot, so the saved transcript
    /// for this provider, model and character is replaced rather than appended.
    func newConversation() {
        guard transcriptIsAvailable else { return }
        cancel()
        do { try transcripts?.remove(transcriptKey) }
        catch {
            storageErrorMessage = "This conversation could not be removed from this Mac. Its visible messages have been kept."
            return
        }
        messages = []
        seedGreeting()
        errorMessage = nil
        wasInterrupted = false
        retryMessage = nil
        storageErrorMessage = nil
    }

    deinit {
        generation?.cancel()
        publication?.cancel()
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

    func start(provider: any ChatProvider, selection: ProviderSelection, store: ProviderStore,
               character: LocalCharacter? = nil) {
        show(.textChat)
        chat = ProviderChatViewModel(provider: provider, model: selection.model,
                                     character: character, transcripts: .shared)
        store.remember(selection)
    }

    /// Reopens a saved chat from the sidebar. Its provider must still be
    /// configured; a removed configuration is reported rather than guessed at.
    func open(_ summary: ProviderTranscriptSummary, store: ProviderStore,
              library: LocalCharacterLibrary = .shared) {
        if summary.key.kind != .ollama, UUID(uuidString: summary.key.providerID) != nil,
           !store.configurations.contains(where: { $0.id.uuidString == summary.key.providerID }) {
            errorMessage = "That chat's provider has been removed. Add it again to reopen the conversation."
            return
        }
        let character = summary.key.characterID.flatMap { id in
            library.characters.first { $0.id == id }
        }
        guard summary.key.characterID == nil || character != nil else {
            errorMessage = "That chat's character is no longer in your library. Import it again to reopen the saved conversation."
            return
        }
        let selection = ProviderSelection(
            kind: summary.key.kind,
            configurationID: UUID(uuidString: summary.key.providerID),
            model: summary.key.model
        )
        do {
            let provider = try store.provider(for: selection)
            start(provider: provider, selection: selection, store: store, character: character)
        } catch {
            errorMessage = (error as? ProviderError ?? .unavailable).localizedDescription
        }
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
