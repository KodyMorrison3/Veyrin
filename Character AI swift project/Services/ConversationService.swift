//
//  ConversationService.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 26/09/2026.
//

//
//  ConversationService.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 26/09/2026.
//

import Foundation

private struct HideCharacterRequest: Encodable {
    let characterExternalID: String

    enum CodingKeys: String, CodingKey {
        case characterExternalID = "character_external_id"
    }
}

private struct SetTurnPinRequest: Encodable {
    let chatType: String
    let turnKey: SetTurnPinKey
    let isPinned: Bool

    enum CodingKeys: String, CodingKey {
        case chatType = "chat_type"
        case turnKey = "turn_key"
        case isPinned = "is_pinned"
    }
}

private struct SetTurnPinKey: Encodable {
    let chatID: String
    let turnID: String

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case turnID = "turn_id"
    }
}

private struct RemoveTurnsRequest: Encodable {
    let turnIDs: [String]

    enum CodingKeys: String, CodingKey {
        case turnIDs = "turn_ids"
    }
}

private struct CopyConversationRequest: Encodable {
    let endTurnID: String
    let overrides: CopyConversationOverrides

    enum CodingKeys: String, CodingKey {
        case endTurnID = "end_turn_id"
        case overrides
    }
}

private struct CopyConversationOverrides: Encodable {
    let preferredModelType: String

    enum CodingKeys: String, CodingKey {
        case preferredModelType = "preferred_model_type"
    }
}

struct CopyConversationResponse: Decodable {
    let newChatID: String

    enum CodingKeys: String, CodingKey {
        case newChatID = "new_chat_id"
    }
}

struct ConversationService {
    private let httpClient: HTTPClient
    private let authenticatedHTTPClient: AuthenticatedHTTPClient

    init(
        httpClient: HTTPClient = HTTPClient(),
        authenticatedHTTPClient: AuthenticatedHTTPClient
    ) {
        self.httpClient = httpClient
        self.authenticatedHTTPClient = authenticatedHTTPClient
    }

    func loadChat(chatID: String) async throws -> Chat {
        guard let url = URL(
            string: "https://neo.character.ai/chat/\(chatID)/?load_metadata=true"
        ) else {
            throw NetworkError.invalidURL
        }

        // Try decoding ChatResponse container first as confirmed by the HAR: {"chat": {...}, "metadata": {...}}
        do {
            let container: ChatResponse = try await authenticatedHTTPClient.get(url)
            return container.chat
        } catch {
            return try await authenticatedHTTPClient.get(url)
        }
    }

    /// Fetches verified conversation facts (Memory) for the current chat from:
    /// `GET https://neo.character.ai/chat/{chatID}/conversation-facts/`
    func loadConversationFacts(chatID: String) async throws -> ConversationFactsResponse {
        guard let url = URL(
            string: "https://neo.character.ai/chat/\(chatID)/conversation-facts/"
        ) else {
            throw NetworkError.invalidURL
        }

        return try await authenticatedHTTPClient.get(url)
    }

    /// Fetches verified character voted status from:
    /// `GET https://neo.character.ai/character/v1/character_voted/{characterID}/voted`
    func loadCharacterVoted(characterID: String) async throws -> Bool {
        guard let url = URL(
            string: "https://neo.character.ai/character/v1/character_voted/\(characterID)/voted"
        ) else {
            throw NetworkError.invalidURL
        }

        let response: CharacterVotedResponse = try await authenticatedHTTPClient.get(url)
        return response.voted
    }

    /// Fetches verified recent chat history for a specific character from:
    /// `GET https://neo.character.ai/chats/recent/{characterID}`
    func loadCharacterRecentChats(characterID: String) async throws -> [RecentChat] {
        guard let url = URL(
            string: "https://neo.character.ai/chats/recent/\(characterID)"
        ) else {
            throw NetworkError.invalidURL
        }

        let response: RecentChatsResponse = try await authenticatedHTTPClient.get(url)
        return response.chats
    }

