import Foundation

/// Stub WebSocket transport with the real transport's reconnect lifecycle:
/// `disconnect()` ends the current frame stream (the router's receive task is
/// torn down with it) and the next `connect` arms a fresh one, exactly like a
/// replacement URLSessionWebSocketTask. `loadRealTurns` disconnects before
/// first use, so a one-shot stream cannot carry a full check run.
private actor ConversationSocket: WebSocketTransport {
    private struct Link {
        let output: AsyncThrowingStream<Data, Error>.Continuation
        var iterator: AsyncThrowingStream<Data, Error>.Iterator
        let streamID = UUID()
    }

    private var link: Link?
    private var pin = false
    private var pendingGeneration: String?
    private var chatID = "chat"
    private var turnID = "turn"
    private var creationAcknowledgementDelay: Duration = .zero

    func setCreationAcknowledgementDelay(_ delay: Duration) {
        creationAcknowledgementDelay = delay
    }

    init() {
        let (stream, output) = AsyncThrowingStream<Data, Error>.makeStream()
        link = Link(output: output, iterator: stream.makeAsyncIterator())
    }

    private func arm() {
        let (stream, output) = AsyncThrowingStream<Data, Error>.makeStream()
        link = Link(output: output, iterator: stream.makeAsyncIterator())
    }

    func connect(sessionToken: String) {
        if link == nil { arm() }
    }

    func disconnect() {
        link?.output.finish()
        link = nil
    }

    func receive() async throws -> Data {
        guard var current = link else { throw URLError(.networkConnectionLost) }
        guard let frame = try await current.iterator.next(isolation: self) else { throw URLError(.networkConnectionLost) }
        if link?.streamID == current.streamID { link = current }
        return frame
    }

    func frame(_ requestID: String, text: String, final: Bool, candidateID: String = "candidate") {
        let json = "{\"command\":\"update_turn\",\"request_id\":\"\(requestID)\",\"turn\":{\"turn_key\":{\"turn_id\":\"\(turnID)\",\"chat_id\":\"\(chatID)\"},\"state\":\"STATE_OK\",\"author\":{\"author_id\":\"character\",\"name\":\"Character\"},\"candidates\":[{\"candidate_id\":\"\(candidateID)\",\"raw_content\":\"\(text)\",\"is_final\":\(final)}],\"primary_candidate_id\":\"\(candidateID)\",\"is_pinned\":\(pin)}}"
        yield(Data(json.utf8))
    }

    func send(_ message: String) async throws {
        let envelope = try JSONSerialization.jsonObject(with: Data(message.utf8)) as! [String: Any]
        let command = envelope["command"] as! String
        let requestID = envelope["request_id"] as! String
        let payload = envelope["payload"] as! [String: Any]
        if command == "create_chat" {
            let chat = payload["chat"] as! [String: Any]
            precondition(chat["creator_id"] as? String == "user", "Fresh create_chat must use the authenticated account ID")
            precondition(chat["character_id"] as? String == "character", "Fresh create_chat must use the selected character ID")
            precondition(chat["preferred_model_type"] == nil, "Fresh create_chat must use the server's account default")
            let returnedChatID = chat["chat_id"] as! String
            let returnedChat = """
            {"chat_id":"\(returnedChatID)","creator_id":"user","visibility":"VISIBILITY_PRIVATE","character_id":"character","type":"TYPE_ONE_ON_ONE","preferred_model_type":"MODEL_TYPE_DEEP_SYNTH"}
            """
            if creationAcknowledgementDelay > .zero {
                try await Task.sleep(for: creationAcknowledgementDelay)
            }
            yield(Data("{\"command\":\"create_chat_response\",\"request_id\":\"\(requestID)\",\"chat\":\(returnedChat)}".utf8))
        } else if command == "set_turn_pin" {
            pin = payload["is_pinned"] as! Bool
            frame(requestID, text: "Pin ACK must not overwrite streamed content", final: true)
        } else if command == "create_and_generate_turn" {
            pendingGeneration = requestID
            frame(requestID, text: "Partial", final: false)
        } else if command == "generate_turn_candidate" {
            frame(requestID, text: "Regenerated", final: true, candidateID: "regenerated")
        } else if command == "edit_turn_candidate" {
            frame(requestID, text: payload["new_candidate_raw_content"] as! String, final: true, candidateID: "edited")
        }
    }

    func finishGeneration() {
        if let requestID = pendingGeneration { frame(requestID, text: "Final streamed response", final: true) }
    }

    private func yield(_ data: Data) { link?.output.yield(data) }
}

