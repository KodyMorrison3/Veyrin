import AppKit
import Foundation

/// Bounded in-memory and disk image cache for character and persona avatars.
/// Prevents redundant HTTP fetches and repeated decoding across message rows,
/// sidebar rows, headers, and composer.
final class ImageCacheService: @unchecked Sendable {
    static let shared = ImageCacheService()

    private let memoryCache = NSCache<NSURL, NSImage>()
    private let urlSession: URLSession

    init() {
        memoryCache.countLimit = 150
        memoryCache.totalCostLimit = 40 * 1024 * 1024 // 40 MB max

        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.urlCache = URLCache(
            memoryCapacity: 20 * 1024 * 1024,
            diskCapacity: 80 * 1024 * 1024,
            diskPath: "VeyrinImageCache"
        )
        self.urlSession = URLSession(configuration: config)
    }

    func image(for url: URL) -> NSImage? {
        memoryCache.object(forKey: url as NSURL)
    }

    func insert(_ image: NSImage, for url: URL) {
        let cost = Int(image.size.width * image.size.height * 4)
        memoryCache.setObject(image, forKey: url as NSURL, cost: cost)
    }

    func fetchImage(for url: URL) async -> NSImage? {
        if let cached = image(for: url) {
            return cached
        }

        do {
            let (data, response) = try await urlSession.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let image = NSImage(data: data) else {
                return nil
            }
            insert(image, for: url)
            return image
        } catch {
            return nil
        }
    }
}
