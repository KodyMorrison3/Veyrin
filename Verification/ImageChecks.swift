import AppKit
import Foundation
import ImageIO
import Synchronization

nonisolated private final class ImageHTTP: URLProtocol, @unchecked Sendable {
    // URLProtocol test hook: shared state is fully mutex-protected.
    static let payload = Mutex(Data())
    static let requests = Mutex(0)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.withLock { $0 += 1 }
        let data = Self.payload.withLock { $0 }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "image/png"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
func runImageChecks() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    func writeImage(_ name: String, red: CGFloat, transparent: Bool = false) throws -> URL {
        let context = CGContext(data: nil, width: 4096, height: 2048, bitsPerComponent: 8, bytesPerRow: 4096 * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: red, green: 0.2, blue: 1 - red, alpha: transparent ? 0 : 1)
        context.fill(CGRect(x: 0, y: 0, width: 4096, height: 2048))
        let url = directory.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        return url
    }
    let red = try writeImage("red.png", red: 1)
    let blue = try writeImage("blue.png", red: 0)
    let transparent = try writeImage("transparent.png", red: 0, transparent: true)
    let original = try Data(contentsOf: red)
    let attachment = try await ImageProcessing.importAttachment(from: red)
    precondition(attachment.data == original, "Upload bytes were replaced by preview")
    precondition(attachment.preview.size.width <= 512 && attachment.preview.size.height <= 512)
    let wallpaper = ImageProcessing.thumbnail(from: red, maxPixelSize: 1800)!
    precondition(wallpaper.size.width <= 1800 && wallpaper.size.height <= 1800)

    ImageHTTP.payload.withLock { $0 = original }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ImageHTTP.self]
    configuration.urlCache = nil
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let cache = ImageCacheService(session: session)
    let url = URL(string: "https://images.invalid/avatar")!
    async let first = cache.fetchImage(for: url)
    async let second = cache.fetchImage(for: url)
    let (a, b) = await (first, second)
    precondition(a != nil && a === b)
    precondition(a!.size.width <= 160)
    precondition(ImageHTTP.requests.withLock { $0 } == 1)
    _ = await cache.fetchImage(for: url)
    precondition(ImageHTTP.requests.withLock { $0 } == 1)

    let suite = "Verification.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let persisted = directory.appendingPathComponent("saved.png")
    let preferences = AppPreferences(defaults: defaults, wallpaperURL: persisted)
    preferences.setCustomWallpaper(from: red)
    preferences.setCustomWallpaper(from: blue)
    for _ in 0..<200 {
        if preferences.customWallpaper != nil { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    precondition(preferences.backgroundMode == .customWallpaper)
    let color = preferences.customWallpaper!.averageColor()!.usingColorSpace(.sRGB)!
    precondition(color.blueComponent > color.redComponent, "Older wallpaper replaced newer selection")
    precondition(preferences.customWallpaper!.size.width <= 1800)
    preferences.setCustomWallpaper(from: red)
    preferences.clearCustomWallpaper()
    try await Task.sleep(for: .milliseconds(200))
    precondition(preferences.customWallpaper == nil && preferences.backgroundMode == .solidColor)
    precondition(!FileManager.default.fileExists(atPath: persisted.path))

    // A transparent image is still valid even when average color is unavailable.
    try FileManager.default.copyItem(at: transparent, to: persisted)
    defaults.set("customWallpaper", forKey: "preferences.backgroundMode")
    let reloaded = AppPreferences(defaults: defaults, wallpaperURL: persisted)
    for _ in 0..<200 {
        if reloaded.customWallpaper != nil { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    precondition(reloaded.customWallpaper != nil && reloaded.backgroundMode == .customWallpaper)
    let corrupt = directory.appendingPathComponent("corrupt.png")
    try Data("not-an-image".utf8).write(to: corrupt)
    let failed = AppPreferences(defaults: defaults, wallpaperURL: corrupt)
    for _ in 0..<200 {
        if failed.backgroundMode == .solidColor { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    precondition(failed.backgroundMode == .solidColor)
    print("Attachment originals/previews, avatar bounds/deduplication and wallpaper race/reload checks passed")
}
