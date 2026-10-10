import Foundation

extension ConversationService {
    private func historyKey(_ chatID: String) -> String { "history:\(chatID)" }

    func cachedHistory(chatID: String, freshOnly: Bool = false) -> CachedConversation? {
        cache.cached(historyKey(chatID), as: CachedConversation.self, maxAge: 300, requireFresh: freshOnly)
    }

    func loadHistory(chatID: String, characterID: String, forceRefresh: Bool = false) async throws -> CachedConversation {
        if forceRefresh { invalidateHistory(chatID: chatID) }
        return try await cache.value(for: historyKey(chatID), ttl: 45, cost: { $0.cost }) {
            let page = try await loadTurnPage(chatID: chatID)
            let pins: Set<String>
            if page.turns.allSatisfy({ $0.isPinned != nil }) { pins = [] }
            else { pins = try await loadPinnedTurnIDs(chatID: chatID) }
            var ids: Set<String> = []
            let turns = page.turns.filter { ids.insert($0.turnKey.turnID).inserted }.map {
                makeUITurn(from: $0, characterID: characterID,
                           isPinned: $0.isPinned ?? pins.contains($0.turnKey.turnID))
            }
            return CachedConversation(characterID: characterID, turns: turns, nextToken: page.meta.nextToken,
                                      visitedTokens: [], isComplete: page.meta.nextToken == nil)
        }
    }

    /// Keep the growing value local to this load. Cache checkpoints double in
    /// size, avoiding a copy of the entire prefix for every small page.
    func loadHistoryPages(
        chatID: String, characterID: String, forceRefresh: Bool = false,
        receive: @MainActor ([Turn], Bool, Bool) throws -> Void
    ) async throws {
        if forceRefresh { invalidateHistory(chatID: chatID) }
        let epoch = cache.epoch
        let generation = authenticatedHTTPClient.sessionGeneration
        let read = authenticatedHTTPClient.requestState.beginHistoryRead(chatID)
        defer { authenticatedHTTPClient.requestState.endHistoryRead(chatID, read: read) }
        var initial: CachedConversation? = try await loadHistory(chatID: chatID, characterID: characterID)
        guard var result = initial else { return }
        initial = nil
        try Task.checkCancellation()
        guard read.isValid, cache.epoch == epoch, generation == authenticatedHTTPClient.sessionGeneration,
              result.characterID == characterID else { throw CancellationError() }
        let revision = result.revision
        var ids = Set(result.turns.map { TurnKey(turnId: $0.turnID, chatId: $0.chatID) })
        var nextCheckpoint = max(result.turns.count * 2, 1)
        func isCurrent() -> Bool {
            cache.epoch == epoch && authenticatedHTTPClient.sessionGeneration == generation &&
            read.isValid &&
            (cachedHistory(chatID: chatID).map { $0.revision == revision } ?? true)
        }
        func checkpoint() {
            guard isCurrent() else { return }
            if let latest = cachedHistory(chatID: chatID),
               !latest.visitedTokens.isSubset(of: result.visitedTokens) { return }
            cache.update(historyKey(chatID), as: CachedConversation.self, cost: { _ in result.cost }) { _ in result }
        }
        // Cancellation saves confirmed progress only; a mutation/account change
        // must never write this old load back over the newer cache revision.
        defer { checkpoint() }
        try Task.checkCancellation()
        try receive(result.turns, true, result.isComplete)
        while let cursor = result.nextToken {
            guard !result.visitedTokens.contains(cursor) else {
                throw NetworkError.serverMessage("Conversation pagination returned a repeated cursor.")
            }
            let page = try await loadTurnPage(chatID: chatID, nextToken: cursor)
            let pins: Set<String>
            if page.turns.allSatisfy({ $0.isPinned != nil }) { pins = [] }
            else { pins = try await loadPinnedTurnIDs(chatID: chatID) }
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            if let next = page.meta.nextToken, next == cursor || result.visitedTokens.contains(next) {
                throw NetworkError.serverMessage("Conversation pagination returned a repeated cursor.")
            }
            var additions: [Turn] = []
            for turn in page.turns {
                let key = TurnKey(turnId: turn.turnKey.turnID, chatId: turn.turnKey.chatID)
                guard ids.insert(key).inserted else { continue }
                additions.append(makeUITurn(from: turn, characterID: characterID,
                                            isPinned: turn.isPinned ?? pins.contains(turn.turnKey.turnID)))
            }
            result.append(additions)
            result.visitedTokens.insert(cursor)
            result.nextToken = page.meta.nextToken
            result.isComplete = result.nextToken == nil
            try receive(additions, false, result.isComplete)
            if result.turns.count >= nextCheckpoint {
                checkpoint()
                nextCheckpoint = max(result.turns.count * 2, nextCheckpoint * 2)
            }
        }
    }

