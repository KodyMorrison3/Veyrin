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
