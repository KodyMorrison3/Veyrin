//
//  ConversationService.swift
//  Character AI swift project
//
//  Created by Kody Morrison on 26/09/2026.
//

import Foundation

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

nonisolated struct CopyConversationResponse: Decodable, Sendable {
    let newChatID: String

    enum CodingKeys: String, CodingKey {
        case newChatID = "new_chat_id"
    }
}

struct ConversationCopySource {
    let chatID: String
    let characterID: String
    let endTurnID: String
}

@MainActor
struct ConversationService: Sendable {
    let authenticatedHTTPClient: AuthenticatedHTTPClient
    var cache: ResourceCache { authenticatedHTTPClient.conversationCache }
    var resources: ResourceCache { authenticatedHTTPClient.resources }

    init(authenticatedHTTPClient: AuthenticatedHTTPClient) {
        self.authenticatedHTTPClient = authenticatedHTTPClient
    }

    func loadChat(chatID: String, forceRefresh: Bool = false) async throws -> Chat {
        guard let url = URL(
            string: "https://neo.character.ai/chat/\(chatID)/?load_metadata=true"
        ) else {
            throw NetworkError.invalidURL
        }

        return try await resources.value(for: "chat:\(chatID)", ttl: 60, forceRefresh: forceRefresh, cost: { _ in 1024 }) {
            let response: ChatResponse = try await authenticatedHTTPClient.get(url)
            return response.chat
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

    /// Fetches chat history for a character from the HAR-observed list endpoint.
    /// This `GET /chats/` response contains `{ "chats": [...] }` without pagination metadata.
    func loadCharacterRecentChats(characterID: String) async throws -> [ChatPreview] {
        try await loadChatPreviews(characterIDs: [characterID])
    }

    /// Finds the latest usable turn from the character's most recent conversations.
    /// The confirmed `/copy` endpoint needs this source turn to create a model-specific branch.
    func loadLatestConversationCopySource(
        characterID: String
    ) async throws -> ConversationCopySource? {
        let previews = try await loadChatPreviews(characterIDs: [characterID])

        for preview in previews where preview.characterID == characterID {
            let previewSource = preview.previewTurns?.last(where: {
                !$0.candidates.isEmpty
            }).map { turn in
                ConversationCopySource(
                    chatID: preview.chatID,
                    characterID: characterID,
                    endTurnID: turn.turnKey.turnID
                )
            }

            // Previews request the latest two turns. Their newest usable turn
            // is sufficient for /copy; paginate history only when omitted.
            if let previewSource {
                return previewSource
            }

            let turns = try await loadAllTurns(chatID: preview.chatID)
            if let latestTurn = turns.last(where: { !$0.candidates.isEmpty }) {
                return ConversationCopySource(
                    chatID: preview.chatID,
                    characterID: characterID,
                    endTurnID: latestTurn.turnKey.turnID
                )
            }
        }

        return nil
    }

    func loadAllTurns(
        chatID: String,
        pinnedOnly: Bool = false
    ) async throws -> [APITurn] {
        var allTurns: [APITurn] = []
        var nextToken: String?
        var visitedTokens: Set<String> = []

        repeat {
            try Task.checkCancellation()
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


            allTurns.append(
                contentsOf: response.turns
            )

            nextToken = response.meta.nextToken
            if let nextToken, !visitedTokens.insert(nextToken).inserted {
                throw NetworkError.serverMessage("Conversation pagination returned a repeated cursor.")
            }

        } while nextToken != nil


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

        let response: AvailableModelsResponse = try await resources.value(for: "available-models", ttl: 300, cost: { $0.availableModels.count * 1024 + 512 }) {
            try await authenticatedHTTPClient.get(url, headers: [
                "Accept": "application/json", "Origin-ID": "web-next"
            ])
        }

        return response.availableModels.map { modelType in
            let configuration = response.configs[modelType]
            return ModelSelectionOption(
                modelType: modelType,
                name: configuration?.displayName ?? configuration?.name,
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
        resources.invalidate("recent-chats")
        resources.invalidate(prefix: "previews:")
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
        beginMutation(chatID: chatID)
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
        chatID: String,
        requestID: String = UUID().uuidString
    ) -> CharacterAICommand<CreateChatRequest> {
        let request = createChat(
            characterID: characterID,
            creatorID: creatorID,
            chatID: chatID
        )

        return CharacterAICommand(
            command: "create_chat",
            requestID: requestID,
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

    func loadRecentChats() async throws -> [ConversationSummary] {
        try await resources.value(for: "recent-chats", ttl: 30, cost: { $0.count * 2048 }) {
            try await fetchRecentChats()
        }
    }

    private func fetchRecentChats() async throws -> [ConversationSummary] {
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

        var seen: Set<String> = []
        let characterIDs = response.chats.map(\.characterID).filter { seen.insert($0).inserted }
        let previewGroups = try await previewGroups(characterIDs: characterIDs, tolerateFailures: true)
        let indices = Dictionary(summaries.enumerated().map { ($0.element.chatID, $0.offset) },
                                 uniquingKeysWith: { first, _ in first })
        for preview in previewGroups.flatMap({ $0 }) {
            guard let lastMessage = preview.lastMessage, let index = indices[preview.chatID] else { continue }
            let conversation = summaries[index]
            summaries[index] = ConversationSummary(
                id: conversation.id, chatID: conversation.chatID,
                characterID: conversation.characterID, characterName: conversation.characterName,
                characterAvatarURI: conversation.characterAvatarURI,
                lastUpdated: conversation.lastUpdated, state: conversation.state,
                lastMessage: lastMessage
            )
        }

        return summaries
    }
    
    func loadChatPreviews(
        characterIDs: [String]
    ) async throws -> [ChatPreview] {
        try await previewGroups(characterIDs: characterIDs, tolerateFailures: false).flatMap { $0 }
    }

    /// The accessible contract only verifies single-character requests. Keep
    /// that wire format and allow at most three independent requests at once.
    private func previewGroups(characterIDs: [String], tolerateFailures: Bool) async throws -> [[ChatPreview]] {
        var results = Array(repeating: [ChatPreview](), count: characterIDs.count)
        // Small waves avoid capturing an inout task group in a local enqueue
        // function (unsupported by the current region-isolation checker).
        for start in stride(from: 0, to: characterIDs.count, by: 3) {
            try Task.checkCancellation()
            try await withThrowingTaskGroup(of: (Int, [ChatPreview]).self) { group in
                for index in start..<min(start + 3, characterIDs.count) {
                    let characterID = characterIDs[index]
                    group.addTask {
                        do { return (index, try await loadPreview(characterID: characterID)) }
                        catch {
                            try Task.checkCancellation()
                            if tolerateFailures { return (index, []) }
                            throw error
                        }
                    }
                }
                for try await (index, previews) in group {
                    results[index] = previews
                }
            }
        }
        return results
    }

    private func loadPreview(characterID: String) async throws -> [ChatPreview] {
        try await resources.value(for: "previews:\(characterID)", ttl: 30, cost: { previews in
            previews.reduce(256) { total, preview in
                total + 512 + (preview.previewTurns ?? []).reduce(0) { $0 + $1.candidates.reduce(0) { $0 + $1.rawContent.utf8.count * 4 + 256 } }
            }
        }) {
            try await fetchPreview(characterID: characterID)
        }
    }

    private func fetchPreview(characterID: String) async throws -> [ChatPreview] {
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
            ),
            URLQueryItem(
                name: "include_turn_count",
                value: "false"
            ),
            URLQueryItem(
                name: "num_summaries",
                value: "0"
            ),
            URLQueryItem(
                name: "limit",
                value: "100"
            )
        ]

        guard let url = components?.url else {
            throw NetworkError.invalidURL
        }

        let response: ChatPreviewResponse =
            try await authenticatedHTTPClient.get(url)

        return response.chats
    }
    
    func makeCreateAndGenerateTurnMessage(
        characterID: String,
        userID: String,
        username: String,
        chatID: String,
        message: String,
        requestID: String = UUID().uuidString
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
            requestID: requestID,
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
        turnID: String,
        requestID: String = UUID().uuidString
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
            requestID: requestID,
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
        newContent: String,
        requestID: String = UUID().uuidString
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
            requestID: requestID,
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