    func loadAllTurns(
        chatID: String,
        pinnedOnly: Bool = false
    ) async throws -> [APITurn] {
        var allTurns: [APITurn] = []
        var nextToken: String?

        repeat {
            var components = URLComponents(
                string: "https://neo.character.ai/turns/\(chatID)/"
            )

            var queryItems = [
                URLQueryItem(
                    name: "order_by_asc",
                    value: "true"
                )
            ]

            if pinnedOnly {
                queryItems.append(
                    URLQueryItem(
                        name: "pinned_only",
                        value: "true"
                    )
                )
            }

            if let nextToken {
                queryItems.append(
                    URLQueryItem(
                        name: "next_token",
                        value: nextToken
                    )
                )
            }

            components?.queryItems = queryItems

            guard let url = components?.url else {
                throw NetworkError.invalidURL
            }

            let response: TurnsResponse =
                try await authenticatedHTTPClient.get(url)

            print(
                "LOADED TURN PAGE:",
                response.turns.count
            )

            allTurns.append(
                contentsOf: response.turns
            )

            nextToken = response.meta.nextToken

            print(
                "NEXT TOKEN:",
                nextToken != nil ? "YES" : "NONE"
            )

        } while nextToken != nil

        print(
            "TOTAL TURNS LOADED:",
            allTurns.count
        )

        if let firstTurn = allTurns.first,
           let candidate = firstTurn.candidates.first {
            print(
                "FIRST TURN ID:",
                firstTurn.turnKey.turnID
            )

            print(
                "FIRST MESSAGE:",
                candidate.rawContent
            )
        }

        if let lastTurn = allTurns.last,
           let candidate = lastTurn.candidates.first {
            print(
                "LAST TURN ID:",
                lastTurn.turnKey.turnID
            )

            print(
                "LAST MESSAGE:",
                candidate.rawContent
            )
        }

        return allTurns
    }

    func loadPinnedTurnIDs(chatID: String) async throws -> Set<String> {
        Set(
            try await loadAllTurns(
                chatID: chatID,
                pinnedOnly: true
            ).map { $0.turnKey.turnID }
        )
    }

    func loadAvailableModels() async throws -> [ModelSelectionOption] {
        guard let url = URL(
            string: "https://neo.character.ai/get-available-models"
        ) else {
            throw NetworkError.invalidURL
        }

        let response: AvailableModelsResponse = try await authenticatedHTTPClient.get(
            url,
            headers: [
                "Accept": "application/json",
                "Origin-ID": "web-next"
            ]
        )

        return response.availableModels.map { modelType in
            let configuration = response.configs[modelType]
            return ModelSelectionOption(
                modelType: modelType,
                name: configuration?.name,
                isPlusOnly: configuration?.isPlusOnly ?? false,
                isFeatured: configuration?.isFeatured ?? false,
                isBeta: configuration?.isBeta ?? false,
                isLegacy: configuration?.isLegacy ?? false,
                hasModelSteering: configuration?.hasModelSteering ?? false
            )
        }
    }

    func startNewConversation(
        chatID: String,
        endTurnID: String,
        modelType: String
    ) async throws -> String {
        let pathCharacters = CharacterSet.urlPathAllowed.subtracting(
            CharacterSet(charactersIn: "/?#")
        )
        let encodedChatID = chatID.addingPercentEncoding(
            withAllowedCharacters: pathCharacters
        ) ?? chatID

        guard let url = URL(
            string: "https://neo.character.ai/chat/\(encodedChatID)/copy"
        ) else {
            throw NetworkError.invalidURL
        }

        let request = CopyConversationRequest(
            endTurnID: endTurnID,
            overrides: CopyConversationOverrides(
                preferredModelType: modelType
            )
        )
        let response: CopyConversationResponse = try await authenticatedHTTPClient.post(
            url,
            body: request,
            headers: [
                "Origin-ID": "web-next",
                "Request-ID": UUID().uuidString.lowercased()
            ]
        )
        return response.newChatID
    }

