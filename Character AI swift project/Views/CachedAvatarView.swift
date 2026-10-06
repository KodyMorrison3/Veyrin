import SwiftUI
import AppKit

/// Bounded-cached avatar view that checks `ImageCacheService` before downloading,
/// avoiding redundant decoding and network calls in repeated rows and headers.
struct CachedAvatarView<Placeholder: View>: View {
    let url: URL?
    let placeholder: () -> Placeholder

    @State private var loadedImage: NSImage?
    @State private var hasFailed = false

    init(url: URL?, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let loadedImage {
                Image(nsImage: loadedImage)
                    .resizable()
                    .scaledToFill()
            } else if hasFailed || url == nil {
                placeholder()
            } else {
                placeholder()
                    .task(id: url) {
                        guard let url else { return }
                        if let cached = ImageCacheService.shared.image(for: url) {
                            self.loadedImage = cached
                            return
                        }
                        if let fetched = await ImageCacheService.shared.fetchImage(for: url) {
                            self.loadedImage = fetched
                        } else {
                            self.hasFailed = true
                        }
                    }
            }
        }
    }
}
