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
    @Published var isLoading = false
    @Published var isGenerating = false
    @Published var errorMessage: String?

    private let authStore: AuthStore
    private let conversationService: ConversationService
    private let webSocketClient = WebSocketClient()

    init(authStore: AuthStore) {
        self.authStore = authStore

        self.conversationService = ConversationService(
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

            try await webSocketClient.connect(
                sessionToken: authSession.sessionToken
            )

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
        guard let character else {
            return
        }

        print("LOADING CHAT HISTORY")
        print("CHAT ID:", chatID)
        print("CHARACTER ID:", character.externalID)

        isLoading = true
        errorMessage = nil
        turns = []

        do {
            let apiTurns =
                try await conversationService.loadAllTurns(
                    chatID: chatID
                )

            print(
                "TOTAL TURNS LOADED:",
                apiTurns.count
            )

            turns = apiTurns.map { apiTurn in
                conversationService.makeUITurn(
                    from: apiTurn,
                    characterID: character.externalID
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
            try await webSocketClient.connect(
                sessionToken: authSession.sessionToken
            )

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
                    try await webSocketClient.receive()

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

                let uiTurn =
                    conversationService.makeUITurn(
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

        } catch {
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
            try await webSocketClient.connect(
                sessionToken: authSession.sessionToken
            )

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
                    try await webSocketClient.receive()

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

                guard updatedTurn.turnKey.chatID == chatID else {
                    continue
                }

                guard updatedTurn.turnKey.turnID == turnID else {
                    continue
                }

                let uiTurn =
                    conversationService.makeUITurn(
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
        } catch {
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
            try await webSocketClient.connect(
                sessionToken: authSession.sessionToken
            )

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
                    try await webSocketClient.receive()

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

                let uiTurn =
                    conversationService.makeUITurn(
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
        } catch {
            print(
                "EDIT MESSAGE ERROR:",
                error
            )
            errorMessage =
                error.localizedDescription
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
        webSocketClient.disconnect()
    }
}