    func turnIDsToRemove(
        from turns: [Turn],
        startingAt turnID: String,
        chatID: String
    ) throws -> [String] {
        guard let targetIndex = turns.firstIndex(where: {
            $0.turnID == turnID && $0.chatID == chatID
        }) else {
            throw NetworkError.serverMessage("Conversation turn not found.")
        }

        // The selected turn is the rewind boundary and must remain. The API
        // removes each successor, supplied newest-first.
        let turnsToRemove = Array(turns.dropFirst(targetIndex + 1))
        guard turnsToRemove.allSatisfy({ $0.chatID == chatID }) else {
            throw NetworkError.serverMessage(
                "The selected turns do not belong to this conversation."
            )
        }

        return turnsToRemove.reversed().map(\.turnID)
    }

    func removeTurns(chatID: String, turnIDs: [String]) async throws {
        guard !turnIDs.isEmpty else {
            throw NetworkError.serverMessage("No conversation turns were selected to rewind.")
        }

        let pathCharacters = CharacterSet.urlPathAllowed.subtracting(
            CharacterSet(charactersIn: "/?#")
        )
        let encodedChatID = chatID.addingPercentEncoding(
            withAllowedCharacters: pathCharacters
        ) ?? chatID

        guard let url = URL(
            string: "https://neo.character.ai/turns/\(encodedChatID)/remove"
        ) else {
            throw NetworkError.invalidURL
        }

        let body = try JSONEncoder().encode(
            RemoveTurnsRequest(turnIDs: turnIDs)
        )
        try await authenticatedHTTPClient.send(
            url,
            method: "POST",
            body: body,
            headers: [
                "Accept": "application/json",
                "Origin-ID": "web-next",
                "Request-ID": UUID().uuidString.lowercased()
            ]
        )
    }

    func makeUITurn(
        from apiTurn: APITurn,
        characterID: String,
        isPinned: Bool? = nil
    ) -> Turn {
        Turn(
            turnID: apiTurn.turnKey.turnID,
            chatID: apiTurn.turnKey.chatID,
            authorID: apiTurn.author.authorID,
            authorName: apiTurn.author.name,
            isHuman: apiTurn.author.authorID != characterID,
            candidates: apiTurn.candidates.map { candidate in
                Candidate(
                    candidateId: candidate.candidateID,
                    rawContent: candidate.rawContent,
                    isFinal: candidate.isFinal,
                    modelType: "MODEL_TYPE_UNSPECIFIED"
                )
            },
            primaryCandidateID: apiTurn.primaryCandidateID,
            isPinned: isPinned ?? apiTurn.isPinned ?? false
        )
    }

    func makeUITurns(
        from response: TurnsResponse,
        characterID: String
    ) -> [Turn] {
        response.turns.map { apiTurn in
            makeUITurn(
                from: apiTurn,
                characterID: characterID
            )
        }
    }

    func createChat(
        characterID: String,
        creatorID: String,
        chatID: String
    ) -> CreateChatRequest {
        let chat = NewChat(
            chatID: chatID,
            creatorID: creatorID,
            visibility: "VISIBILITY_PRIVATE",
            characterID: characterID,
            type: "TYPE_ONE_ON_ONE"
        )

        return CreateChatRequest(
            chatType: "TYPE_ONE_ON_ONE",
            chat: chat,
            withGreeting: true,
            withPreGeneratedHistory: false
        )
    }

    func makeSetTurnPinMessage(
        chatID: String,
        turnID: String,
        isPinned: Bool
    ) throws -> (requestID: String, message: String) {
        let requestID = UUID().uuidString.lowercased()
        let request = SetTurnPinRequest(
            chatType: "TYPE_ONE_ON_ONE",
            turnKey: SetTurnPinKey(
                chatID: chatID,
                turnID: turnID
            ),
            isPinned: isPinned
        )
        let command = CharacterAICommand(
            command: "set_turn_pin",
            requestID: requestID,
            payload: request,
            originID: "web-next"
        )
        let data = try JSONEncoder().encode(command)
        guard let message = String(data: data, encoding: .utf8) else {
            throw NetworkError.invalidResponse
        }
        return (requestID, message)
    }

