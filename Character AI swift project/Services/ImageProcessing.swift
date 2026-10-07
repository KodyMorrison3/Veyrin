import AppKit
import Foundation
import ImageIO

nonisolated enum ImageProcessing {
    static func thumbnail(from data: Data, maxPixelSize: Int) -> NSImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        return thumbnail(from: source, maxPixelSize: maxPixelSize)
    }

    static func thumbnail(from url: URL, maxPixelSize: Int) -> NSImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { return nil }
        return thumbnail(from: source, maxPixelSize: maxPixelSize)
    }

    private static func thumbnail(from source: CGImageSource, maxPixelSize: Int) -> NSImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    @concurrent
    static func decodedThumbnail(from data: Data, maxPixelSize: Int) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        return thumbnail(from: data, maxPixelSize: maxPixelSize)
    }

    struct Attachment: Identifiable, Sendable {
        let id = UUID()
        let fileName: String
        let preview: NSImage
        let data: Data
    }

    @concurrent
    static func importAttachment(from url: URL) async throws -> Attachment {
        try Task.checkCancellation()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Own the selected bytes; do not retain a mapping of an external
        // file that may later be changed or removed by its owner.
        let data = try Data(contentsOf: url)
        guard let preview = thumbnail(from: data, maxPixelSize: 512) else {
            throw NetworkError.serverMessage("The selected image could not be decoded.")
        }
        try Task.checkCancellation()
        return Attachment(fileName: url.lastPathComponent, preview: preview, data: data)
    }
}
