import AppKit
import Foundation

/// Decoded pools are independent; URLSession and URLCache remain shared.
/// NSImage work finishes off-main before the immutable result is published.
@MainActor
final class ImageCacheService {
    static let shared = ImageCacheService()

    enum Pool: Hashable { case avatar, media }
    static let avatarCostLimit = 16 * 1024 * 1024
    static let mediaCostLimit = 24 * 1024 * 1024

    private struct InFlight {
        let id: UUID
        let task: Task<NSImage?, Never>
        var consumers: Set<UUID>
        var pools: Set<Pool>
    }
    private struct Download {
        let id: UUID
        let task: Task<Data?, Never>
        var consumers: Set<UUID>
    }

    private let avatars = NSCache<NSString, NSImage>()
    private let media = NSCache<NSString, NSImage>()
    private let urlSession: URLSession
    private var inFlight: [String: InFlight] = [:]
    private var downloads: [URL: Download] = [:]

    init(session: URLSession? = nil) {
        avatars.countLimit = 150
        avatars.totalCostLimit = Self.avatarCostLimit
        media.countLimit = 40
        media.totalCostLimit = Self.mediaCostLimit
        if let session { urlSession = session }
        else {
            let config = URLSessionConfiguration.default
            config.requestCachePolicy = .returnCacheDataElseLoad
            config.urlCache = URLCache(memoryCapacity: 20 * 1024 * 1024,
                                      diskCapacity: 80 * 1024 * 1024,
                                      directory: Self.diskCacheDirectory)
            urlSession = URLSession(configuration: config)
        }
    }

    private static var diskCacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "CharacterAI", isDirectory: true)
            .appendingPathComponent("ImageCache", isDirectory: true)
    }

    private func cache(_ pool: Pool) -> NSCache<NSString, NSImage> {
        pool == .avatar ? avatars : media
    }

    private static func cacheKey(for url: URL, maxPixelSize: Int) -> String {
        "\(maxPixelSize)|\(url.absoluteString)"
    }

    func image(for url: URL, maxPixelSize: Int = 160, pool: Pool = .avatar) -> NSImage? {
        cache(pool).object(forKey: Self.cacheKey(for: url, maxPixelSize: maxPixelSize) as NSString)
    }

    /// The pool controls retention, not the decoded resolution or HTTP request.
    func fetchImage(for url: URL, maxPixelSize: Int = 160, pool: Pool = .avatar) async -> NSImage? {
        guard !Task.isCancelled, maxPixelSize > 0 else { return nil }
        let key = Self.cacheKey(for: url, maxPixelSize: maxPixelSize)
        if let cached = image(for: url, maxPixelSize: maxPixelSize, pool: pool) { return cached }
        let consumer = UUID()
        let load: InFlight
        if var existing = inFlight[key] {
            existing.consumers.insert(consumer)
            existing.pools.insert(pool)
            inFlight[key] = existing
            load = existing
        } else {
            let task = Task<NSImage?, Never> { [weak self] in
                guard let data = await self?.download(url), !Task.isCancelled else { return nil }
                return await ImageProcessing.decodedThumbnail(from: data, maxPixelSize: maxPixelSize)
            }
            load = InFlight(id: UUID(), task: task, consumers: [consumer], pools: [pool])
            inFlight[key] = load
        }
        let image = await withTaskCancellationHandler {
            await load.task.value
        } onCancel: {
            Task { @MainActor [weak self] in self?.release(key, loadID: load.id, consumer: consumer) }
        }
        if let current = inFlight[key], current.id == load.id {
            inFlight.removeValue(forKey: key)
            if let image, !load.task.isCancelled {
                let cost = Int(image.size.width * image.size.height * 4)
                for pool in current.pools { cache(pool).setObject(image, forKey: key as NSString, cost: cost) }
            }
        }
        return Task.isCancelled ? nil : image
    }

    private func download(_ url: URL) async -> Data? {
        guard !Task.isCancelled else { return nil }
        let consumer = UUID()
        let load: Download
        if var existing = downloads[url] {
            existing.consumers.insert(consumer)
            downloads[url] = existing
            load = existing
        } else {
            let session = urlSession
            let task = Task<Data?, Never> {
                do {
                    let (data, response) = try await session.data(from: url)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                          !Task.isCancelled else { return nil }
                    return data
                } catch { return nil }
            }
            load = Download(id: UUID(), task: task, consumers: [consumer])
            downloads[url] = load
        }
        let data = await withTaskCancellationHandler {
            await load.task.value
        } onCancel: {
            Task { @MainActor [weak self] in self?.releaseDownload(url, loadID: load.id, consumer: consumer) }
        }
        releaseDownload(url, loadID: load.id, consumer: consumer)
        return Task.isCancelled ? nil : data
    }

    private func releaseDownload(_ url: URL, loadID: UUID, consumer: UUID) {
        guard var load = downloads[url], load.id == loadID else { return }
        load.consumers.remove(consumer)
        if load.consumers.isEmpty {
            load.task.cancel()
            downloads.removeValue(forKey: url)
        } else { downloads[url] = load }
    }

    private func release(_ key: String, loadID: UUID, consumer: UUID) {
        guard var load = inFlight[key], load.id == loadID else { return }
        load.consumers.remove(consumer)
        if load.consumers.isEmpty {
            load.task.cancel()
            inFlight.removeValue(forKey: key)
        } else { inFlight[key] = load }
    }

    #if DEBUG
    var pendingDecodeCount: Int { inFlight.count }
    var pendingDownloadCount: Int { downloads.count }
    func clearDecoded(_ pool: Pool) { cache(pool).removeAllObjects() }
    #endif

    deinit {
        for load in inFlight.values { load.task.cancel() }
        for load in downloads.values { load.task.cancel() }
    }
}