    func makeCreateChatCommand(
        characterID: String,
        creatorID: String,
        chatID: String
    ) -> CharacterAICommand<CreateChatRequest> {
        let request = createChat(
            characterID: characterID,
            creatorID: creatorID,
            chatID: chatID
        )

        return CharacterAICommand(
            command: "create_chat",
            requestID: UUID().uuidString,
            payload: request,
            originID: "web-next"
        )
    }

    func makeCreateChatMessage(
        characterID: String,
        creatorID: String,
        chatID: String
    ) throws -> String {
        let command = makeCreateChatCommand(
            characterID: characterID,
            creatorID: creatorID,
            chatID: chatID
        )

        let encoder = JSONEncoder()

        let data = try encoder.encode(command)

        guard let message = String(
            data: data,
            encoding: .utf8
        ) else {
            throw NetworkError.invalidResponse
        }

        return message
    }

    func hideCharacter(externalID: String) async throws {
        let pathCharacters = CharacterSet.urlPathAllowed.subtracting(
            CharacterSet(charactersIn: "/?#")
        )
        let encodedID = externalID.addingPercentEncoding(
            withAllowedCharacters: pathCharacters
        ) ?? externalID

        guard let primaryURL = URL(
            string: "https://neo.character.ai/chats/recent/\(encodedID)/hide"
        ), let fallbackURL = URL(
            string: "https://plus.character.ai/chat/history/hide/"
        ) else {
            throw NetworkError.invalidURL
        }

        do {
            try await authenticatedHTTPClient.send(
                primaryURL,
                method: "PUT"
            )
        } catch {
            let body = try JSONEncoder().encode(
                HideCharacterRequest(characterExternalID: externalID)
            )

            try await authenticatedHTTPClient.send(
                fallbackURL,
                method: "POST",
                body: body
            )
        }
    }

    func loadRecentChats() async throws -> [ConversationSummary] {
        guard let url = URL(
            string: "https://neo.character.ai/chats/recent/?include_restricted=true"
        ) else {
            throw NetworkError.invalidURL
        }

        let response: RecentChatsResponse =
            try await authenticatedHTTPClient.get(url)

        var summaries = response.chats.map { chat in
            ConversationSummary(
                id: chat.chatID,
                chatID: chat.chatID,
                characterID: chat.characterID,
                characterName: chat.characterName,
                characterAvatarURI: chat.characterAvatarURI,
                lastUpdated: chat.createTime,
                state: chat.state,
                lastMessage: nil
            )
        }

        let characterIDs = Array(
            Set(
                response.chats.map {
                    $0.characterID
                }
            )
        )

        for characterID in characterIDs {
            do {
                let previews = try await loadChatPreviews(
                    characterIDs: [characterID]
                )

                for preview in previews {
                    guard let lastMessage = preview.lastMessage else {
                        continue
                    }

                    if let index = summaries.firstIndex(
                        where: {
                            $0.chatID == preview.chatID
                        }
                    ) {
                        let conversation = summaries[index]

                        summaries[index] = ConversationSummary(
                            id: conversation.id,
                            chatID: conversation.chatID,
                            characterID: conversation.characterID,
                            characterName: conversation.characterName,
                            characterAvatarURI: conversation.characterAvatarURI,
                            lastUpdated: conversation.lastUpdated,
                            state: conversation.state,
                            lastMessage: lastMessage
                        )
                    }
                }
            } catch {
                print(
                    "CHAT PREVIEW LOAD ERROR:",
                    characterID,
                    error
                )
            }
        }

        return summaries
    }
    
    func loadChatPreviews(
        characterIDs: [String]
    ) async throws -> [ChatPreview] {
        var allPreviews: [ChatPreview] = []

        for characterID in characterIDs {
            var components = URLComponents(
                string: "https://neo.character.ai/chats/"
            )

            components?.queryItems = [
                URLQueryItem(
                    name: "character_ids",
                    value: characterID
                ),
                URLQueryItem(
                    name: "num_preview_turns",
                    value: "2"
                )
            ]

            guard let url = components?.url else {
                throw NetworkError.invalidURL
            }

            print("CHAT PREVIEW URL:")
            print(url.absoluteString)

            let response: ChatPreviewResponse =
                try await authenticatedHTTPClient.get(url)

            allPreviews.append(contentsOf: response.chats)
        }

        return allPreviews
    }
    
