//
//  ChatViewModel.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 26/09/2026.
//

import Foundation
import Combine

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var character: Character?
    @Published var chat: Chat?
    @Published var turns: [Turn] = []
    @Published var recentChats: [ConversationSummary] = []
    @Published private(set) var hidingCharacterIDs: Set<String> = []
    @Published var hideErrorMessage: String?
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

    private struct PendingPinRequest {
        let chatID: String
        let turnID: String
        let isPinned: Bool
    }

    private var pendingPinRequests: [String: PendingPinRequest] = [:]
    private var deferredWebSocketMessages: [String] = []
    private var activeChatID: String?
    private var isReceivingWebSocketMessage = false
    private var receiveWaiters: [CheckedContinuation<Void, Never>] = []

    private let authStore: AuthStore
    private let conversationService: ConversationService
    private let webSocketClient = WebSocketClient()

    init(
        authStore: AuthStore,
        conversationService: ConversationService? = nil
    ) {
        self.authStore = authStore
        self.conversationService = conversationService ?? ConversationService(
            authenticatedHTTPClient: AuthenticatedHTTPClient(
                authStore: authStore
            )
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

            if !webSocketClient.isConnected {
                try await webSocketClient.connect(
                    sessionToken: authSession.sessionToken
                )
            }

            try await webSocketClient.send(
                message
            )

            let response =
                try await webSocketClient.receive()

            print("CREATE CHAT RESPONSE:")
            print(response)

            chat = Chat(
                chatID: chatID,
                creatorID: authSession.userID,
                visibility: "VISIBILITY_PRIVATE",
                characterID: characterID,
                type: "TYPE_ONE_ON_ONE"
            )

            return chatID

        } catch {
            print(
                "CREATE CHAT ERROR:",
                error
            )

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

        print("LOADING CHAT HISTORY")
        print("CHAT ID:", chatID)
        print("CHARACTER ID:", character.externalID)

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
                webSocketClient.disconnect()
            }
        }
        activeChatID = chatID
        isLoading = true
        errorMessage = nil
        turns = []

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
                print("LOAD PINNED TURN IDS ERROR:", error)
                pinnedIDs = []
            }
            guard activeChatID == chatID else {
                isLoading = false
                return
            }

            print(
                "TOTAL TURNS LOADED:",
                apiTurns.count
            )

            turns = apiTurns.map { apiTurn in
                let isPinned = apiTurn.isPinned
                    ?? pinnedIDs.contains(apiTurn.turnKey.turnID)
                return conversationService.makeUITurn(
                    from: apiTurn,
                    characterID: character.externalID,
                    isPinned: isPinned
                )
            }

            print(
                "UI TURN COUNT:",
                turns.count
            )

        } catch {
            print(
                "LOAD TURNS ERROR:",
                error
            )

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
            if !webSocketClient.isConnected {
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

            print("SENDING MESSAGE")
            print("CHAT ID:", chatID)
            print("CHARACTER ID:", character.externalID)
            print("MESSAGE:", trimmedContent)

            try await webSocketClient.send(
                message
            )

            while true {
                let response =
                    try await receiveChatWebSocketMessage()

                if handlePinResponse(response, activeChatID: chatID) {
                    continue
                }

                guard let data = response.data(
                    using: .utf8
                ) else {
                    continue
                }

                let rawMessage =
                    try JSONDecoder().decode(
                        WebSocketMessage.self,
                        from: data
                    )

                if rawMessage.command == "neo_error" {
                    let errorResponse =
                        try JSONDecoder().decode(
                            WebSocketErrorResponse.self,
                            from: data
                        )

                    print(
                        "CHARACTER.AI ERROR:"
                    )

                    print(
                        errorResponse.comment
                    )

                    print(
                        "ERROR CODE:",
                        errorResponse.errorCode
                    )

                    if errorResponse.errorCode == 403 {
                        throw NetworkError.serverMessage(
                            "Character.AI denied access to this conversation. It may have been deleted or is no longer available."
                        )
                    }

                    throw NetworkError.serverMessage(
                        errorResponse.comment
                    )
                }

                let message =
                    try JSONDecoder().decode(
                        WebSocketTurnResponse.self,
                        from: data
                    )

                guard let turn = message.turn else {
                    print(
                        "WEBSOCKET MESSAGE WITHOUT TURN:"
                    )

                    print(response)

                    throw NetworkError.serverMessage(
                        "Character.AI returned a response without a conversation turn."
                    )
                }

                print("RECEIVED TURN")
                print(
                    "REQUEST CHAT ID:",
                    chatID
                )

                print(
                    "RESPONSE CHAT ID:",
                    turn.turnKey.chatID
                )

                print(
                    "TURN ID:",
                    turn.turnKey.turnID
                )

                print(
                    "AUTHOR:",
                    turn.author.name
                )

                guard activeChatID == chatID else {
                    break
                }
                guard turn.turnKey.chatID == chatID else {
                    print(
                        "IGNORING TURN FROM DIFFERENT CHAT"
                    )

                    print(
                        "EXPECTED CHAT:",
                        chatID
                    )

                    print(
                        "RECEIVED CHAT:",
                        turn.turnKey.chatID
                    )

                    continue
                }

                let uiTurn = makeUpdatedUITurn(
                    from: turn,
                    characterID: character.externalID
                )

                if let index = turns.firstIndex(
                    where: {
                        $0.turnID == uiTurn.turnID
                    }
                ) {
                    turns[index] = uiTurn
                } else {
                    turns.append(uiTurn)
                }

                let isCharacterTurn =
                    turn.author.authorID ==
                    character.externalID

                let isFinal =
                    turn.candidates.contains {
                        $0.isFinal == true
                    }

                if isCharacterTurn && isFinal {
                    break
                }
            }

            try await finishPendingPinResponses(chatID: chatID)
        } catch {
            failPendingPinRequests(forChatID: chatID, error: error)
            print(
                "SEND MESSAGE ERROR:",
                error
            )
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
            if !webSocketClient.isConnected {
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

            print("REGENERATING RESPONSE")
            print("CHAT ID:", chatID)
            print("TURN ID:", turnID)
            print("CHARACTER ID:", character.externalID)

            try await webSocketClient.send(
                message
            )

            while true {
                let response =
                    try await receiveChatWebSocketMessage()

                if handlePinResponse(response, activeChatID: chatID) {
                    continue
                }

                guard let data = response.data(
                    using: .utf8
                ) else {
                    continue
                }

                let rawMessage =
                    try JSONDecoder().decode(
                        WebSocketMessage.self,
                        from: data
                    )

                if rawMessage.command == "neo_error" {
                    let errorResponse =
                        try JSONDecoder().decode(
                            WebSocketErrorResponse.self,
                            from: data
                        )

                    print("CHARACTER.AI ERROR:")
                    print(errorResponse.comment)
                    print("ERROR CODE:", errorResponse.errorCode)

                    throw NetworkError.serverMessage(
                        errorResponse.comment
                    )
                }

                let message =
                    try JSONDecoder().decode(
                        WebSocketTurnResponse.self,
                        from: data
                    )

                guard let updatedTurn = message.turn else {
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

                if let index = turns.firstIndex(
                    where: {
                        $0.turnID == uiTurn.turnID
                    }
                ) {
                    turns[index] = uiTurn
                }

                let isCharacterTurn =
                    updatedTurn.author.authorID ==
                    character.externalID

                let isFinal =
                    updatedTurn.candidates.contains {
                        $0.isFinal == true
                    }

                if isCharacterTurn && isFinal {
                    break
                }
            }

            try await finishPendingPinResponses(chatID: chatID)
        } catch {
            failPendingPinRequests(forChatID: chatID, error: error)
            print(
                "REGENERATE RESPONSE ERROR:",
                error
            )
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
            if !webSocketClient.isConnected {
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

            print("EDITING MESSAGE")
            print("CHAT ID:", chatID)
            print("TURN ID:", turnID)
            print("CANDIDATE ID:", candidateID)

            try await webSocketClient.send(
                message
            )

            while true {
                let response =
                    try await receiveChatWebSocketMessage()

                if handlePinResponse(response, activeChatID: chatID) {
                    continue
                }

                guard let data = response.data(
                    using: .utf8
                ) else {
                    continue
                }

                let rawMessage =
                    try JSONDecoder().decode(
                        WebSocketMessage.self,
                        from: data
                    )

                if rawMessage.command == "neo_error" {
                    let errorResponse =
                        try JSONDecoder().decode(
                            WebSocketErrorResponse.self,
                            from: data
                        )

                    print("CHARACTER.AI ERROR:")
                    print(errorResponse.comment)
                    print("ERROR CODE:", errorResponse.errorCode)

                    throw NetworkError.serverMessage(
                        errorResponse.comment
                    )
                }

                let message =
                    try JSONDecoder().decode(
                        WebSocketTurnResponse.self,
                        from: data
                    )

                guard let updatedTurn = message.turn else {
                    continue
                }
                
                print("EDIT UPDATE RECEIVED")
                print("TURN ID:", updatedTurn.turnKey.turnID)
                print("CHAT ID:", updatedTurn.turnKey.chatID)
                print("PRIMARY CANDIDATE ID:", updatedTurn.primaryCandidateID)
            
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

                if let index = turns.firstIndex(
                    where: {
                        $0.turnID == uiTurn.turnID
                    }
                ) {
                    turns[index] = uiTurn
                }

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
            print(
                "EDIT MESSAGE ERROR:",
                error
            )
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
                turns.removeAll { removedIDs.contains($0.turnID) }
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

            if !webSocketClient.isConnected {
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

    private func receiveChatWebSocketMessage() async throws -> String {
        if !deferredWebSocketMessages.isEmpty {
            return deferredWebSocketMessages.removeFirst()
        }
        return try await receiveWebSocketMessageFromSocket()
    }

    private func receiveWebSocketMessageFromSocket() async throws -> String {
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

        return try await webSocketClient.receive()
    }

    private func handlePinResponse(
        _ response: String,
        activeChatID: String
    ) -> Bool {
        guard let data = response.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(WebSocketMessage.self, from: data),
              let pending = pendingPinRequests[envelope.requestID],
              pending.chatID == activeChatID else {
            return false
        }

        if envelope.command == "neo_error",
           let errorResponse = try? JSONDecoder().decode(WebSocketErrorResponse.self, from: data) {
            completePinRequest(
                requestID: envelope.requestID,
                error: NetworkError.serverMessage(errorResponse.comment)
            )
            return true
        }

        guard envelope.command == "update_turn",
              let update = try? JSONDecoder().decode(WebSocketTurnResponse.self, from: data),
              let apiTurn = update.turn else {
            completePinRequest(
                requestID: envelope.requestID,
                error: NetworkError.serverMessage("Character.AI returned an invalid pin response.")
            )
            return true
        }

        guard apiTurn.turnKey.chatID == pending.chatID,
              apiTurn.turnKey.turnID == pending.turnID,
              activeChatID == pending.chatID else {
            completePinRequest(
                requestID: envelope.requestID,
                error: NetworkError.serverMessage("The pin response did not match the requested turn.")
            )
            return true
        }

        guard activeChatID == pending.chatID else {
            completePinRequest(
                requestID: envelope.requestID,
                error: NetworkError.serverMessage(
                    "Conversation changed before the pin update completed."
                )
            )
            return true
        }
        guard let index = turns.firstIndex(where: {
            $0.turnID == pending.turnID && $0.chatID == pending.chatID
        }) else {
            completePinRequest(
                requestID: envelope.requestID,
                error: NetworkError.serverMessage("The requested conversation turn is no longer available.")
            )
            return true
        }
        turns[index] = turns[index].settingPinned(
            apiTurn.isPinned ?? pending.isPinned
        )
        completePinRequest(requestID: envelope.requestID, error: nil)
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
            let response = try await receiveWebSocketMessageFromSocket()
            if !handlePinResponse(response, activeChatID: chatID) {
                deferredWebSocketMessages.append(response)
            }
        }
    }

    private func makeUpdatedUITurn(
        from apiTurn: APITurn,
        characterID: String
    ) -> Turn {
        let existingTurn = turns.first(where: {
            $0.turnID == apiTurn.turnKey.turnID && $0.chatID == apiTurn.turnKey.chatID
        })
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

    func hideCharacter(externalID: String) async -> Bool {
        guard !hidingCharacterIDs.contains(externalID) else {
            return false
        }

        hidingCharacterIDs.insert(externalID)
        hideErrorMessage = nil

        defer {
            hidingCharacterIDs.remove(externalID)
        }

        do {
            try await conversationService.hideCharacter(
                externalID: externalID
            )

            recentChats.removeAll {
                $0.characterID == externalID
            }
            return true
        } catch {
            hideErrorMessage = error.localizedDescription
            return false
        }
    }

    func loadRecentChats() async {
        isLoading = true
        errorMessage = nil

        do {
            recentChats =
                try await conversationService.loadRecentChats()

            print(
                "RECENT CONVERSATION COUNT:",
                recentChats.count
            )

            for conversation in recentChats {
                print(
                    "CONVERSATION:",
                    conversation.chatID,
                    "| CHARACTER:",
                    conversation.characterName,
                    "| STATE:",
                    conversation.state
                )
            }

        } catch {
            print(
                "LOAD RECENT CHATS ERROR:",
                error
            )

            errorMessage =
                error.localizedDescription
        }

        do {
            let characterIDs = [
                "IH7x6sc3Ksp3WDB0JMYGDySBeaCcpdbCO9pJDtW_AOM",
                "FTjqU9DJsFr-dD0kUcfUqbqOv6GvESsUpCNrwrUrouI"
            ]

            try await conversationService.loadChatPreviews(
                characterIDs: characterIDs
            )
        } catch {
            print(
                "CHAT PREVIEW TEST ERROR:",
                error
            )
        }

        isLoading = false
    }

    func disconnect() {
        failPendingPinRequests(
            error: NetworkError.serverMessage(
                "The WebSocket connection closed before the pin update completed."
            )
        )
        webSocketClient.disconnect()
    }
}
