import SwiftUI
import AppKit

struct CachedAvatarView<Placeholder: View>: View {
    let url: URL?
    let placeholder: () -> Placeholder

    @State private var loadedImage: NSImage?
    @State private var loadedURL: URL?

    init(url: URL?, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let loadedImage, loadedURL == url {
                Image(nsImage: loadedImage).resizable().scaledToFill()
            } else { placeholder() }
        }
        .task(id: url) {
            loadedImage = nil
            loadedURL = nil
            guard let url else { return }
            let image = await ImageCacheService.shared.fetchImage(for: url)
            guard !Task.isCancelled else { return }
            loadedURL = url
            loadedImage = image
        }
    }
}

/// Feed and Discover media through ImageCacheService, decoded at `maxPixelSize`.
/// Keeps loading and failure as separate states so each can show its own content.
struct CachedRemoteImage<Content: View, Placeholder: View, Failure: View>: View {
    let url: URL
    let maxPixelSize: Int
    private let cacheService: ImageCacheService
    let content: (Image) -> Content
    let placeholder: () -> Placeholder
    let failure: () -> Failure

    @State private var state: LoadState = .loading

    private struct Request: Hashable {
        let url: URL
        let maxPixelSize: Int
    }
    private var request: Request { Request(url: url, maxPixelSize: maxPixelSize) }

    private enum LoadState {
        case loading
        case loaded(Request, NSImage)
        case failed(Request)
    }

    init(
        url: URL,
        maxPixelSize: Int,
        cacheService: ImageCacheService = .shared,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder,
        @ViewBuilder failure: @escaping () -> Failure
    ) {
        self.url = url
        self.maxPixelSize = maxPixelSize
        self.cacheService = cacheService
        self.content = content
        self.placeholder = placeholder
        self.failure = failure
    }

    var body: some View {
        Group {
            switch state {
            case .loaded(let loadedRequest, let image) where loadedRequest == request:
                content(Image(nsImage: image).resizable())
            case .failed(let failedRequest) where failedRequest == request:
                failure()
            default:
                placeholder()
            }
        }
        .task(id: request) {
            let requested = request
            state = .loading
            let image = await cacheService.fetchImage(
                for: requested.url, maxPixelSize: requested.maxPixelSize, pool: .media
            )
            guard !Task.isCancelled else { return }
            state = image.map { .loaded(requested, $0) } ?? .failed(requested)
        }
    }
}
