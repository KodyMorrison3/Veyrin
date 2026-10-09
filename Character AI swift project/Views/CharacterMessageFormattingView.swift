import AppKit
import SwiftUI

struct CharacterMessageFormattingView: View {
    let content: String
    // Message bubbles fit short text; other consumers retain the original layout.
    var expandsToFill = true
    var isStreaming = false

    enum FormattedBlock {
        case paragraph(AttributedString)
        case heading(AttributedString)
        case list(ordered: Bool, items: [AttributedString])
        case code(language: String, content: String)
    }

    private final class CachedFormatting: NSObject {
        let blocks: [FormattedBlock]
        init(_ blocks: [FormattedBlock]) { self.blocks = blocks }
    }
    // MainActor-only values include SwiftUI Font/Color attributes. The fixed
    // styling recipe is independent of layout, locale and light/dark mode.
    private static let completedFormatting: NSCache<NSString, CachedFormatting> = {
        let cache = NSCache<NSString, CachedFormatting>()
        cache.countLimit = 128
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    static func clearCache() { completedFormatting.removeAllObjects() }

    func formattedBlocks() -> [FormattedBlock] {
        let key = content as NSString
        if !isStreaming, let cached = Self.completedFormatting.object(forKey: key) { return cached.blocks }
        let blocks = CharacterMessageMarkdown.parse(content, cacheCompletedContent: !isStreaming).map { block in
            switch block {
            case .paragraph(let inline): return FormattedBlock.paragraph(attributedString(for: inline))
            case .heading(let level, let inline): return .heading(attributedString(for: inline, font: headingFont(level)))
            case .list(let ordered, let items): return .list(ordered: ordered, items: items.map { attributedString(for: $0) })
            case .code(let language, let code): return .code(language: language, content: code)
            }
        }
        if !isStreaming {
            // Include source, runs and parse overhead conservatively; NSCache
            // cost is an estimate, not a precise heap measurement.
            Self.completedFormatting.setObject(CachedFormatting(blocks), forKey: key,
                                               cost: max(content.utf8.count * 8, 1))
        }
        return blocks
    }

    @State private var pendingURL: URL?

    var body: some View {
        let blocks = formattedBlocks()
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks.indices, id: \.self) { index in
                blockView(blocks[index])
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            guard CharacterMessageMarkdown.safeExternalURL(url.absoluteString) != nil else {
                return .discarded
            }
            pendingURL = url
            return .handled
        })
        .confirmationDialog(
            "Open external link?",
            isPresented: Binding(
                get: { pendingURL != nil },
                set: { if !$0 { pendingURL = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Open Link") {
                guard let pendingURL,
                      CharacterMessageMarkdown.safeExternalURL(pendingURL.absoluteString) != nil else {
                    self.pendingURL = nil
                    return
                }
                NSWorkspace.shared.open(pendingURL)
                self.pendingURL = nil
            }
            Button("Cancel", role: .cancel) {
                pendingURL = nil
            }
        } message: {
            Text(pendingURL?.host ?? "This destination is not supported.")
        }
    }

    @ViewBuilder
    private func blockView(_ block: FormattedBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(text)
                .lineSpacing(4)
                .frame(maxWidth: expandsToFill ? .infinity : nil, alignment: .leading)

        case .heading(let text):
            Text(text)
                .frame(maxWidth: expandsToFill ? .infinity : nil, alignment: .leading)

        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(ordered ? "\(index + 1)." : "•")
                            .frame(minWidth: 18, alignment: .trailing)
                        Text(items[index])
                            .lineSpacing(4)
                            .frame(maxWidth: expandsToFill ? .infinity : nil, alignment: .leading)
                    }
                }
            }
            .padding(.leading, 8)

        case .code(let language, let code):
            codeBlock(language: language, code: code)
        }
    }

    private func attributedString(
        for inlines: [CharacterMessageMarkdown.Inline],
        font: Font = .body,
        bold: Bool = false,
        italic: Bool = false
    ) -> AttributedString {
        var result = AttributedString()
        for inline in inlines {
            switch inline {
            case .text(let value):
                var part = AttributedString(value)
                part.font = styledFont(font, bold: bold, italic: italic)
                result.append(part)

            case .emphasis(let children):
                result.append(attributedString(
                    for: children,
                    font: font,
                    bold: bold,
                    italic: true
                ))

            case .strong(let children):
                result.append(attributedString(
                    for: children,
                    font: font,
                    bold: true,
                    italic: italic
                ))

            case .code(let value):
                var part = AttributedString(value)
                part.font = .system(.body, design: .monospaced)
                part.backgroundColor = Color.secondary.opacity(0.15)
                result.append(part)

            case .link(let label, let destination):
                var part = attributedString(for: label, font: font, bold: bold, italic: italic)
                if let url = CharacterMessageMarkdown.safeExternalURL(destination) {
                    part.link = url
                    part.underlineStyle = .single
                    part.foregroundColor = .blue
                } else {
                    part = AttributedString("Unsupported link")
                    part.font = styledFont(font, bold: bold, italic: italic)
                }
                result.append(part)
            }
        }
        return result
    }

    private func styledFont(_ font: Font, bold: Bool, italic: Bool) -> Font {
        var result = font
        if bold { result = result.bold() }
        if italic { result = result.italic() }
        return result
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title
        case 2: .title2
        default: .title3
        }
    }

    private func codeBlock(language: String, code: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.secondary.opacity(0.12))

            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .frame(maxWidth: expandsToFill ? .infinity : nil, alignment: .leading)
                    .padding(10)
            }
            .background(Color.black.opacity(0.88))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
