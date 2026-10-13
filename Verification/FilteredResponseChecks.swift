import Foundation

/// HAR-derived filtered-response regression suite (sanitized: no request
/// bodies, tokens, or captured message text — structure mirrors the wire only).
///
/// Protocol facts under test, all verified in captured traffic:
/// 1. A censored AI response is a normal final turn whose candidate carries
///    `candidates[].safety_truncated: true`. The web client keeps the turn in
///    place and renders a filter notice under it.
/// 2. Control frames (`{"command": "ok"}` replies to `update_primary_candidate`,
///    captured in several conversations) omit `request_id`; they must not
///    abort routing.
/// 3. Streaming/filtered frames omit candidate content, candidate id, turn
///    state, or the primary id; the web client tolerates those omissions.
///
/// Key invariant under test: `filtered generation != conversation deletion`.
private actor FilteredSocket: WebSocketTransport {
    private struct Link {
        let output: AsyncThrowingStream<Data, Error>.Continuation
        var iterator: AsyncThrowingStream<Data, Error>.Iterator

        /// One link per armed generation of the frame stream; a connect after
        /// a disconnect produces a new ID.
        let streamID = UUID()
    }

    private var link: Link?
    var generationFails = false
    var malformNextGeneration = false
    private var pendingGenerations: [String] = []

    func setGenerationFails() { generationFails = true }
    func setMalformNextGeneration() { malformNextGeneration = true }

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
    private func yield(_ data: Data) { link?.output.yield(data) }

    func emit(_ json: String) {
        yield(Data(json.utf8))
    }

    func emitMalformed() {
        yield(Data("{\"command\":\"update_turn\",".utf8))
    }

    func streamingFrame(requestID: String) {
        emit("""
        {"command":"update_turn","request_id":"\(requestID)","turn":{"turn_key":{"turn_id":"turn-\(requestID.prefix(8))","chat_id":"chat"},"state":"STATE_OK","author":{"author_id":"character","name":"Character"},"candidates":[{"candidate_id":"candidate-\(requestID.prefix(8))","raw_content":"Partial"}],"primary_candidate_id":"candidate-\(requestID.prefix(8))"}}
        """)
    }

    func finalFrame(requestID: String, text: String) {
        emit("""
        {"command":"update_turn","request_id":"\(requestID)","turn":{"turn_key":{"turn_id":"turn-\(requestID.prefix(8))","chat_id":"chat"},"create_time":"2026-10-01T00:00:00.000000Z","last_update_time":"2026-10-01T00:00:00.000000Z","state":"STATE_OK","author":{"author_id":"character","name":"Character"},"candidates":[{"candidate_id":"candidate-\(requestID.prefix(8))","create_time":"2026-10-01T00:00:00.000000Z","raw_content":"\(text)","is_final":true,"model_type":"MODEL_TYPE_DEFAULT"}],"primary_candidate_id":"candidate-\(requestID.prefix(8))"}}
        """)
    }

    /// Captured censored shape: a candidate carrying only `safety_truncated`
    /// and `is_final` — with the omissions captured alongside it (no candidate
    /// content, no candidate id, no turn create/state context, empty primary).
    func emitFilteredFrame(requestID: String, turnID: String) {
        emit("""
        {"command":"update_turn","request_id":"\(requestID)","turn":{"turn_key":{"turn_id":"\(turnID)","chat_id":"chat"},"state":"STATE_OK","author":{"author_id":"character","name":"Character"},"candidates":[{"safety_truncated":true,"is_final":true}],"primary_candidate_id":""}}
        """)
    }

    func send(_ message: String) throws {
        guard let envelope = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any],
              let command = envelope["command"] as? String,
              let requestID = envelope["request_id"] as? String else {
            return
        }
        switch command {
        case "create_chat":
            emit("{\"command\":\"create_chat\",\"request_id\":\"\(requestID)\"}")
        case "create_and_generate_turn":
            pendingGenerations.append(requestID)
            if generationFails {
                emit("{\"command\":\"neo_error\",\"request_id\":\"\(requestID)\",\"comment\":\"Generation backend unavailable\"}")
            } else if malformNextGeneration {
                malformNextGeneration = false
                emitMalformed()
            } else {
                streamingFrame(requestID: requestID)
            }
        default:
            break
        }
    }

    func finishLastGenerationWithFiltered(turnID: String) {
        guard let requestID = pendingGenerations.popLast() else { return }
        emitFilteredFrame(requestID: requestID, turnID: turnID)
    }

    func finishLastGenerationWithFinal(text: String) {
        guard let requestID = pendingGenerations.popLast() else { return }
        finalFrame(requestID: requestID, text: text)
    }
}

