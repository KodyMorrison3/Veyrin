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

    func loadNextHistoryPage(chatID: String, snapshot: CachedConversation) async throws -> CachedConversation {
        guard let cursor = snapshot.nextToken else { return snapshot }
        guard !snapshot.visitedTokens.contains(cursor) else {
            throw NetworkError.serverMessage("Conversation pagination returned a repeated cursor.")
        }
        let epoch = cache.epoch
        let page = try await loadTurnPage(chatID: chatID, nextToken: cursor)
        try Task.checkCancellation()
        guard cache.epoch == epoch else { throw CancellationError() }
        // Oversized histories deliberately bypass cache admission but must
        // still paginate correctly in the active view.
        let latest = cachedHistory(chatID: chatID) ?? snapshot
        if latest.visitedTokens.contains(cursor) { return latest }
        guard latest.nextToken == cursor, latest.revision == snapshot.revision else { throw CancellationError() }
        var result = latest
        result.visitedTokens.insert(cursor)
        if let next = page.meta.nextToken, result.visitedTokens.contains(next) {
            throw NetworkError.serverMessage("Conversation pagination returned a repeated cursor.")
        }
        var ids = Set(result.turns.map(\.turnID))
        let pins: Set<String>
        if page.turns.allSatisfy({ $0.isPinned != nil }) { pins = [] }
        else { pins = try await loadPinnedTurnIDs(chatID: chatID) }
        for turn in page.turns where ids.insert(turn.turnKey.turnID).inserted {
            result.turns.append(makeUITurn(from: turn, characterID: result.characterID,
                                          isPinned: turn.isPinned ?? pins.contains(turn.turnKey.turnID)))
        }
        try Task.checkCancellation()
        guard cache.epoch == epoch,
              cachedHistory(chatID: chatID).map({ $0.revision == snapshot.revision }) ?? true else { throw CancellationError() }
        result.nextToken = page.meta.nextToken
        result.isComplete = result.nextToken == nil
        cache.update(historyKey(chatID), as: CachedConversation.self, cost: { _ in result.cost }) { _ in result }
        return result
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
            if let index = snapshot.turns.firstIndex(where: { $0.turnID == turn.turnID }) {
                snapshot.turns[index] = turn
            } else { snapshot.turns.append(turn) }
            return snapshot
        }
    }

    func cacheRewind(chatID: String, removedIDs: Set<String>) {
        cache.update(historyKey(chatID), as: CachedConversation.self, cost: { $0.cost }) { snapshot in
            var snapshot = snapshot
            snapshot.turns.removeAll { removedIDs.contains($0.turnID) }
            return snapshot
        }
    }

    func completeMutation(chatID: String) {
        if let snapshot = cachedHistory(chatID: chatID), snapshot.isComplete {
            cache.insert(snapshot, for: historyKey(chatID), ttl: 45, cost: snapshot.cost)
        }
    }

    func invalidateHistory(chatID: String) {
        cache.invalidate(historyKey(chatID))
        resources.invalidate(prefix: "turn-page:https://neo.character.ai/turns/\(chatID)/")
    }
}