@MainActor
func runConversationChecks() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubHTTP.self]
    configuration.urlCache = nil
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let auth = AuthStore(session: AuthSession(sessionToken: "synthetic", userID: "user", username: "name"))
    let service = ConversationService(authenticatedHTTPClient: AuthenticatedHTTPClient(session: session, authStore: auth))
    let socket = ConversationSocket()
    let vm = ChatViewModel(authStore: auth, conversationService: service, webSocketRouter: WebSocketRouter(client: socket))
    vm.character = Character(externalID: "character", title: "", name: "Character", visibility: "PUBLIC", copyable: true, greeting: "Hi", description: "", avatarFileName: "avatar")
    await vm.loadRealTurns(chatID: "chat")
    await socket.setCreationAcknowledgementDelay(.milliseconds(100))
    let createTask = Task { await vm.createRealChat(characterID: "character") }
    try await Task.sleep(for: .milliseconds(10))
    precondition(vm.isLoading, "Create-chat shows loading while awaiting server acknowledgement")
    let created = await createTask.value
    precondition(created != nil && vm.errorMessage == nil)
    precondition(!vm.isLoading, "Create-chat immediately releases loading after acknowledgement")
    let emptyCharacterCreated = await vm.createRealChat(characterID: "  ")
    precondition(emptyCharacterCreated == nil, "A missing character ID is rejected before create_chat")
    precondition(vm.errorMessage?.contains("missing its Character.AI ID") == true)
    let missingAccountViewModel = ChatViewModel(
        authStore: AuthStore(session: AuthSession(sessionToken: "synthetic", userID: "  ", username: "name")),
        conversationService: service,
        webSocketRouter: WebSocketRouter(client: ConversationSocket())
    )
    let missingAccountCreated = await missingAccountViewModel.createRealChat(characterID: "character")
    precondition(missingAccountCreated == nil, "A missing account ID is rejected before create_chat")
    precondition(missingAccountViewModel.errorMessage?.contains("account ID is unavailable") == true)
    precondition(vm.chat?.preferredModelType == "MODEL_TYPE_DEEP_SYNTH", "Fresh chat keeps the model returned by create_chat_response")
    let identity = vm.turnStates[0]
    let send = Task { await vm.sendMessage("Hello", chatID: "chat") }
    for _ in 0..<100 {
        if vm.lastTurn?.candidates.first?.rawContent == "Partial" { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    precondition(vm.isGenerating && vm.lastTurn?.candidates.first?.rawContent == "Partial")
    await vm.togglePin(turnID: "turn", chatID: "chat")
    precondition(vm.lastTurn?.isPinned == true && vm.lastTurn?.candidates.first?.rawContent == "Partial")
    await socket.finishGeneration()
    await send.value
    precondition(!vm.isGenerating && vm.lastTurn?.candidates.first?.rawContent == "Final streamed response")
    precondition(vm.lastTurn?.isPinned == true && vm.turnStates[0] === identity)
    await vm.regenerateResponse(turnID: "turn", chatID: "chat")
    precondition(vm.lastTurn?.primaryCandidateID == "regenerated")
    await vm.editMessage(turnID: "turn", chatID: "chat", candidateID: "regenerated", newContent: "Edited")
    precondition(vm.lastTurn?.candidates.first?.rawContent == "Edited")
    await vm.togglePin(turnID: "turn", chatID: "chat")
    precondition(vm.lastTurn?.isPinned == false && vm.pinningTurnIDs.isEmpty)
    precondition(vm.errorMessage == nil && vm.pinErrorMessage == nil)
    vm.disconnect()
    print("Create/send/coalesced streaming, stable TurnState identity, interleaved pin/unpin, regenerate and edit checks passed")
}
