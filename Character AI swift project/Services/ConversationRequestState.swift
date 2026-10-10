import Foundation

@MainActor
final class ConversationRequestState {
    final class HistoryRead {
        let id = UUID()
        var isValid = true
    }

    private struct PreviewWaiter {
        let id: UUID
        let continuation: CheckedContinuation<UUID, Error>
    }

    private var histories: [String: [UUID: HistoryRead]] = [:]
    private var activePreviews: Set<UUID> = []
    private var previewWaiters: [PreviewWaiter] = []

    func beginHistoryRead(_ chatID: String) -> HistoryRead {
        let read = HistoryRead()
        histories[chatID, default: [:]][read.id] = read
        return read
    }

    func endHistoryRead(_ chatID: String, read: HistoryRead) {
        histories[chatID]?.removeValue(forKey: read.id)
        if histories[chatID]?.isEmpty == true { histories.removeValue(forKey: chatID) }
    }

    func invalidateHistory(_ chatID: String) {
        for read in histories.removeValue(forKey: chatID)?.values ?? [:].values { read.isValid = false }
    }

    func acquirePreview() async throws -> UUID {
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if activePreviews.count < 3 {
                    activePreviews.insert(id)
                    continuation.resume(returning: id)
                } else {
                    previewWaiters.append(PreviewWaiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelPreview(id) }
        }
    }

    func releasePreview(_ id: UUID) {
        guard activePreviews.remove(id) != nil else { return }
        while activePreviews.count < 3, !previewWaiters.isEmpty {
            let waiter = previewWaiters.removeFirst()
            activePreviews.insert(waiter.id)
            waiter.continuation.resume(returning: waiter.id)
        }
    }

    private func cancelPreview(_ id: UUID) {
        if let index = previewWaiters.firstIndex(where: { $0.id == id }) {
            previewWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
        }
        // An active request releases its own slot after URLSession cancellation.
    }

    func clear() {
        for reads in histories.values { for read in reads.values { read.isValid = false } }
        histories.removeAll()
        let waiters = previewWaiters
        previewWaiters.removeAll()
        for waiter in waiters { waiter.continuation.resume(throwing: CancellationError()) }
        // Keep cancelled active slots occupied until their requests really exit.
    }
}
