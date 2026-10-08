import AppKit
import Foundation

/// Bounded decoded image cache, keyed by URL and maximum pixel size so one URL
/// is never served at the wrong resolution. The URLCache retains HTTP data.
/// NSImage work finishes off-main before the immutable result is published.
@MainActor
final class ImageCacheService {
    static let shared = ImageCacheService()

    private struct InFlight {
        let id: UUID
        let task: Task<NSImage?, Never>
        var consumers: Set<UUID>
    }
    private let memoryCache = NSCache<NSString, NSImage>()
    private let urlSession: URLSession
    private var inFlight: [String: InFlight] = [:]

    init(session: URLSession? = nil) {
        memoryCache.countLimit = 150
        memoryCache.totalCostLimit = 40 * 1024 * 1024
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

    /// Per-app folder in the user's Caches directory, independent of the working directory.
    private static var diskCacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "CharacterAI", isDirectory: true)
            .appendingPathComponent("ImageCache", isDirectory: true)
    }

    private static func cacheKey(for url: URL, maxPixelSize: Int) -> String {
        "\(maxPixelSize)|\(url.absoluteString)"
    }

    func image(for url: URL, maxPixelSize: Int = 160) -> NSImage? {
        memoryCache.object(forKey: Self.cacheKey(for: url, maxPixelSize: maxPixelSize) as NSString)
    }

    /// `maxPixelSize` bounds the longest decoded edge; callers pass their Retina-scaled display size.
    func fetchImage(for url: URL, maxPixelSize: Int = 160) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        let key = Self.cacheKey(for: url, maxPixelSize: maxPixelSize)
        if let cached = image(for: url, maxPixelSize: maxPixelSize) { return cached }
        let consumer = UUID()
        let load: InFlight
        if var existing = inFlight[key] {
            existing.consumers.insert(consumer)
            inFlight[key] = existing
            load = existing
        } else {
            let session = urlSession
            let task = Task<NSImage?, Never> {
                do {
                    let (data, response) = try await session.data(from: url)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                          !Task.isCancelled else { return nil }
                    // Avatars use 160 px: the largest presentation is 64pt, and 160 covers
                    // Retina without decoding arbitrary full-size profile URLs.
                    return await ImageProcessing.decodedThumbnail(from: data, maxPixelSize: maxPixelSize)
                } catch { return nil }
            }
            load = InFlight(id: UUID(), task: task, consumers: [consumer])
            inFlight[key] = load
        }
        let image = await withTaskCancellationHandler {
            await load.task.value
        } onCancel: {
            Task { @MainActor [weak self] in self?.release(key, loadID: load.id, consumer: consumer) }
        }
        if inFlight[key]?.id == load.id {
            inFlight.removeValue(forKey: key)
            if let image, !load.task.isCancelled {
                memoryCache.setObject(image, forKey: key as NSString,
                                      cost: Int(image.size.width * image.size.height * 4))
            }
        }
        return Task.isCancelled ? nil : image
    }

    private func release(_ key: String, loadID: UUID, consumer: UUID) {
        guard var load = inFlight[key], load.id == loadID else { return }
        load.consumers.remove(consumer)
        if load.consumers.isEmpty {
            load.task.cancel()
            inFlight.removeValue(forKey: key)
        } else { inFlight[key] = load }
    }

    deinit { for load in inFlight.values { load.task.cancel() } }
}
