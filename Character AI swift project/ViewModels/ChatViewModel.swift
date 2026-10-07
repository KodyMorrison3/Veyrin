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
    var lastTurnID: String? { turnStates.last?.id }
    @Published var recentChats: [ConversationSummary] = []
    @Published var isLoading = false
    @Published var isGenerating = false
    @Published var errorMessage: String?
    @Published private(set) var pinningTurnIDs: Set<String> = []
    @Published var pinErrorMessage: String?
    @Published var rewindErrorMessage: String?
    @Published private(set) var rewindingFromTurnID: String?
    @Published private(set) var availableModels: [ModelSelectionOption] = []
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

    private struct PendingPinRequest {
        let chatID: String
        let turnID: String
        let isPinned: Bool
    }

    private var pendingPinRequests: [String: PendingPinRequest] = [:]
    private var pendingTurnUpdates: [String: Turn] = [:]
    private var turnUpdateTasks: [String: Task<Void, Never>] = [:]
    private var deferredWebSocketMessages: [WebSocketTurnResponse] = []
    private var characterHistoryLoadID: UUID?
    private var activeChatID: String?
    private var isReceivingWebSocketMessage = false
    private var receiveWaiters: [CheckedContinuation<Void, Never>] = []

    let authStore: AuthStore
    private let conversationService: ConversationService
    let authenticatedHTTPClient: AuthenticatedHTTPClient
    var preferences: AppPreferences { .shared }
    private let webSocketClient = WebSocketClient()

    init(
        authStore: AuthStore,
        conversationService: ConversationService? = nil
    ) {
        self.authStore = authStore
        let client = AuthenticatedHTTPClient(authStore: authStore)
        self.authenticatedHTTPClient = client
        self.conversationService = conversationService ?? ConversationService(
            authenticatedHTTPClient: client
        )
    }

    func createRealChat(
        characterID: String
    ) async -> String? {
        guard let authSession = authStore.session else {
            errorMessage = "Not authenticated."
            return nil
        }

        isLoading = true
        errorMessage = nil

        defer {
            isLoading = false
        }

        let chatID = UUID().uuidString

        do {
            let message =
                try conversationService.makeCreateChatMessage(
                    characterID: characterID,
                    creatorID: authSession.userID,
                    chatID: chatID
                )

            if !(await webSocketClient.isConnected) {
                try await webSocketClient.connect(
                    sessionToken: authSession.sessionToken
                )
            }

            try await webSocketClient.send(message)

            let response = try await webSocketClient.receive()
            _ = response // The create-chat acknowledgement may contain private identifiers.

            chat = Chat(
                chatID: chatID,
                creatorID: authSession.userID,
                visibility: "VISIBILITY_PRIVATE",
                characterID: characterID,
                type: "TYPE_ONE_ON_ONE"
            )

            return chatID

        } catch {
            chatLogger.error("Chat creation failed: \(error.localizedDescription, privacy: .private)")

            errorMessage = error.localizedDescription
            return nil
        }
    }

    func loadCharacter(
        externalID: String
    ) async {
        isLoading = true
        errorMessage = nil

        do {
            let characterAPI = CharacterAPI()

            character =
                try await characterAPI.getCharacterInfo(
                    externalID: externalID
                )

        } catch {
            errorMessage =
                error.localizedDescription
        }

        isLoading = false
    }

    func loadChat(
        chatID: String
    ) async {
        isLoading = true
        errorMessage = nil

        do {
            chat =
                try await conversationService.loadChat(
                    chatID: chatID
                )

        } catch {
            errorMessage =
                error.localizedDescription
        }

        isLoading = false
    }

    /// Loads conversation facts from GET https://neo.character.ai/chat/{chatID}/conversation-facts/
    func loadFacts(chatID: String) async {
        isLoadingFacts = true
        conversationFactsErrorMessage = nil
        defer { isLoadingFacts = false }
        do {
            let response = try await conversationService.loadConversationFacts(chatID: chatID)
            var mapped: [String: [ConversationFact]] = [:]
            if let factsDict = response.conversationFacts {
                for (entity, container) in factsDict {
                    mapped[entity] = container.facts
                }
            }
            self.conversationFacts = mapped
        } catch {
            conversationFactsErrorMessage = error.localizedDescription
            chatLogger.error("Conversation facts request failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Loads character voted state from GET https://neo.character.ai/character/v1/character_voted/{characterID}/voted
    func loadCharacterVotedStatus(characterID: String) async {
        do {
            let voted = try await conversationService.loadCharacterVoted(characterID: characterID)
            self.isCharacterVoted = voted
        } catch {
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

        do {
            let chats = try await conversationService.loadCharacterRecentChats(
                characterID: characterID
            )
            guard characterHistoryLoadID == loadID else { return }
            recentCharacterChats = chats
        } catch {
            guard characterHistoryLoadID == loadID else { return }
            characterHistoryErrorMessage = error.localizedDescription
            chatLogger.error("Character history request failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    func loadRealTurns(
        chatID: String
    ) async {
        guard rewindingFromTurnID == nil else {
            return
        }
        guard let character else {
            return
        }
        self.character = character

        if activeChatID != chatID {
            let hadPendingPins = !pendingPinRequests.isEmpty
            failPendingPinRequests(
                forChatID: activeChatID,
                error: NetworkError.serverMessage(
                    "Conversation changed before the pin update completed."
                )
            )
            deferredWebSocketMessages.removeAll()
            if hadPendingPins && !isGenerating {
                await webSocketClient.disconnect()
            }
        }
        activeChatID = chatID
        isLoading = true
        errorMessage = nil
        turnUpdateTasks.values.forEach { $0.cancel() }
        turnUpdateTasks.removeAll()
        pendingTurnUpdates.removeAll()
        turnStates = []

        do {
            let apiTurns = try await conversationService.loadAllTurns(
                chatID: chatID
            )
            guard activeChatID == chatID else {
                isLoading = false
                return
            }

            let pinnedIDs: Set<String>
            do {
                pinnedIDs = try await conversationService.loadPinnedTurnIDs(
                    chatID: chatID
                )
            } catch {
                // Ordinary history remains usable if the pinned-only query fails.
                chatLogger.error("Pinned-turn lookup failed: \(error.localizedDescription, privacy: .private)")
                pinnedIDs = []
            }
            guard activeChatID == chatID else {
                isLoading = false
                return
            }

            turnStates = apiTurns.map { apiTurn in
                let isPinned = apiTurn.isPinned
                    ?? pinnedIDs.contains(apiTurn.turnKey.turnID)
                return TurnState(conversationService.makeUITurn(
                    from: apiTurn,
                    characterID: character.externalID,
                    isPinned: isPinned
                ))
            }

        } catch {
            chatLogger.error("Conversation history request failed: \(error.localizedDescription, privacy: .private)")

            errorMessage =
                error.localizedDescription
        }

        isLoading = false
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

        isGenerating = true
        errorMessage = nil

        defer {
            isGenerating = false
        }

        do {
            if !(await webSocketClient.isConnected) {
                try await webSocketClient.connect(
                    sessionToken: authSession.sessionToken
                )
            }

            let message =
                try conversationService
                    .makeCreateAndGenerateTurnMessage(
                        characterID: character.externalID,
                        userID: authSession.userID,
                        username: authSession.username,
                        chatID: chatID,
                        message: trimmedContent
                    )

            try await webSocketClient.send(
                message
            )

            while true {
                let decoded = try await receiveChatWebSocketMessage()
                if handlePinResponse(decoded, activeChatID: chatID) {
                    continue
                }

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

                guard let turn = decoded.turn else {
                    chatLogger.error("WebSocket response did not contain a turn")

                    throw NetworkError.serverMessage(
                        "Character.AI returned a response without a conversation turn."
                    )
                }

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

                let isFinal = turn.candidates.contains { $0.isFinal == true }
                scheduleTurnUpdate(uiTurn, isFinal: isFinal)

                if isCharacterTurn && isFinal {
                    break
                }
            }

            try await finishPendingPinResponses(chatID: chatID)
        } catch {
            flushPendingTurnUpdates()
            failPendingPinRequests(forChatID: chatID, error: error)
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

        guard let turn = turns.first(where: {
            $0.turnID == turnID
        }) else {
            errorMessage = "Conversation turn not found."
            return
        }

        guard !turn.isHuman else {
            errorMessage = "Only character responses can be regenerated."
            return
        }

        isGenerating = true
        errorMessage = nil

        defer {
            isGenerating = false
        }

        do {
            if !(await webSocketClient.isConnected) {
                try await webSocketClient.connect(
                    sessionToken: authSession.sessionToken
                )
            }

            let message =
                try conversationService.makeGenerateTurnCandidateMessage(
                    characterID: character.externalID,
                    username: authSession.username,
                    chatID: chatID,
                    turnID: turnID
                )

            try await webSocketClient.send(
                message
            )

            while true {
                let decoded = try await receiveChatWebSocketMessage()
                if decoded.command == "neo_error" {
                    let errorResponse = decoded.asErrorResponse
                    chatLogger.error("Character.AI rejected response operation (code \(errorResponse.errorCode, privacy: .public))")
                    throw NetworkError.serverMessage(errorResponse.comment)
                }
                if handlePinResponse(decoded, activeChatID: chatID) {
                    continue
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

                let isFinal = updatedTurn.candidates.contains { $0.isFinal == true }
                scheduleTurnUpdate(uiTurn, isFinal: isFinal)

                if isCharacterTurn && isFinal {
                    break
                }
            }

            try await finishPendingPinResponses(chatID: chatID)
        } catch {
            flushPendingTurnUpdates()
            failPendingPinRequests(forChatID: chatID, error: error)
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

        isGenerating = true
        errorMessage = nil

        defer {
            isGenerating = false
        }
        do {
            if !(await webSocketClient.isConnected) {
                try await webSocketClient.connect(
                    sessionToken: authSession.sessionToken
                )
            }

            let message =
                try conversationService.makeEditTurnCandidateMessage(
                    chatID: chatID,
                    turnID: turnID,
                    currentCandidateID: candidateID,
                    newContent: newContent
                )

            try await webSocketClient.send(
                message
            )

            while true {
                let decoded = try await receiveChatWebSocketMessage()
                if decoded.command == "neo_error" {
                    let errorResponse = decoded.asErrorResponse
                    chatLogger.error("Character.AI rejected response operation (code \(errorResponse.errorCode, privacy: .public))")
                    throw NetworkError.serverMessage(errorResponse.comment)
                }
                if handlePinResponse(decoded, activeChatID: chatID) {
                    continue
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

                try await webSocketClient.send(
                    primaryCandidateMessage
                )

                break
            }

            try await finishPendingPinResponses(chatID: chatID)
        } catch {
            failPendingPinRequests(forChatID: chatID, error: error)
            chatLogger.error("Message edit failed: \(error.localizedDescription, privacy: .private)")
            errorMessage =
                error.localizedDescription
        }
    }


    func loadAvailableModels() async {
        isLoadingAvailableModels = true
        availableModelsErrorMessage = nil
        startConversationErrorMessage = nil
        defer {
            isLoadingAvailableModels = false
        }

        do {
            availableModels = try await conversationService.loadAvailableModels()
            if availableModels.isEmpty {
                availableModelsErrorMessage = "No AI models are currently available."
            }
        } catch {
            availableModelsErrorMessage = error.localizedDescription
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
              turns.contains(where: { $0.turnID == turn.turnID && $0.chatID == turn.chatID }) else {
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
                try await conversationService.removeTurns(
                    chatID: chatID,
                    turnIDs: turnIDsToRemove
                )
                guard activeChatID == chatID else {
                    return
                }

                let removedIDs = Set(turnIDsToRemove)
                turnStates.removeAll { removedIDs.contains($0.id) }
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
        guard let turn = turns.first(where: {
            $0.turnID == turnID && $0.chatID == chatID
        }) else {
            pinErrorMessage = "Conversation turn not found."
            return
        }
        guard let authSession = authStore.session else {
            pinErrorMessage = "Not authenticated."
            return
        }

        let shouldReceivePinResponse = !isGenerating
        let isPinned = !turn.isPinned
        pinningTurnIDs.insert(turnID)
        pinErrorMessage = nil

        do {
            let request = try conversationService.makeSetTurnPinMessage(
                chatID: chatID,
                turnID: turnID,
                isPinned: isPinned
            )
            pendingPinRequests[request.requestID] = PendingPinRequest(
                chatID: chatID,
                turnID: turnID,
                isPinned: isPinned
            )

            if !(await webSocketClient.isConnected) {
                try await webSocketClient.connect(
                    sessionToken: authSession.sessionToken
                )
            }
            try await webSocketClient.send(request.message)

            if shouldReceivePinResponse {
                try await finishPendingPinResponses(chatID: chatID)
            }
        } catch {
            failPendingPinRequests(forTurnID: turnID, error: error)
            pinErrorMessage = error.localizedDescription
        }
    }

    private func receiveChatWebSocketMessage() async throws -> WebSocketTurnResponse {
        if !deferredWebSocketMessages.isEmpty {
            return deferredWebSocketMessages.removeFirst()
        }
        return try await receiveWebSocketMessageFromSocket()
    }

    private func receiveWebSocketMessageFromSocket() async throws -> WebSocketTurnResponse {
        while isReceivingWebSocketMessage {
            await withCheckedContinuation { continuation in
                receiveWaiters.append(continuation)
            }
        }

        isReceivingWebSocketMessage = true
        defer {
            isReceivingWebSocketMessage = false
            if !receiveWaiters.isEmpty {
                receiveWaiters.removeFirst().resume()
            }
        }

        let data = try await webSocketClient.receive()
        return try await WebSocketMessageProcessor.shared.decode(data)
    }

    private func handlePinResponse(
        _ decoded: WebSocketTurnResponse,
        activeChatID: String
    ) -> Bool {
        guard let pending = pendingPinRequests[decoded.requestID],
              pending.chatID == activeChatID else {
            return false
        }

        if decoded.command == "neo_error" {
            completePinRequest(
                requestID: decoded.requestID,
                error: NetworkError.serverMessage(decoded.errorComment ?? "Character.AI rejected the pin update.")
            )
            return true
        }

        guard decoded.command == "update_turn",
              let apiTurn = decoded.turn else {
            completePinRequest(
                requestID: decoded.requestID,
                error: NetworkError.serverMessage("Character.AI returned an invalid pin response.")
            )
            return true
        }

        guard apiTurn.turnKey.chatID == pending.chatID,
              apiTurn.turnKey.turnID == pending.turnID,
              activeChatID == pending.chatID else {
            completePinRequest(
                requestID: decoded.requestID,
                error: NetworkError.serverMessage("The pin response did not match the requested turn.")
            )
            return true
        }

        guard activeChatID == pending.chatID else {
            completePinRequest(
                requestID: decoded.requestID,
                error: NetworkError.serverMessage(
                    "Conversation changed before the pin update completed."
                )
            )
            return true
        }
        guard let index = turnStates.firstIndex(where: {
            $0.id == pending.turnID && $0.turn.chatID == pending.chatID
        }) else {
            completePinRequest(
                requestID: decoded.requestID,
                error: NetworkError.serverMessage("The requested conversation turn is no longer available.")
            )
            return true
        }
        turnStates[index].update(turnStates[index].turn.settingPinned(
            apiTurn.isPinned ?? pending.isPinned
        ))
        completePinRequest(requestID: decoded.requestID, error: nil)
        return true
    }

    private func completePinRequest(requestID: String, error: Error?) {
        guard let pending = pendingPinRequests.removeValue(forKey: requestID) else {
            return
        }
        pinningTurnIDs.remove(pending.turnID)

        if let error {
            pinErrorMessage = error.localizedDescription
        }
    }

    private func finishPendingPinResponses(chatID: String) async throws {
        while pendingPinRequests.values.contains(where: { $0.chatID == chatID }) {
            let decoded = try await receiveWebSocketMessageFromSocket()
            if !handlePinResponse(decoded, activeChatID: chatID) {
                deferredWebSocketMessages.append(decoded)
            }
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
        if let state = turnStates.first(where: {
            $0.id == turn.turnID && $0.turn.chatID == turn.chatID
        }) {
            state.update(turn)
        } else {
            turnStates.append(TurnState(turn))
        }
    }

    private func makeUpdatedUITurn(
        from apiTurn: APITurn,
        characterID: String
    ) -> Turn {
        let existingTurn = turnStates.first(where: {
            $0.id == apiTurn.turnKey.turnID && $0.turn.chatID == apiTurn.turnKey.chatID
        })?.turn
        return conversationService.makeUITurn(
            from: apiTurn,
            characterID: characterID,
            isPinned: apiTurn.isPinned ?? existingTurn?.isPinned ?? false
        )
    }

    private func failPendingPinRequests(
        forTurnID turnID: String? = nil,
        forChatID chatID: String? = nil,
        error: Error
    ) {
        let requestIDs = pendingPinRequests.compactMap { requestID, pending in
            let matchesTurn = turnID == nil || pending.turnID == turnID
            let matchesChat = chatID == nil || pending.chatID == chatID
            return matchesTurn && matchesChat ? requestID : nil
        }
        for requestID in requestIDs {
            completePinRequest(requestID: requestID, error: error)
        }
    }

    func loadRecentChats() async {
        isLoading = true
        errorMessage = nil

        do {
            recentChats =
                try await conversationService.loadRecentChats()

        } catch {
            chatLogger.error("Recent conversations request failed: \(error.localizedDescription, privacy: .private)")

            errorMessage =
                error.localizedDescription
        }

        isLoading = false
    }

    func disconnect() {
        failPendingPinRequests(
            error: NetworkError.serverMessage(
                "The WebSocket connection closed before the pin update completed."
            )
        )
        flushPendingTurnUpdates()
        Task { await webSocketClient.disconnect() }
    }

    private func flushPendingTurnUpdates() {
        let turnIDs = Array(pendingTurnUpdates.keys)
        for turnID in turnIDs {
            turnUpdateTasks.removeValue(forKey: turnID)?.cancel()
            flushTurnUpdate(turnID: turnID)
        }
    }
}