@MainActor
private func pollForContent(_ content: String, from vm: ChatViewModel) async throws -> Bool {
    for _ in 0..<200 {
        if vm.lastTurn?.candidates.first?.rawContent == content { return true }
        try await Task.sleep(for: .milliseconds(5))
    }
    return false
}

@MainActor
private func pollForGenerating(_ vm: ChatViewModel) async throws -> Bool {
    for _ in 0..<200 {
        if vm.isGenerating { return true }
        try await Task.sleep(for: .milliseconds(5))
    }
    return false
}

@MainActor
private func makeHarness(session: URLSession) -> (AuthStore, ConversationService) {
    let auth = AuthStore(session: AuthSession(sessionToken: "synthetic", userID: "user", username: "name"))
    let service = ConversationService(authenticatedHTTPClient: AuthenticatedHTTPClient(session: session, authStore: auth))
    return (auth, service)
}

@MainActor
private func seedCharacter(_ vm: ChatViewModel) {
    vm.character = Character(externalID: "character", title: "", name: "Character", visibility: "PUBLIC", copyable: true, greeting: "Hi", description: "", avatarFileName: "avatar")
}

@MainActor
func runFilteredResponseChecks() async throws {
    // ---- Decode-level scenarios: persisted filtered turn, request_id-less
    // control frame, degenerate frame, and a normal turn (HAR-shaped fixtures).
    let filteredTurnFixture = """
    {"turns":[{"turn_key":{"turn_id":"turn-filtered","chat_id":"chat"},"create_time":"2026-09-09T08:30:00.000000Z","last_update_time":"2026-09-09T08:30:00.000000Z","state":"STATE_OK","author":{"author_id":"character","name":"Character"},"candidates":[{"candidate_id":"candidate-filtered","create_time":"2026-09-09T08:30:00.000000Z","raw_content":"partial reply","is_final":true,"model_type":"MODEL_TYPE_DEFAULT","safety_truncated":true}],"primary_candidate_id":"candidate-filtered"}],"meta":{"next_token":null}}
    """
    let page = try JSONDecoder().decode(TurnsResponse.self, from: Data(filteredTurnFixture.utf8))
    precondition(page.turns.first?.candidates.first?.isSafetyTruncated == true, "Persisted safety_truncated must decode")
    precondition(page.turns.first?.state == "STATE_OK", "Filtered turn keeps its normal turn state")

    let controlFrame = try JSONDecoder().decode(WebSocketTurnResponse.self, from: Data("{\"command\":\"ok\"}".utf8))
    precondition(controlFrame.requestID == nil, "Captured request_id-less control frames must decode")

    let degenerateFrame = try JSONDecoder().decode(WebSocketTurnResponse.self, from: Data("""
    {"command":"update_turn","request_id":"req","turn":{"turn_key":{"turn_id":"turn-filtered","chat_id":"chat"},"author":{"author_id":"character"},"candidates":[{"safety_truncated":true,"is_final":true}],"primary_candidate_id":""}}
    """.utf8))
    precondition(degenerateFrame.turn?.candidates.first?.isSafetyTruncated == true, "Degenerate filtered frame must decode")
    precondition(degenerateFrame.turn?.candidates.first?.isFinal == true, "Degenerate filtered frame keeps is_final")

    let normalTurn = try JSONDecoder().decode(WebSocketTurnResponse.self, from: Data("""
    {"command":"update_turn","request_id":"req","turn":{"turn_key":{"turn_id":"turn","chat_id":"chat"},"state":"STATE_OK","author":{"author_id":"character","name":"Character"},"candidates":[{"candidate_id":"candidate","raw_content":"Normal","is_final":true}],"primary_candidate_id":"candidate"}}
    """.utf8))
    precondition(normalTurn.turn?.candidates.first?.isSafetyTruncated == nil, "Normal turns carry no filter marker")

    // ---- Runtime scenarios over a live router + stub transport.
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubHTTP.self]
    configuration.urlCache = nil
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }

    // Scenarios 2+3: existing multi-turn conversation; filtered generation in
    // the captured degraded shape. Invariant: conversation preserved.
    StubHTTP.state.withLock { state in
        state.counts = [:]
        state.status = 200
        state.directChat = false
        state.missingPins = true
    }
    let (auth, service) = makeHarness(session: session)
    let socket = FilteredSocket()
    let vm = ChatViewModel(authStore: auth, conversationService: service, webSocketRouter: WebSocketRouter(client: socket))
    seedCharacter(vm)
    await vm.loadRealTurns(chatID: "chat")
    let existingTurnCount = vm.turnStates.count
    precondition(existingTurnCount > 0, "StubHTTP base history must load")
    let existingState = vm.turnStates[0]

    let filteredRequest = Task { await vm.sendMessage("hello again", chatID: "chat") }
    let generationStarted = try await pollForGenerating(vm)
    precondition(generationStarted, "Generation must start")
    let partialAppeared = try await pollForContent("Partial", from: vm)
    precondition(partialAppeared, "Streaming partial must appear before the filter frame")
    await socket.finishLastGenerationWithFiltered(turnID: "turn-filtered")
    await filteredRequest.value
    precondition(vm.errorMessage == nil, "Filtered generation must not surface an error banner: \(vm.errorMessage ?? "")")
    precondition(vm.turnStates.count == existingTurnCount + 2,
                 "User turn and filtered turn must append; conversation preserved")
    precondition(vm.turnStates[0] === existingState, "Existing TurnState identity preserved through the filtered generation")
    precondition(vm.turnStates[0].turn.turnID == existingState.turn.turnID, "Existing turn untouched by the filtered generation")
    let filteredTurn = vm.lastTurn
    precondition(filteredTurn?.candidates.first?.isFiltered == true, "Filtered turn must carry the safety_truncated marker")
    precondition(!vm.isGenerating, "A censored candidate ends generation (HAR: safety_truncated terminates)")

    // Scenario 4: continue the conversation after a filtered response.
    let continueRequest = Task { await vm.sendMessage("one more", chatID: "chat") }
    let continuationStarted = try await pollForGenerating(vm)
    precondition(continuationStarted, "User must be able to send another message after a filtered response")
    await socket.finishLastGenerationWithFinal(text: "Continued")
    await continueRequest.value
    precondition(vm.errorMessage == nil, "Continuation after a filtered response must succeed")
    precondition(vm.turnStates.count == existingTurnCount + 3, "Continuation turn appended after the filtered turn")

    // Scenario 7: reload after a filtered response must not fail or wipe.
    await vm.loadRealTurns(chatID: "chat")
    precondition(vm.errorMessage == nil && vm.hasTurns && vm.turnStates[0] === existingState,
                 "Reload after a filtered response keeps the conversation and stable identity")
    precondition(vm.turnStates.contains { $0.turn.candidates.contains { $0.isFiltered } },
                 "Reload must reproduce the filtered turn with its safety_truncated marker")
    vm.disconnect()

    // Narrowed empty-history guard. A complete but empty server history keeps the
    // turns on screen only while a censored generation in this chat is unconfirmed.
    StubHTTP.state.withLock { $0.emptyTurns = false }
    // Scenario 1: normal empty complete history (no filtered generation) still replaces.
    let (normAuth, normService) = makeHarness(session: session)
    let normVM = ChatViewModel(authStore: normAuth, conversationService: normService, webSocketRouter: WebSocketRouter(client: FilteredSocket()))
    seedCharacter(normVM)
    await normVM.loadRealTurns(chatID: "chat")
    precondition(normVM.turnStates.count > 0, "Base history must load before the empty-history check")
    normService.invalidateHistory(chatID: "chat")
    StubHTTP.state.withLock { $0.emptyTurns = true }
    await normVM.loadRealTurns(chatID: "chat", forceRefresh: true)
    precondition(normVM.turnStates.isEmpty, "A normal complete empty history still replaces the view")
    normVM.disconnect()

    // Scenario 2: after a censored generation, an empty complete server history must
    // not erase the conversation until the filtered turn is server-confirmed.
    StubHTTP.state.withLock { $0.emptyTurns = false }
    let (guardAuth, guardService) = makeHarness(session: session)
    let guardSocket = FilteredSocket()
    let guardVM = ChatViewModel(authStore: guardAuth, conversationService: guardService, webSocketRouter: WebSocketRouter(client: guardSocket))
    seedCharacter(guardVM)
    await guardVM.loadRealTurns(chatID: "chat")
    let guardBaseIDs = guardVM.turnStates.map(\.id)
    precondition(!guardBaseIDs.isEmpty, "Base history must load for the filtered-guard check")
    let guardRequest = Task { await guardVM.sendMessage("hello", chatID: "chat") }
    let guardStarted = try await pollForGenerating(guardVM)
    precondition(guardStarted, "Generation must start for the filtered-guard check")
    await guardSocket.finishLastGenerationWithFiltered(turnID: "turn-filtered")
    await guardRequest.value
    let guardIDsAfterFilter = guardVM.turnStates.map(\.id)
    precondition(Array(guardIDsAfterFilter.prefix(guardBaseIDs.count)) == guardBaseIDs,
                 "Filtered generation keeps every existing turn in order")
    guardService.invalidateHistory(chatID: "chat")
    StubHTTP.state.withLock { $0.emptyTurns = true }
    await guardVM.loadRealTurns(chatID: "chat", forceRefresh: true)
    precondition(guardVM.errorMessage == nil, "Empty history after a filtered generation must not surface an error")
    precondition(guardVM.turnStates.map(\.id) == guardIDsAfterFilter,
                 "Empty complete server history must not erase the conversation after a filtered generation")
    // The guard releases once a non-empty server history confirms the filtered turn:
    // a later empty complete history then replaces the view normally.
    StubHTTP.state.withLock { $0.emptyTurns = false }
    guardService.invalidateHistory(chatID: "chat")
    await guardVM.loadRealTurns(chatID: "chat", forceRefresh: true)
    precondition(!guardVM.turnStates.isEmpty, "Server-confirmed history loads normally")
    StubHTTP.state.withLock { $0.emptyTurns = true }
    guardService.invalidateHistory(chatID: "chat")
    await guardVM.loadRealTurns(chatID: "chat", forceRefresh: true)
    precondition(guardVM.turnStates.isEmpty, "After server confirmation, an empty complete history replaces normally")
    StubHTTP.state.withLock { $0.emptyTurns = false }
    guardVM.disconnect()

    // Scenario 3: an incomplete generation (streamed partial, no terminal frame yet)
    // must not replace or reorder the existing conversation.
    let (partialAuth, partialService) = makeHarness(session: session)
    let partialSocket = FilteredSocket()
    let partialVM = ChatViewModel(authStore: partialAuth, conversationService: partialService, webSocketRouter: WebSocketRouter(client: partialSocket))
    seedCharacter(partialVM)
    await partialVM.loadRealTurns(chatID: "chat")
    let partialBaseIDs = partialVM.turnStates.map(\.id)
    let partialRequest = Task { await partialVM.sendMessage("partial check", chatID: "chat") }
    let partialGenerating = try await pollForGenerating(partialVM)
    precondition(partialGenerating, "Generation must start for the incomplete-generation check")
    let partialShown = try await pollForContent("Partial", from: partialVM)
    precondition(partialShown, "Streamed partial must be visible mid-generation")
    precondition(Array(partialVM.turnStates.map(\.id).prefix(partialBaseIDs.count)) == partialBaseIDs,
                 "An incomplete generation must not replace or reorder existing turns")
    await partialSocket.finishLastGenerationWithFinal(text: "Complete")
    await partialRequest.value
    precondition(partialVM.errorMessage == nil, "Completed generation after an incomplete one must succeed")
    partialVM.disconnect()

    // Scenario 5: genuine protocol failure during generation is a visible
    // error and existing turns remain.
    let (failureAuth, failureService) = makeHarness(session: session)
    let failingSocket = FilteredSocket()
    await failingSocket.setGenerationFails()
    let failingVM = ChatViewModel(authStore: failureAuth, conversationService: failureService, webSocketRouter: WebSocketRouter(client: failingSocket))
    seedCharacter(failingVM)
    await failingVM.loadRealTurns(chatID: "chat")
    let beforeFailure = failingVM.turnStates.map(\.id)
    let failureRequest = Task { await failingVM.sendMessage("hello", chatID: "chat") }
    await failureRequest.value
    precondition(failingVM.errorMessage != nil, "neo_error must surface as a failure")
    precondition(failingVM.turnStates.map(\.id) == beforeFailure,
                 "A failed generation must not clear or replace existing conversation turns")
    failingVM.disconnect()

    // Scenario 6: malformed frame fails its pending operation visibly but
    // leaves the socket and later operations alive.
    let (malformedAuth, malformedService) = makeHarness(session: session)
    let malformedSocket = FilteredSocket()
    await malformedSocket.setMalformNextGeneration()
    let malformedVM = ChatViewModel(authStore: malformedAuth, conversationService: malformedService, webSocketRouter: WebSocketRouter(client: malformedSocket))
    seedCharacter(malformedVM)
    await malformedVM.loadRealTurns(chatID: "chat")
    let beforeMalformed = malformedVM.turnStates.map(\.id)
    let malformedRequest = Task { await malformedVM.sendMessage("hello", chatID: "chat") }
    await malformedRequest.value
    precondition(malformedVM.errorMessage != nil, "Malformed frame must fail its pending operation visibly")
    precondition(malformedVM.turnStates.map(\.id) == beforeMalformed,
                 "Malformed frame must not clear the conversation")
    // The router survived: a well-formed generation still completes.
    let recoveryRequest = Task { await malformedVM.sendMessage("again", chatID: "chat") }
    let recoveryStarted = try await pollForGenerating(malformedVM)
    precondition(recoveryStarted, "Router must stay alive after a malformed frame")
    await malformedSocket.finishLastGenerationWithFinal(text: "Recovered")
    await recoveryRequest.value
    precondition(malformedVM.lastTurn?.candidates.first?.rawContent == "Recovered",
                 "A well-formed generation completes on the same connection")
    malformedVM.disconnect()

    // Scenario 8: WebSocket disconnect during a streamed response is failure
    // handling, not conversation deletion.
    let (disconnectAuth, disconnectService) = makeHarness(session: session)
    let disconnectSocket = FilteredSocket()
    let disconnectVM = ChatViewModel(authStore: disconnectAuth, conversationService: disconnectService, webSocketRouter: WebSocketRouter(client: disconnectSocket))
    seedCharacter(disconnectVM)
    await disconnectVM.loadRealTurns(chatID: "chat")
    let beforeDisconnect = disconnectVM.turnStates.map(\.id)
    let disconnectRequest = Task { await disconnectVM.sendMessage("hello", chatID: "chat") }
    let disconnectStarted = try await pollForGenerating(disconnectVM)
    precondition(disconnectStarted, "Generation must start before the disconnect")
    await disconnectSocket.disconnect()
    await disconnectRequest.value
    precondition(disconnectVM.errorMessage != nil, "Disconnect during generation surfaces as failure")
    // The streamed partial turn legitimately appended before the disconnect;
    // the precise invariant is: every pre-existing turn survives, the partial
    // turn survives, and nothing was removed.
    precondition(disconnectVM.turnStates.count == beforeDisconnect.count + 1
                 && Array(disconnectVM.turnStates.map(\.id).prefix(beforeDisconnect.count)) == beforeDisconnect,
                 "Disconnect must not remove existing turns (only the streamed partial is appended)")
    disconnectVM.disconnect()

    print("Filtered-response checks passed: filtered turn preserved, conversation intact, chat continues, reload/failure/malformed/disconnect all keep existing turns")
}
