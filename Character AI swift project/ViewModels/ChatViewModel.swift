//
//  ChatViewModel.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 26/09/2026.
//

import Foundation
import Combine
import OSLog

private let chatLogger = Logger(subsystem: "CharacterAI", category: "Chat")

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var character: Character?
    @Published var chat: Chat?
    @Published private(set) var turnStates: [TurnState] = []

    /// Snapshot for existing conversation-level operations. Streaming updates
    /// publish only through the affected TurnState, not this collection.
    var turns: [Turn] { turnStates.map(\.turn) }
    private var turnsByKey: [TurnKey: TurnState] = [:]
    var hasTurns: Bool { !turnStates.isEmpty }
    var lastTurn: Turn? { turnStates.last?.turn }
    private func turnState(turnID: String, chatID: String) -> TurnState? {
        turnsByKey[TurnKey(turnId: turnID, chatId: chatID)]
    }
    private func replaceTurns(_ states: [TurnState]) {
        let keys = Set(states.map { TurnKey(turnId: $0.id, chatId: $0.turn.chatID) })
        for key in turnsByKey.keys where !keys.contains(key) {
            turnsByKey.removeValue(forKey: key)
        }
        for state in states {
            let key = TurnKey(turnId: state.id, chatId: state.turn.chatID)
            if turnsByKey[key] !== state { turnsByKey[key] = state }
        }
        guard states.count != turnStates.count || zip(states, turnStates).contains(where: { $0 !== $1 }) else { return }
        turnStates = states
    }
    var lastTurnID: String? { turnStates.last?.id }
    @Published var recentChats: [ConversationSummary] = []
    @Published private(set) var recentPreviewGeneration = UUID()
    private var recentChatsLoadID: UUID?
    private var recentChatsSession: UUID?
    @Published var isLoading = false
    @Published var isGenerating = false
    @Published var errorMessage: String?
    @Published private(set) var historyNotice: String?
    @Published private(set) var isHistoryReadOnly = false
    private var historySummary: ConversationSummary?
    private let historyStore: CharacterAIHistoryStore
    @Published private(set) var pinningTurnIDs: Set<String> = []
    @Published var pinErrorMessage: String?
    @Published var rewindErrorMessage: String?
    @Published private(set) var rewindingFromTurnID: String?
    @Published private(set) var availableModels: [ModelSelectionOption] = []
    /// Tier of the signed-in account; nil when the server did not report it.
    @Published private(set) var subscriptionTier: SubscriptionTier?
    @Published private(set) var isLoadingAvailableModels = false
    @Published private(set) var availableModelsErrorMessage: String?
    @Published private(set) var isCreatingConversationFromTurn = false
    @Published var startConversationErrorMessage: String?

    // Verified endpoints state:
    @Published private(set) var isCharacterVoted: Bool = false
    @Published private(set) var conversationFacts: [String: [ConversationFact]] = [:]
    @Published private(set) var conversationFactsErrorMessage: String?
    @Published private(set) var recentCharacterChats: [ChatPreview] = []
    @Published private(set) var isLoadingFacts = false
    @Published private(set) var isLoadingCharacterHistory = false
    @Published private(set) var characterHistoryErrorMessage: String?
    @Published private(set) var characterHistoryCharacterID: String?

    private var pendingTurnUpdates: [String: Turn] = [:]
    private var turnUpdateTasks: [String: Task<Void, Never>] = [:]
    private var characterHistoryLoadID: UUID?
    private var factsLoadID: UUID?
    private var votedStatusLoadID: UUID?
    private var activeChatID: String?
    private var historyLoadID: UUID?
    private var characterLoadID: UUID?
    private var chatLoadID: UUID?
    /// Chats whose latest generation was censored. Until a non-empty server
    /// history confirms the filtered turn, an empty complete history must not
    /// erase turns already on screen. Chats without a filtered turn are unaffected.
    private var chatsAwaitingFilteredHistory: Set<String> = []

    private func mergeTurns(_ turns: [Turn], removeMissing: Bool, isServerConfirmed: Bool) {
        var seen: Set<TurnKey> = []
        let states = turns.compactMap { turn -> TurnState? in
            let key = TurnKey(turnId: turn.turnID, chatId: turn.chatID)
            guard seen.insert(key).inserted else { return nil }
            if let state = turnsByKey[key] {
                state.update(turn)
                return state
            }
            return TurnState(turn)
        }
        if removeMissing {
            if states.isEmpty, !turnStates.isEmpty, let chatID = activeChatID,
               chatsAwaitingFilteredHistory.contains(chatID) {
                return
            }
            if isServerConfirmed, !states.isEmpty, let chatID = activeChatID {
                chatsAwaitingFilteredHistory.remove(chatID)
            }
            replaceTurns(states)
        }
        else {
            replaceTurns(states + turnStates.filter {
                !seen.contains(TurnKey(turnId: $0.id, chatId: $0.turn.chatID))
            })
        }
    }

    /// The prefix is already in server order. Unconfirmed warm turns stay after
    /// it until the last page, so a failed refresh cannot erase usable content.
    private func mergeHistoryPage(_ page: [Turn], verifiedCount: inout Int) {
        var additions: [TurnState] = []
        for turn in page {
            let key = TurnKey(turnId: turn.turnID, chatId: turn.chatID)
            if let state = turnsByKey[key] {
                state.update(turn)
                additions.append(state)
            } else {
                let state = TurnState(turn)
                turnsByKey[key] = state
                additions.append(state)
            }
        }
        guard !additions.isEmpty else { return }
        if verifiedCount == turnStates.count {
            turnStates.append(contentsOf: additions)
        } else if verifiedCount + additions.count <= turnStates.count,
                  zip(additions, turnStates[verifiedCount..<verifiedCount + additions.count]).allSatisfy({ $0 === $1 }) {
            // A warm refresh whose ordering has not changed only updates rows.
        } else {
            // Only warm refreshes need to move previously visible rows. Cold
            // pagination never filters or reconstructs the accumulated prefix.
            let keys = Set(page.map { TurnKey(turnId: $0.turnID, chatId: $0.chatID) })
            let tail = turnStates.dropFirst(verifiedCount).filter {
                !keys.contains(TurnKey(turnId: $0.id, chatId: $0.turn.chatID))
            }
            turnStates.replaceSubrange(verifiedCount..., with: additions + tail)
        }
        verifiedCount += additions.count
    }

    private func finishHistory(verifiedCount: Int, chatID: String) {
        if verifiedCount == 0, !turnStates.isEmpty, chatsAwaitingFilteredHistory.contains(chatID) { return }
        if verifiedCount > 0 { chatsAwaitingFilteredHistory.remove(chatID) }
        guard verifiedCount < turnStates.count else { return }
        for state in turnStates.dropFirst(verifiedCount) {
            turnsByKey.removeValue(forKey: TurnKey(turnId: state.id, chatId: state.turn.chatID))
        }
        turnStates.removeSubrange(verifiedCount...)
    }

    #if DEBUG
    func checkFilteredHistory(chatID: String) { chatsAwaitingFilteredHistory.insert(chatID) }
    #endif

    private func beginMutation(chatID: String) -> Bool {
        guard !isHistoryReadOnly, !authStore.isOfflineReading, !isLoading else {
            errorMessage = "Refresh this conversation before making changes."
            return false
        }
        if let accountID = authStore.session?.userID {
            do { try historyStore.markNeedsRefresh(accountID: accountID, chatID: chatID) }
            catch {
                // A corrupt cache is not authoritative. Leave it unchanged and
                // let online chat continue; it cannot be shown as a valid copy.
                historyNotice = "The saved reading copy could not be updated and was left unchanged."
            }
        }
        historyLoadID = nil
        isLoading = false
        conversationService.beginMutation(chatID: chatID)
        return true
    }

    let authStore: AuthStore
    private let conversationService: ConversationService
    let authenticatedHTTPClient: AuthenticatedHTTPClient
    var preferences: AppPreferences { .shared }
    private let webSocketRouter: WebSocketRouter

    init(
        authStore: AuthStore,
        conversationService: ConversationService? = nil,
        webSocketRouter: WebSocketRouter? = nil,
        historyStore: CharacterAIHistoryStore? = nil
    ) {
        self.historyStore = historyStore ?? .shared
        self.webSocketRouter = webSocketRouter ?? WebSocketRouter()
        self.authStore = authStore
        let client = AuthenticatedHTTPClient(authStore: authStore)
        self.authenticatedHTTPClient = conversationService?.authenticatedHTTPClient ?? client
        self.conversationService = conversationService ?? ConversationService(
            authenticatedHTTPClient: client
        )
    }

    func createRealChat(
        characterID: String,
        preferredModelFallback: String? = nil
    ) async -> String? {
        guard let authSession = authStore.session else {
            errorMessage = "Not authenticated."
            return nil
        }
        guard !characterID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "This character is missing its Character.AI ID. Please reopen the character and try again."
            return nil
        }
        guard !authSession.userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Your Character.AI account ID is unavailable. Sign out and sign in again, then retry."
            return nil
        }

        isLoading = true
        errorMessage = nil

        let chatID = UUID().uuidString
        let sessionGeneration = authStore.sessionGeneration

        do {
            defer { isLoading = false }
            var createdChat: Chat?
            let command = conversationService.makeCreateChatCommand(
                characterID: characterID,
                creatorID: authSession.userID,
                chatID: chatID
            )
            try await webSocketRouter.connect(sessionToken: authSession.sessionToken)
            let responses = try webSocketRouter.responses(for: command.requestID, timeout: .seconds(10))
            defer { webSocketRouter.finish(command.requestID) }
            let message = String(decoding: try JSONEncoder().encode(command), as: UTF8.self)
            try await webSocketRouter.send(message)
            var acknowledged = false
            for try await response in responses {
                guard authStore.sessionGeneration == sessionGeneration, !Task.isCancelled else { throw CancellationError() }
                if response.command == "neo_error" {
                    throw NetworkError.serverMessage(response.asErrorResponse.comment)
                }
                guard response.command == "create_chat_response" else { continue }
                createdChat = response.chat
                acknowledged = true
                break
            }
            guard acknowledged else { throw NetworkError.invalidResponse }
            isLoading = false

            conversationService.resources.invalidate("recent-chats")
            conversationService.resources.invalidate("previews:\(characterID)")
            chat = Chat(
                chatID: createdChat?.chatID ?? chatID,
                creatorID: createdChat?.creatorID ?? authSession.userID,
                visibility: createdChat?.visibility ?? "VISIBILITY_PRIVATE",
                characterID: createdChat?.characterID ?? characterID,
                type: createdChat?.type ?? "TYPE_ONE_ON_ONE",
                preferredModelType: createdChat?.preferredModelType ?? preferredModelFallback
            )
            return createdChat?.chatID ?? chatID
        } catch {
            chatLogger.error("Chat creation failed: \(error.localizedDescription, privacy: .private)")

            errorMessage = error.localizedDescription
            return nil
        }
    }

    func loadConversationHistory(chatID: String, characterID: String, summary: ConversationSummary? = nil) async {
        historySummary = summary
        let accountID = authStore.session?.userID ?? authStore.offlineAccountID
        if activeChatID != chatID {
            historyLoadID = nil
            webSocketRouter.disconnect()
            replaceTurns([])
            isHistoryReadOnly = false
            historyNotice = nil
        }
        if let accountID {
            do {
                if let snapshot = try historyStore.load(accountID: accountID, chatID: chatID),
                   snapshot.summary.characterID == characterID {
                    activeChatID = chatID
                    mergeTurns(snapshot.turns, removeMissing: true, isServerConfirmed: false)
                    isHistoryReadOnly = true
                    historyNotice = snapshot.needsRefresh
                        ? "Saved reading copy. A previous change needs verification; it may be out of date."
                        : "Saved reading copy from \(snapshot.savedAt.formatted()). Refreshing requires a connection."
                }
            } catch { historyNotice = "A saved reading copy could not be read; the file was left unchanged." }
        }
        guard !authStore.isOfflineReading else {
            isHistoryReadOnly = true
            if turnStates.isEmpty && historyNotice == nil { historyNotice = "No saved reading copy is available for this conversation." }
            return
        }
        if isHistoryReadOnly {
            async let characterLoad: Void = loadCharacter(externalID: characterID)
            await loadRealTurns(chatID: chatID, characterID: characterID)
            await characterLoad
            if historyNotice == "Conversation refreshed, but character details are unavailable. Reopen it when connected.",
               character?.externalID == characterID {
                isHistoryReadOnly = false
                historyNotice = nil
            }
        } else {
            await loadCharacter(externalID: characterID)
            guard !Task.isCancelled, character?.externalID == characterID else { return }
            await loadRealTurns(chatID: chatID)
        }
        if character?.externalID != characterID, isHistoryReadOnly {
            errorMessage = nil
            if historyNotice == nil { historyNotice = "Character details could not be refreshed." }
        }
    }

    func loadCharacter(externalID: String) async {
        let id = UUID()
        let session = authStore.sessionGeneration
        characterLoadID = id
        isLoading = true
        defer { if characterLoadID == id { isLoading = false } }
        do {
            let loaded = try await authStore.resources.value(for: "character:\(externalID)", ttl: 300,
                                                             cost: { DataCacheCost.json($0) }) {
                try await CharacterAPI().getCharacterInfo(externalID: externalID)
            }
            guard characterLoadID == id, authStore.sessionGeneration == session, !Task.isCancelled else { return }
            character = loaded
        } catch is CancellationError { return }
        catch { if characterLoadID == id, authStore.sessionGeneration == session { errorMessage = error.localizedDescription } }
    }

    func loadChat(chatID: String) async {
        let id = UUID()
        let session = authStore.sessionGeneration
        chatLoadID = id
        do {
            let loaded = try await conversationService.loadChat(chatID: chatID)
            guard chatLoadID == id, authStore.sessionGeneration == session, !Task.isCancelled else { return }
            chat = loaded
        } catch is CancellationError { return }
        catch { chatLogger.error("Chat metadata request failed: \(error.localizedDescription, privacy: .private)") }
    }

    /// Loads conversation facts from GET https://neo.character.ai/chat/{chatID}/conversation-facts/
    func loadFacts(chatID: String) async {
        let loadID = UUID()
        let session = authStore.sessionGeneration
        factsLoadID = loadID
        conversationFacts = [:]
        isLoadingFacts = true
        conversationFactsErrorMessage = nil
        defer {
            if factsLoadID == loadID {
                factsLoadID = nil
                isLoadingFacts = false
            }
        }
        do {
            let response = try await conversationService.loadConversationFacts(chatID: chatID)
            guard factsLoadID == loadID, authStore.sessionGeneration == session, !Task.isCancelled else { return }
            conversationFacts = [:]
            var mapped: [String: [ConversationFact]] = [:]
            if let factsDict = response.conversationFacts {
                for (entity, container) in factsDict {
                    mapped[entity] = container.facts
                }
            }
            conversationFacts = mapped
        } catch is CancellationError {
            return
        } catch {
            guard factsLoadID == loadID, authStore.sessionGeneration == session, !Task.isCancelled else { return }
            conversationFactsErrorMessage = error.localizedDescription
            chatLogger.error("Conversation facts request failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Loads character voted state from GET https://neo.character.ai/character/v1/character_voted/{characterID}/voted
    func loadCharacterVotedStatus(characterID: String) async {
        let loadID = UUID()
        let session = authStore.sessionGeneration
        votedStatusLoadID = loadID
        isCharacterVoted = false
        defer { if votedStatusLoadID == loadID { votedStatusLoadID = nil } }
        do {
            let voted = try await conversationService.loadCharacterVoted(characterID: characterID)
            guard votedStatusLoadID == loadID, authStore.sessionGeneration == session, !Task.isCancelled else { return }
            isCharacterVoted = voted
        } catch is CancellationError {
            return
        } catch {
            guard votedStatusLoadID == loadID, authStore.sessionGeneration == session, !Task.isCancelled else { return }
            chatLogger.error("Character vote-status request failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Loads the character's history list using the HAR-observed GET /chats/ query.
    func loadRecentCharacterChats(characterID: String) async {
        if isLoadingCharacterHistory && characterHistoryCharacterID == characterID { return }

        let loadID = UUID()
        characterHistoryLoadID = loadID
        characterHistoryCharacterID = characterID
        isLoadingCharacterHistory = true
        characterHistoryErrorMessage = nil

        defer {
            if characterHistoryLoadID == loadID {
                characterHistoryLoadID = nil
                isLoadingCharacterHistory = false
            }
        }

        let session = authStore.sessionGeneration
        do {
            let chats = try await conversationService.loadCharacterRecentChats(
                characterID: characterID
            )
            guard characterHistoryLoadID == loadID, authStore.sessionGeneration == session, !Task.isCancelled else { return }
            recentCharacterChats = chats
        } catch is CancellationError {
            return
        } catch {
            guard characterHistoryLoadID == loadID, authStore.sessionGeneration == session, !Task.isCancelled else { return }
            characterHistoryErrorMessage = error.localizedDescription
            chatLogger.error("Character history request failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    func loadRealTurns(chatID: String, forceRefresh: Bool = false, characterID: String? = nil) async {
        guard rewindingFromTurnID == nil, !isGenerating,
              let characterID = characterID ?? character?.externalID else { return }
        if activeChatID != chatID {
            webSocketRouter.disconnect()
            replaceTurns([])
            isHistoryReadOnly = false
            historyNotice = nil
        }
        activeChatID = chatID
        let loadID = UUID()
        let session = authStore.sessionGeneration
        historyLoadID = loadID
        let cached = isHistoryReadOnly ? nil : conversationService.cachedHistory(chatID: chatID)
        if let cached, cached.characterID == characterID {
            // An incomplete cached snapshot (for example page one of a history
            // whose pagination was cancelled) must union with the visible turns,
            // never replace them.
            mergeTurns(cached.turns, removeMissing: cached.isComplete, isServerConfirmed: false)
        }
        // Keep warm content visible. A cold ascending history renders each
        // verified page immediately; no undocumented newest-first mode is used.
        isLoading = cached == nil || cached?.isComplete == false
        errorMessage = nil
        defer {
            if historyLoadID == loadID { isLoading = false; historyLoadID = nil }
        }
        turnUpdateTasks.values.forEach { $0.cancel() }
        turnUpdateTasks.removeAll()
        pendingTurnUpdates.removeAll()
        do {
            var verifiedCount = 0
            try await conversationService.loadHistoryPages(
                chatID: chatID, characterID: characterID, forceRefresh: forceRefresh || isHistoryReadOnly
            ) { page, isFirst, isComplete in
                guard self.historyLoadID == loadID, self.activeChatID == chatID,
                      self.authStore.sessionGeneration == session, !Task.isCancelled else { throw CancellationError() }
                if !isComplete { self.isLoading = true }
                if isFirst {
                    self.mergeTurns(page, removeMissing: isComplete, isServerConfirmed: true)
                    verifiedCount = page.count
                } else {
                    self.mergeHistoryPage(page, verifiedCount: &verifiedCount)
                    if isComplete {
                        self.finishHistory(verifiedCount: verifiedCount, chatID: chatID)
                    }
                }
            }
            guard historyLoadID == loadID, authStore.sessionGeneration == session, !Task.isCancelled else { return }
            let serverComplete = conversationService.cachedHistory(chatID: chatID)?.isComplete == true
            if chatsAwaitingFilteredHistory.contains(chatID) {
                isHistoryReadOnly = true
                historyNotice = "Character.AI has not confirmed the filtered response yet. The saved copy was not replaced."
            } else {
                isHistoryReadOnly = character?.externalID != characterID
                historyNotice = isHistoryReadOnly ? "Conversation refreshed, but character details are unavailable. Reopen it when connected." : nil
            }
            if let summary = historySummary, let accountID = authStore.session?.userID,
               serverComplete,
               !chatsAwaitingFilteredHistory.contains(chatID) {
                do { try historyStore.save(accountID: accountID, summary: summary, turns: turns) }
                catch { historyNotice = "Could not save an offline reading copy. The previous file was left unchanged." }
            }
        } catch is CancellationError {
            if historyLoadID == loadID, !Task.isCancelled, isHistoryReadOnly {
                historyNotice = "Refresh was interrupted by another change. Retry before making changes."
            }
            return
        }
        catch {
            guard historyLoadID == loadID, authStore.sessionGeneration == session else { return }
            if isHistoryReadOnly {
                historyNotice = "Showing a saved reading copy. Refresh failed; it may be out of date."
            } else if cached == nil || forceRefresh { errorMessage = error.localizedDescription }
        }
    }

    func sendMessage(
        _ content: String,
        chatID: String
    ) async {
        let trimmedContent =
            content.trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard !trimmedContent.isEmpty else {
            return
        }

        guard rewindingFromTurnID == nil else {
            errorMessage = "Wait for the rewind to finish before continuing."
            return
        }
        guard !isGenerating else {
            return
        }

        guard let character else {
            errorMessage = "Character not loaded."
            return
        }

        guard let authSession = authStore.session else {
            errorMessage = "Not authenticated."
            return
        }

        guard beginMutation(chatID: chatID) else { return }
        let sessionGeneration = authStore.sessionGeneration
        isGenerating = true
        errorMessage = nil

        defer {
            isGenerating = false
        }

        do {
            try await webSocketRouter.connect(sessionToken: authSession.sessionToken)

            let requestID = UUID().uuidString
            let responses = try webSocketRouter.responses(for: requestID)
            defer { webSocketRouter.finish(requestID) }
            let message =
                try conversationService
                    .makeCreateAndGenerateTurnMessage(
                        characterID: character.externalID,
                        userID: authSession.userID,
                        username: authSession.username,
                        chatID: chatID,
                        message: trimmedContent,
                        requestID: requestID
                    )

            try await webSocketRouter.send(
                message
            )

            for try await decoded in responses {
                guard authStore.sessionGeneration == sessionGeneration, !Task.isCancelled else { throw CancellationError() }

                if decoded.command == "neo_error" {
                    let errorResponse = decoded.asErrorResponse
                    chatLogger.error("Character.AI rejected message generation (code \(errorResponse.errorCode, privacy: .public))")

                    if errorResponse.errorCode == 403 {
                        throw NetworkError.serverMessage(
                            "Character.AI denied access to this conversation. It may have been deleted or is no longer available."
                        )
                    }
                    throw NetworkError.serverMessage(errorResponse.comment)
                }

                guard let turn = decoded.turn else { continue }

                guard activeChatID == chatID else {
                    break
                }
                guard turn.turnKey.chatID == chatID else {
                    chatLogger.error("Ignored a WebSocket turn for a different active conversation")

                    continue
                }

                let uiTurn = makeUpdatedUITurn(
                    from: turn,
                    characterID: character.externalID
                )

                let isCharacterTurn =
                    turn.author.authorID ==
                    character.externalID

                // A censored candidate terminates the generation: the HAR-persisted
                // filtered turn pairs `safety_truncated` with `is_final`, and the
                // web client ends generation when it observes the filter marker.
                let isFinal = turn.candidates.contains { $0.isFinal == true || $0.isSafetyTruncated == true }
                if turn.candidates.contains(where: { $0.isSafetyTruncated == true }) {
                    chatsAwaitingFilteredHistory.insert(turn.turnKey.chatID)
                }
                scheduleTurnUpdate(uiTurn, isFinal: isFinal)

                if isCharacterTurn && isFinal {
                    conversationService.completeMutation(chatID: chatID)
                    break
                }
            }

        } catch is CancellationError {
            flushPendingTurnUpdates()
        } catch {
            flushPendingTurnUpdates()
            chatLogger.error("Message generation failed: \(error.localizedDescription, privacy: .private)")
            errorMessage =
                error.localizedDescription
        }
    }
    
    func regenerateResponse(
        turnID: String,
        chatID: String
    ) async {
        guard rewindingFromTurnID == nil else {
            errorMessage = "Wait for the rewind to finish before continuing."
            return
        }
        guard !isGenerating else {
            return
        }

        guard let character else {
            errorMessage = "Character not loaded."
            return
        }

        guard let authSession = authStore.session else {
            errorMessage = "Not authenticated."
            return
        }

        guard let turn = turnState(turnID: turnID, chatID: chatID)?.turn else {
            errorMessage = "Conversation turn not found."
            return
        }

        guard !turn.isHuman else {
            errorMessage = "Only character responses can be regenerated."
            return
        }

        guard beginMutation(chatID: chatID) else { return }
        let sessionGeneration = authStore.sessionGeneration
        isGenerating = true
        errorMessage = nil

        defer {
            isGenerating = false
        }

        do {
            try await webSocketRouter.connect(sessionToken: authSession.sessionToken)

            let requestID = UUID().uuidString
            let responses = try webSocketRouter.responses(for: requestID)
            defer { webSocketRouter.finish(requestID) }
            let message =
                try conversationService.makeGenerateTurnCandidateMessage(
                    characterID: character.externalID,
                    username: authSession.username,
                    chatID: chatID,
                    turnID: turnID,
                    requestID: requestID
                )

            try await webSocketRouter.send(
                message
            )

            for try await decoded in responses {
                guard authStore.sessionGeneration == sessionGeneration, !Task.isCancelled else { throw CancellationError() }
                if decoded.command == "neo_error" {
                    let errorResponse = decoded.asErrorResponse
                    chatLogger.error("Character.AI rejected response operation (code \(errorResponse.errorCode, privacy: .public))")
                    throw NetworkError.serverMessage(errorResponse.comment)
                }

                guard let updatedTurn = decoded.turn else {
                    continue
                }

                guard activeChatID == chatID else {
                    break
                }
                guard updatedTurn.turnKey.chatID == chatID else {
                    continue
                }

                guard updatedTurn.turnKey.turnID == turnID else {
                    continue
                }

                let uiTurn = makeUpdatedUITurn(
                    from: updatedTurn,
                    characterID: character.externalID
                )

                let isCharacterTurn =
                    updatedTurn.author.authorID ==
                    character.externalID

                // Same terminal rule as sendMessage: a censored candidate ends
                // the regeneration even if the frame omits `is_final`.
                let isFinal = updatedTurn.candidates.contains { $0.isFinal == true || $0.isSafetyTruncated == true }
                if updatedTurn.candidates.contains(where: { $0.isSafetyTruncated == true }) {
                    chatsAwaitingFilteredHistory.insert(updatedTurn.turnKey.chatID)
                }
                scheduleTurnUpdate(uiTurn, isFinal: isFinal)

                if isCharacterTurn && isFinal {
                    conversationService.completeMutation(chatID: chatID)
                    break
                }
            }

        } catch is CancellationError {
            flushPendingTurnUpdates()
        } catch {
            flushPendingTurnUpdates()
            chatLogger.error("Response regeneration failed: \(error.localizedDescription, privacy: .private)")
            errorMessage =
                error.localizedDescription
        }
    }
    
    func editMessage(
        turnID: String,
        chatID: String,
        candidateID: String,
        newContent: String
    ) async {
        guard rewindingFromTurnID == nil else {
            errorMessage = "Wait for the rewind to finish before continuing."
            return
        }
        guard !isGenerating else {
            return
        }

        guard let character else {
            errorMessage = "Character not loaded."
            return
        }

        guard let authSession = authStore.session else {
            errorMessage = "Not authenticated."
            return
        }

        guard !newContent.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            errorMessage = "Message cannot be empty."
            return
        }

        guard beginMutation(chatID: chatID) else { return }
        let sessionGeneration = authStore.sessionGeneration
        isGenerating = true
        errorMessage = nil

        defer {
            isGenerating = false
        }
        do {
            try await webSocketRouter.connect(sessionToken: authSession.sessionToken)

            let requestID = UUID().uuidString
            let responses = try webSocketRouter.responses(for: requestID)
            defer { webSocketRouter.finish(requestID) }
            let message =
                try conversationService.makeEditTurnCandidateMessage(
                    chatID: chatID,
                    turnID: turnID,
                    currentCandidateID: candidateID,
                    newContent: newContent,
                    requestID: requestID
                )

            try await webSocketRouter.send(
                message
            )

            for try await decoded in responses {
                guard authStore.sessionGeneration == sessionGeneration, !Task.isCancelled else { throw CancellationError() }
                if decoded.command == "neo_error" {
                    let errorResponse = decoded.asErrorResponse
                    chatLogger.error("Character.AI rejected response operation (code \(errorResponse.errorCode, privacy: .public))")
                    throw NetworkError.serverMessage(errorResponse.comment)
                }

                guard let updatedTurn = decoded.turn else {
                    continue
                }
                
                guard activeChatID == chatID else {
                    break
                }
                guard updatedTurn.turnKey.chatID == chatID else {
                    continue
                }

                guard updatedTurn.turnKey.turnID == turnID else {
                    continue
                }
                
                guard updatedTurn.candidates.contains(where: {
                    $0.candidateID == updatedTurn.primaryCandidateID
                }) else {
                    continue
                }

                let uiTurn = makeUpdatedUITurn(
                    from: updatedTurn,
                    characterID: character.externalID
                )

                updateTurn(uiTurn)

                let newCandidateID = updatedTurn.primaryCandidateID

                let primaryCandidateMessage =
                    try conversationService
                        .makeUpdatePrimaryCandidateMessage(
                            chatID: chatID,
                            turnID: turnID,
                            candidateID: newCandidateID
                        )

                try await webSocketRouter.send(
                    primaryCandidateMessage
                )
                conversationService.completeMutation(chatID: chatID)

                break
            }

        } catch is CancellationError {
            return
        } catch {
            chatLogger.error("Message edit failed: \(error.localizedDescription, privacy: .private)")
            errorMessage =
                error.localizedDescription
        }
    }


    /// Default model for a fresh conversation: DeepSqueak for Plus, Pipsqueak 3
    /// for free, otherwise the first listed model.
    var defaultModelType: String? {
        ModelDefaults.defaultModelType(tier: subscriptionTier, availableModels: availableModels)
    }

    func loadAvailableModels() async {
        guard !isLoadingAvailableModels else { return }
        let session = authStore.sessionGeneration
        isLoadingAvailableModels = true
        availableModelsErrorMessage = nil
        startConversationErrorMessage = nil
        defer { isLoadingAvailableModels = false }

        // Loaded before the models are published, so the default is ready
        // whenever the model list changes.
        let tier = await loadSubscriptionTier()
        guard authStore.sessionGeneration == session, !Task.isCancelled else { return }
        subscriptionTier = tier

        do {
            let models = try await conversationService.loadAvailableModels()
            guard authStore.sessionGeneration == session, !Task.isCancelled else { return }
            availableModels = models
            if availableModels.isEmpty {
                availableModelsErrorMessage = "No AI models are currently available."
            }
        } catch is CancellationError {
            return
        } catch {
            guard authStore.sessionGeneration == session, !Task.isCancelled else { return }
            availableModelsErrorMessage = error.localizedDescription
        }
    }

    private func loadSubscriptionTier() async -> SubscriptionTier? {
        guard let username = authStore.session?.username, !username.isEmpty else { return nil }
        do {
            let profile = try await UserProfileService(authStore: authStore).loadProfile(username: username)
            return SubscriptionTier(subscriptionType: profile.subscriptionType)
        } catch {
            // Unknown tier keeps the server's first model; the failure is logged, not shown.
            chatLogger.error("Subscription tier request failed: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    func latestConversationCopySource(characterID: String) async throws -> ConversationCopySource? {
        try await conversationService.loadLatestConversationCopySource(
            characterID: characterID
        )
    }

    func createConversation(
        characterID: String,
        source: ConversationCopySource?,
        modelType: String
    ) async -> String? {
        guard !isLoading,
              !isCreatingConversationFromTurn else {
            startConversationErrorMessage = "Wait for current conversation updates to finish before creating a new conversation."
            return nil
        }
        guard let source else {
            startConversationErrorMessage = "A previous conversation turn is required to create a model-specific conversation."
            return nil
        }
        guard source.characterID == characterID else {
            startConversationErrorMessage = "The source conversation belongs to a different character."
            return nil
        }
        guard availableModels.contains(where: { $0.modelType == modelType }) else {
            startConversationErrorMessage = "Select an available AI model."
            return nil
        }

        isCreatingConversationFromTurn = true
        startConversationErrorMessage = nil
        defer {
            isCreatingConversationFromTurn = false
        }

        do {
            return try await conversationService.startNewConversation(
                chatID: source.chatID,
                endTurnID: source.endTurnID,
                modelType: modelType
            )
        } catch {
            startConversationErrorMessage = error.localizedDescription
            return nil
        }
    }

    func createConversation(
        from turn: Turn,
        modelType: String
    ) async -> String? {
        guard !isGenerating,
              !isLoading,
              rewindingFromTurnID == nil,
              pinningTurnIDs.isEmpty else {
            startConversationErrorMessage = "Wait for conversation updates to finish before creating a new conversation."
            return nil
        }
        guard turn.chatID == activeChatID,
              turnState(turnID: turn.turnID, chatID: turn.chatID) != nil else {
            startConversationErrorMessage = "The selected message is no longer in this conversation."
            return nil
        }
        guard availableModels.contains(where: { $0.modelType == modelType }) else {
            startConversationErrorMessage = "Select an available AI model."
            return nil
        }
        guard character != nil else {
            startConversationErrorMessage = "Character details are not loaded yet."
            return nil
        }

        isCreatingConversationFromTurn = true
        startConversationErrorMessage = nil
        defer {
            isCreatingConversationFromTurn = false
        }

        do {
            return try await conversationService.startNewConversation(
                chatID: turn.chatID,
                endTurnID: turn.turnID,
                modelType: modelType
            )
        } catch {
            startConversationErrorMessage = error.localizedDescription
            return nil
        }
    }

    func rewind(fromTurnID turnID: String, chatID: String) async {
        guard !isGenerating else {
            rewindErrorMessage = "Wait for the current response to finish before rewinding."
            return
        }
        guard activeChatID == chatID else {
            rewindErrorMessage = "This conversation is no longer active."
            return
        }
        guard rewindingFromTurnID == nil else {
            return
        }
        guard !isLoading else {
            rewindErrorMessage = "Wait for conversation history to finish loading before rewinding."
            return
        }

        let turnIDsToRemove: [String]
        do {
            turnIDsToRemove = try conversationService.turnIDsToRemove(
                from: turns,
                startingAt: turnID,
                chatID: chatID
            )
        } catch {
            rewindErrorMessage = error.localizedDescription
            return
        }
        guard pinningTurnIDs.isEmpty else {
            rewindErrorMessage = "Wait for pin updates to finish before rewinding."
            return
        }

        rewindingFromTurnID = turnID
        rewindErrorMessage = nil
        defer {
            rewindingFromTurnID = nil
        }

        do {
            // A selected latest turn has no successors; no API removal is
            // needed and the local history already matches that result.
            if !turnIDsToRemove.isEmpty {
                guard beginMutation(chatID: chatID) else {
                    rewindErrorMessage = errorMessage
                    errorMessage = nil
                    return
                }
                try await conversationService.removeTurns(
                    chatID: chatID,
                    turnIDs: turnIDsToRemove
                )
                guard activeChatID == chatID else {
                    return
                }

                let removedIDs = Set(turnIDsToRemove)
                replaceTurns(turnStates.filter { !removedIDs.contains($0.id) })
                conversationService.cacheRewind(chatID: chatID, removedIDs: removedIDs)
                conversationService.completeMutation(chatID: chatID)
            }
        } catch {
            rewindErrorMessage = error.localizedDescription
        }
    }

    func togglePin(
        turnID: String,
        chatID: String
    ) async {
        guard rewindingFromTurnID == nil else {
            pinErrorMessage = "Wait for the rewind to finish before updating pins."
            return
        }
        guard !pinningTurnIDs.contains(turnID) else {
            return
        }
        guard let turn = turnState(turnID: turnID, chatID: chatID)?.turn else {
            pinErrorMessage = "Conversation turn not found."
            return
        }
        guard let authSession = authStore.session else {
            pinErrorMessage = "Not authenticated."
            return
        }

        guard beginMutation(chatID: chatID) else { return }
        let sessionGeneration = authStore.sessionGeneration
        let isPinned = !turn.isPinned
        pinningTurnIDs.insert(turnID)
        pinErrorMessage = nil
        defer { pinningTurnIDs.remove(turnID) }

        do {
            let request = try conversationService.makeSetTurnPinMessage(
                chatID: chatID, turnID: turnID, isPinned: isPinned
            )
            try await webSocketRouter.connect(sessionToken: authSession.sessionToken)
            let responses = try webSocketRouter.responses(for: request.requestID, timeout: .seconds(8))
            defer { webSocketRouter.finish(request.requestID) }
            try await webSocketRouter.send(request.message)
            for try await response in responses {
                guard authStore.sessionGeneration == sessionGeneration, !Task.isCancelled else { throw CancellationError() }
                if response.command == "neo_error" {
                    throw NetworkError.serverMessage(response.asErrorResponse.comment)
                }
                guard response.command == "update_turn", let apiTurn = response.turn,
                      apiTurn.turnKey.chatID == chatID, apiTurn.turnKey.turnID == turnID,
                      activeChatID == chatID,
                      let state = turnState(turnID: turnID, chatID: chatID) else {
                    throw NetworkError.serverMessage("The pin response did not match the requested turn.")
                }
                let value = apiTurn.isPinned ?? isPinned
                state.update(state.turn.settingPinned(value))
                conversationService.cacheCompletedTurn(state.turn)
                conversationService.completeMutation(chatID: chatID)
                if let buffered = pendingTurnUpdates[turnID] {
                    pendingTurnUpdates[turnID] = buffered.settingPinned(value)
                }
                return
            }
            throw NetworkError.invalidResponse
        } catch is CancellationError {
            return
        } catch {
            pinErrorMessage = error.localizedDescription
        }
    }

    private func scheduleTurnUpdate(_ turn: Turn, isFinal: Bool) {
        let turnID = turn.turnID
        pendingTurnUpdates[turnID] = turn

        if isFinal {
            turnUpdateTasks.removeValue(forKey: turnID)?.cancel()
            flushTurnUpdate(turnID: turnID)
        } else if turnUpdateTasks[turnID] == nil {
            turnUpdateTasks[turnID] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(40))
                guard !Task.isCancelled else { return }
                self?.flushTurnUpdate(turnID: turnID)
            }
        }
    }

    private func flushTurnUpdate(turnID: String) {
        turnUpdateTasks.removeValue(forKey: turnID)
        guard let turn = pendingTurnUpdates.removeValue(forKey: turnID) else { return }
        updateTurn(turn)
    }

    private func updateTurn(_ turn: Turn) {
        // Merge like the web client's updateCandidate: a partial frame (e.g. a
        // censored final update without candidate content) cannot clobber the
        // turn already held for this ID.
        let existing = turnState(turnID: turn.turnID, chatID: turn.chatID)?.turn
        let mergedTurn = existing.map { turn.merged(onto: $0) } ?? turn
        conversationService.cacheCompletedTurn(mergedTurn)
        if let state = turnState(turnID: mergedTurn.turnID, chatID: mergedTurn.chatID) {
            state.update(mergedTurn)
        } else {
            let state = TurnState(mergedTurn)
            turnsByKey[TurnKey(turnId: mergedTurn.turnID, chatId: mergedTurn.chatID)] = state
            turnStates.append(state)
        }
    }

    private func makeUpdatedUITurn(
        from apiTurn: APITurn,
        characterID: String
    ) -> Turn {
        let existingTurn = pendingTurnUpdates[apiTurn.turnKey.turnID]
            ?? turnState(turnID: apiTurn.turnKey.turnID, chatID: apiTurn.turnKey.chatID)?.turn
        return conversationService.makeUITurn(
            from: apiTurn,
            characterID: characterID,
            isPinned: apiTurn.isPinned ?? existingTurn?.isPinned ?? false
        )
    }

    func loadRecentChats(forceRefresh: Bool = false) async {
        let loadID = UUID()
        let session = authStore.sessionGeneration
        recentChatsLoadID = loadID
        let accountID = authStore.session?.userID ?? authStore.offlineAccountID
        if let accountID {
            let saved = historyStore.list(accountID: accountID)
            if !saved.snapshots.isEmpty, recentChats.isEmpty {
                recentChats = saved.snapshots.map(\.summary)
                historyNotice = "Showing saved conversations; they may be out of date."
            }
            if saved.unreadable > 0 { historyNotice = "Some saved conversations could not be read and were left unchanged." }
        }
        if authStore.isOfflineReading {
            recentChatsLoadID = nil
            isLoading = false
            if recentChats.isEmpty && historyNotice == nil { historyNotice = "No saved conversations are available for offline reading yet." }
            return
        }
        isLoading = true
        errorMessage = nil
        defer { if recentChatsLoadID == loadID { isLoading = false; recentChatsLoadID = nil } }
        do {
            let loaded = try await conversationService.loadRecentChats(forceRefresh: forceRefresh)
            guard recentChatsLoadID == loadID, authStore.sessionGeneration == session, !Task.isCancelled else { return }
            recentChats = loaded
            historyNotice = nil
            recentChatsSession = session
            recentPreviewGeneration = UUID()
        } catch is CancellationError { return }
        catch {
            guard recentChatsLoadID == loadID, authStore.sessionGeneration == session, !Task.isCancelled else { return }
            if recentChats.isEmpty { errorMessage = error.localizedDescription }
            else { historyNotice = "Showing saved conversations; refresh failed and they may be out of date." }
            chatLogger.error("Recent conversations request failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    func loadRecentPreview(characterID: String, generation: UUID) async {
        let session = authStore.sessionGeneration
        guard generation == recentPreviewGeneration, recentChatsSession == session,
              recentChats.contains(where: { $0.characterID == characterID }) else { return }
        do {
            let previews = try await conversationService.loadChatPreviews(characterIDs: [characterID])
            guard generation == recentPreviewGeneration, session == authStore.sessionGeneration, !Task.isCancelled else { return }
            let messages = Dictionary(previews.filter { $0.characterID == characterID }.compactMap { preview in
                preview.lastMessage.map { (preview.chatID, $0) }
            }, uniquingKeysWith: { first, _ in first })
            for index in recentChats.indices where recentChats[index].characterID == characterID {
                let conversation = recentChats[index]
                guard let message = messages[conversation.chatID], message != conversation.lastMessage else { continue }
                recentChats[index] = ConversationSummary(
                    id: conversation.id, chatID: conversation.chatID,
                    characterID: conversation.characterID, characterName: conversation.characterName,
                    characterAvatarURI: conversation.characterAvatarURI,
                    lastUpdated: conversation.lastUpdated, state: conversation.state, lastMessage: message
                )
            }
        } catch {
            // Base rows stay usable when previews are unavailable. A row task
            // retries only on its next lifetime or an explicit list refresh.
        }
    }

    func disconnect() {
        historyLoadID = nil
        characterLoadID = nil
        chatLoadID = nil
        flushPendingTurnUpdates()
        webSocketRouter.disconnect()
    }

    deinit {
        for task in turnUpdateTasks.values { task.cancel() }
    }

    private func flushPendingTurnUpdates() {
        let turnIDs = Array(pendingTurnUpdates.keys)
        for turnID in turnIDs {
            turnUpdateTasks.removeValue(forKey: turnID)?.cancel()
            flushTurnUpdate(turnID: turnID)
        }
    }
}
