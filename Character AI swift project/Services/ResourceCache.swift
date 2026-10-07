import Foundation

/// Session-owned application data, never credentials. All bookkeeping and
/// type-erased storage stays on MainActor; loaders retain their existing isolation.
@MainActor
final class ResourceCache {
    private struct Entry {
        let value: Any
        let storedAt: Date
        var freshUntil: Date
        let cost: Int
        var access: UInt64
    }
    private struct Load {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: (Result<Any, Error>) -> Void]
    }

    private var entries: [String: Entry] = [:]
    private var loads: [String: Load] = [:]
    private var clock: UInt64 = 0
    private(set) var epoch = UUID()
    private(set) var totalCost = 0
    let countLimit: Int
    let costLimit: Int
    private let now: () -> Date

    init(countLimit: Int = 96, costLimit: Int = 24 * 1024 * 1024,
         now: @escaping () -> Date = Date.init) {
        self.countLimit = countLimit
        self.costLimit = costLimit
        self.now = now
    }

    var count: Int { entries.count }
    var pendingCount: Int { loads.count }

    func cached<Value>(_ key: String, as type: Value.Type, maxAge: TimeInterval = 300,
                       requireFresh: Bool = false) -> Value? {
        guard var entry = entries[key] else { return nil }
        guard now().timeIntervalSince(entry.storedAt) <= maxAge else {
            remove(key)
            return nil
        }
        guard !requireFresh || entry.freshUntil > now(), let value = entry.value as? Value else { return nil }
        clock &+= 1
        entry.access = clock
        entries[key] = entry
        return value
    }

    func insert<Value>(_ value: Value, for key: String, ttl: TimeInterval, cost: Int) {
        remove(key)
        let cost = max(cost, 1)
        guard cost <= costLimit, countLimit > 0 else { return }
        clock &+= 1
        entries[key] = Entry(value: value, storedAt: now(), freshUntil: now().addingTimeInterval(ttl),
                             cost: cost, access: clock)
        totalCost += cost
        trim()
    }

    /// Targeted completed-state updates retain the server freshness deadline:
    /// a local edit does not prove that unrelated server turns are still fresh.
    func update<Value>(_ key: String, as type: Value.Type, cost: (Value) -> Int,
                       transform: (Value) -> Value) {
        guard let entry = entries[key], let old = entry.value as? Value else { return }
        let value = transform(old)
        let newCost = max(cost(value), 1)
        guard newCost <= costLimit else { remove(key); return }
        totalCost -= entry.cost
        clock &+= 1
        entries[key] = Entry(value: value, storedAt: entry.storedAt, freshUntil: entry.freshUntil,
                             cost: newCost, access: clock)
        totalCost += newCost
        trim()
    }

    func value<Value: Sendable>(for key: String, ttl: TimeInterval,
                               forceRefresh: Bool = false, cost: @escaping (Value) -> Int,
                               load: @escaping @MainActor () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        if !forceRefresh, let cached = cached(key, as: Value.self, maxAge: ttl, requireFresh: true) { return cached }
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let resolve: (Result<Any, Error>) -> Void = { result in
                    switch result {
                    case .success(let value):
                        guard let typed = value as? Value else {
                            continuation.resume(throwing: NetworkError.invalidResponse)
                            return
                        }
                        continuation.resume(returning: typed)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
                if var existing = loads[key] {
                    existing.waiters[waiter] = resolve
                    loads[key] = existing
                    return
                }
                guard loads.count < 32 else {
                    continuation.resume(throwing: NetworkError.serverMessage("Too many pending data loads."))
                    return
                }
                let id = UUID()
                let epoch = epoch
                let task = Task { [weak self] in
                    do {
                        let value = try await load()
                        try Task.checkCancellation()
                        self?.complete(key, id: id, epoch: epoch, result: .success(value), ttl: ttl, cost: cost(value))
                    } catch {
                        self?.complete(key, id: id, epoch: epoch, result: .failure(error), ttl: ttl, cost: 0)
                    }
                }
                loads[key] = Load(id: id, task: task, waiters: [waiter: resolve])
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(key, waiter: waiter) }
        }
    }

    private func complete(_ key: String, id: UUID, epoch: UUID, result: Result<Any, Error>,
                          ttl: TimeInterval, cost: Int) {
        guard self.epoch == epoch, let pending = loads[key], pending.id == id else { return }
        loads.removeValue(forKey: key)
        if case .success(let value) = result { insert(value, for: key, ttl: ttl, cost: cost) }
        for resolve in pending.waiters.values { resolve(result) }
    }

    private func cancel(_ key: String, waiter: UUID) {
        guard var pending = loads[key], let resolve = pending.waiters.removeValue(forKey: waiter) else { return }
        resolve(.failure(CancellationError()))
        if pending.waiters.isEmpty {
            loads.removeValue(forKey: key)
            pending.task.cancel()
        } else { loads[key] = pending }
    }

    func invalidate(_ key: String, keepStale: Bool = false) {
        if keepStale, var entry = entries[key] {
            entry.freshUntil = .distantPast
            entries[key] = entry
        } else { remove(key) }
        if let pending = loads.removeValue(forKey: key) {
            pending.task.cancel()
            for resolve in pending.waiters.values { resolve(.failure(CancellationError())) }
        }
    }

    func invalidate(prefix: String) {
        for key in Set(entries.keys).union(loads.keys) where key.hasPrefix(prefix) { invalidate(key) }
    }

    func clear() {
        epoch = UUID()
        entries.removeAll()
        totalCost = 0
        let pending = loads.values
        loads.removeAll()
        for load in pending {
            load.task.cancel()
            for resolve in load.waiters.values { resolve(.failure(CancellationError())) }
        }
    }

    private func remove(_ key: String) {
        if let entry = entries.removeValue(forKey: key) { totalCost -= entry.cost }
    }

    private func trim() {
        for (key, entry) in entries where now().timeIntervalSince(entry.storedAt) > 900 { remove(key) }
        while entries.count > countLimit || totalCost > costLimit {
            guard let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key else { break }
            remove(oldest)
        }
    }

    deinit { for load in loads.values { load.task.cancel() } }
}

nonisolated enum DataCacheCost {
    static func json<Value: Encodable>(_ value: Value) -> Int {
        // Used once per loaded resource, not during view evaluation/streaming.
        (try? JSONEncoder().encode(value).count).map { $0 * 2 } ?? 4096
    }
}