    func loadTurnPage(chatID: String, nextToken: String? = nil, pinnedOnly: Bool = false) async throws -> TurnsResponse {
        var components = URLComponents(string: "https://neo.character.ai/turns/\(chatID)/")
        var items = [URLQueryItem(name: "order_by_asc", value: "true")]
        if pinnedOnly { items.append(URLQueryItem(name: "pinned_only", value: "true")) }
        if let nextToken { items.append(URLQueryItem(name: "next_token", value: nextToken)) }
        components?.queryItems = items
        guard let url = components?.url else { throw NetworkError.invalidURL }
        // Opaque cursor is part of the key; no duplicate decode for shared readers.
        let key = "turn-page:\(url.absoluteString)"
        return try await resources.value(for: key, ttl: 45, cost: { response in
            response.turns.reduce(256) { $0 + 512 + $1.candidates.reduce(0) { $0 + $1.rawContent.utf8.count * 4 + 256 } }
        }) {
            try await authenticatedHTTPClient.get(url)
        }
    }

    /// Before a mutation, cancel obsolete history loads without discarding the
    /// already-visible completed snapshot. Partial streamed values are not saved.
    func beginMutation(chatID: String) {
        authenticatedHTTPClient.requestState.invalidateHistory(chatID)
        cache.invalidate(historyKey(chatID), keepStale: true)
        cache.update(historyKey(chatID), as: CachedConversation.self, cost: { $0.cost }) { snapshot in
            var snapshot = snapshot
            snapshot.revision = UUID()
            return snapshot
        }
        resources.invalidate(prefix: "turn-page:https://neo.character.ai/turns/\(chatID)/")
        resources.invalidate("recent-chats")
        if let characterID = cachedHistory(chatID: chatID)?.characterID {
            resources.invalidate("previews:\(characterID)")
        }
    }

    func cacheCompletedTurn(_ turn: Turn) {
        guard !turn.candidates.contains(where: { $0.isFinal == false }) else { return }
        cache.update(historyKey(turn.chatID), as: CachedConversation.self, cost: { $0.cost }) { snapshot in
            var snapshot = snapshot
            snapshot.update(turn)
            return snapshot
        }
    }

    func cacheRewind(chatID: String, removedIDs: Set<String>) {
        cache.update(historyKey(chatID), as: CachedConversation.self, cost: { $0.cost }) { snapshot in
            var snapshot = snapshot
            snapshot.remove(removedIDs)
            return snapshot
        }
    }

    func completeMutation(chatID: String) {
        if let snapshot = cachedHistory(chatID: chatID), snapshot.isComplete {
            cache.insert(snapshot, for: historyKey(chatID), ttl: 45, cost: snapshot.cost)
        }
    }

    func invalidateHistory(chatID: String) {
        authenticatedHTTPClient.requestState.invalidateHistory(chatID)
        cache.invalidate(historyKey(chatID))
        resources.invalidate(prefix: "turn-page:https://neo.character.ai/turns/\(chatID)/")
    }
}