    func makeCreateAndGenerateTurnMessage(
        characterID: String,
        userID: String,
        username: String,
        chatID: String,
        message: String
    ) throws -> String {
        let turnID = UUID()
            .uuidString
            .lowercased()

        let candidateID = UUID()
            .uuidString
            .lowercased()

        let turn = NewTurn(
            turnKey: NewTurnKey(
                turnID: turnID,
                chatID: chatID
            ),
            author: NewTurnAuthor(
                authorID: userID,
                isHuman: true,
                name: username
            ),
            candidates: [
                NewCandidate(
                    candidateID: candidateID,
                    rawContent: message
                )
            ],
            primaryCandidateID: candidateID
        )

        let request = CreateAndGenerateTurnRequest(
            chatType: "TYPE_ONE_ON_ONE",
            numCandidates: 1,
            ttsEnabled: false,
            selectedLanguage: "",
            characterID: characterID,
            userName: username,
            turn: turn,
            previousAnnotations: [:],
            generateComparison: false
        )

        let command = CharacterAICommand(
            command: "create_and_generate_turn",
            requestID: UUID().uuidString,
            payload: request,
            originID: "web-next"
        )

        let data = try JSONEncoder()
            .encode(command)

        guard let message = String(
            data: data,
            encoding: .utf8
        ) else {
            throw NetworkError.invalidResponse
        }

        return message
    }
    
    func makeGenerateTurnCandidateMessage(
        characterID: String,
        username: String,
        chatID: String,
        turnID: String
    ) throws -> String {
        let request = GenerateTurnCandidateRequest(
            chatType: "TYPE_ONE_ON_ONE",
            ttsEnabled: false,
            selectedLanguage: "",
            characterID: characterID,
            userName: username,
            turnKey: GenerateTurnKey(
                turnID: turnID,
                chatID: chatID
            ),
            previousAnnotations: GenerateTurnAnnotations()
        )

        let command = CharacterAICommand(
            command: "generate_turn_candidate",
            requestID: UUID().uuidString,
            payload: request,
            originID: "web-next"
        )

        let data = try JSONEncoder()
            .encode(command)

        guard let message = String(
            data: data,
            encoding: .utf8
        ) else {
            throw NetworkError.invalidResponse
        }

        return message
    }
    
    func makeEditTurnCandidateMessage(
        chatID: String,
        turnID: String,
        currentCandidateID: String,
        newContent: String
    ) throws -> String {
        let request = EditTurnCandidateRequest(
            chatType: "TYPE_ONE_ON_ONE",
            turnKey: EditTurnKey(
                chatID: chatID,
                turnID: turnID
            ),
            currentCandidateID: currentCandidateID,
            newCandidateRawContent: newContent
        )

        let command = CharacterAICommand(
            command: "edit_turn_candidate",
            requestID: UUID().uuidString,
            payload: request,
            originID: "web-next"
        )

        let data = try JSONEncoder()
            .encode(command)

        guard let message = String(
            data: data,
            encoding: .utf8
        ) else {
            throw NetworkError.invalidResponse
        }

        return message
    }
    
    func makeUpdatePrimaryCandidateMessage(
        chatID: String,
        turnID: String,
        candidateID: String
    ) throws -> String {
        let request = UpdatePrimaryCandidateRequest(
            chatType: "TYPE_ONE_ON_ONE",
            candidateID: candidateID,
            turnKey: UpdatePrimaryCandidateTurnKey(
                chatID: chatID,
                turnID: turnID
            )
        )

        let command = CharacterAICommand(
            command: "update_primary_candidate",
            requestID: UUID().uuidString,
            payload: request,
            originID: "web-next"
        )

        let data = try JSONEncoder()
            .encode(command)

        guard let message = String(
            data: data,
            encoding: .utf8
        ) else {
            throw NetworkError.invalidResponse
        }

        return message
    }
}
