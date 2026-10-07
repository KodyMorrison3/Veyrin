import AppKit
import Foundation

/// Bounded decoded avatar cache; the existing URLCache retains HTTP caching.
/// NSImage work finishes off-main before the immutable result is published.
@MainActor
final class ImageCacheService {
    static let shared = ImageCacheService()

    private struct InFlight {
        let id: UUID
        let task: Task<NSImage?, Never>
        var consumers: Set<UUID>
    }
    private let memoryCache = NSCache<NSURL, NSImage>()
    private let urlSession: URLSession
    private var inFlight: [URL: InFlight] = [:]

    init(session: URLSession? = nil) {
        memoryCache.countLimit = 150
        memoryCache.totalCostLimit = 40 * 1024 * 1024
        if let session { urlSession = session }
        else {
            let config = URLSessionConfiguration.default
            config.requestCachePolicy = .returnCacheDataElseLoad
            config.urlCache = URLCache(memoryCapacity: 20 * 1024 * 1024,
                                      diskCapacity: 80 * 1024 * 1024, diskPath: "VeyrinImageCache")
            urlSession = URLSession(configuration: config)
        }
    }

    func image(for url: URL) -> NSImage? { memoryCache.object(forKey: url as NSURL) }

    func fetchImage(for url: URL) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        if let cached = image(for: url) { return cached }
        let consumer = UUID()
        let load: InFlight
        if var existing = inFlight[url] {
            existing.consumers.insert(consumer)
            inFlight[url] = existing
            load = existing
        } else {
            let session = urlSession
            let task = Task<NSImage?, Never> {
                do {
                    let (data, response) = try await session.data(from: url)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                          !Task.isCancelled else { return nil }
                    // Largest avatar presentation is 64pt; 160 pixels covers
                    // Retina without decoding arbitrary full-size profile URLs.
                    return await ImageProcessing.decodedThumbnail(from: data, maxPixelSize: 160)
                } catch { return nil }
            }
            load = InFlight(id: UUID(), task: task, consumers: [consumer])
            inFlight[url] = load
        }
        let image = await withTaskCancellationHandler {
            await load.task.value
        } onCancel: {
            Task { @MainActor [weak self] in self?.release(url, loadID: load.id, consumer: consumer) }
        }
        if inFlight[url]?.id == load.id {
            inFlight.removeValue(forKey: url)
            if let image, !load.task.isCancelled {
                memoryCache.setObject(image, forKey: url as NSURL,
                                      cost: Int(image.size.width * image.size.height * 4))
            }
        }
        return Task.isCancelled ? nil : image
    }

    private func release(_ url: URL, loadID: UUID, consumer: UUID) {
        guard var load = inFlight[url], load.id == loadID else { return }
        load.consumers.remove(consumer)
        if load.consumers.isEmpty {
            load.task.cancel()
            inFlight.removeValue(forKey: url)
        } else { inFlight[url] = load }
    }

    deinit { for load in inFlight.values { load.task.cancel() } }
}
