import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
func runRenderingChecks() throws {
    let cases = [
        "Plain text\nwith a line break",
        "# Heading\n\n**bold** and *emphasis* and `code`",
        "1. First\n2. Second\n\n- One\n- Two",
        "```swift\nlet value = 42\n```",
        "[Safe](https://example.com) and [Unsafe](javascript:alert)",
        "Text <script>alert('not displayed')</script> end",
        "Unicode 👋 café 日本語"
    ]
    func signature(_ blocks: [CharacterMessageFormattingView.FormattedBlock]) -> [String] {
        blocks.map { block in
            switch block {
            case .paragraph(let text): return "p:" + String(text.characters)
            case .heading(let text): return "h:" + String(text.characters)
            case .list(let ordered, let items): return "l:\(ordered):" + items.map { String($0.characters) }.joined(separator: "|")
            case .code(let language, let content): return "c:" + language + ":" + content
            }
        }
    }
    for content in cases {
        precondition(CharacterMessageMarkdown.parse(content) == CharacterMessageMarkdown.parse(content, cacheCompletedContent: false))
        let completed = CharacterMessageFormattingView(content: content).formattedBlocks()
        let cached = CharacterMessageFormattingView(content: content).formattedBlocks()
        let streaming = CharacterMessageFormattingView(content: content, isStreaming: true).formattedBlocks()
        precondition(signature(completed) == signature(cached) && signature(cached) == signature(streaming))
    }
    precondition(CharacterMessageMarkdown.safeExternalURL("javascript:alert(1)") == nil)
    precondition(CharacterMessageMarkdown.safeExternalURL("https://localhost/path") == nil)
    precondition(CharacterMessageMarkdown.safeExternalURL("https://example.com/path") != nil)
    let unsafe = CharacterMessageFormattingView(content: "[Unsafe](javascript:alert)").formattedBlocks()
    precondition(signature(unsafe) == ["p:Unsupported link"])

    let payload = Data("{\"id\":\"post\",\"type\":1,\"participants\":[],\"media_urls\":[],\"reactions\":{\"z\":2,\"a\":1}}".utf8)
    let post = try JSONDecoder().decode(FeedPost.self, from: payload)
    precondition(post.reactionSummary == "a 1  ·  z 2")
    let postWithoutParticipants = Data("{\"id\":\"post\",\"type\":1,\"media_urls\":[]}".utf8)
    let decodedPost = try JSONDecoder().decode(FeedPost.self, from: postWithoutParticipants)
    precondition(decodedPost.participants.isEmpty, "Feed posts without participants must still decode")
    precondition(PresentationDate.parse("2026-10-07T12:00:00Z") != nil)
    precondition(PresentationDate.parse("2026-10-07T12:00:00.123Z") != nil)
    let suite = "Verification.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = AppPreferences(defaults: defaults, wallpaperURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    preferences.glassOpacity = 0.85
    precondition(abs(preferences.glassAppearance.density - preferences.glassDensity) < 0.000001,
                 "Glass snapshot read the previous @Published value")
    preferences.glassOpacity = 0.20
    precondition(abs(preferences.glassAppearance.tintScale - preferences.glassTintScale) < 0.000001)

    let turn = Turn(turnID: "turn", chatID: "chat", authorID: "character", authorName: "Character", isHuman: false,
                    candidates: [Candidate(candidateId: "candidate", rawContent: "Hello", isFinal: true, modelType: nil)], primaryCandidateID: "candidate")
    let state = TurnState(turn)
    var changes = 0
    let subscription = state.objectWillChange.sink { changes += 1 }
    state.update(turn)
    precondition(changes == 0)
    state.update(turn.settingPinned(true))
    precondition(changes == 1 && state.turn.isPinned)
    _ = subscription

    // Render through native NSHostingView/AppKit, not a browser or web wrapper.
    _ = NSApplication.shared
    let root = VStack(alignment: .leading, spacing: 16) {
        Text("Native formatting verification").font(.headline)
        ForEach(cases, id: \.self) { content in
            CharacterMessageFormattingView(content: content, expandsToFill: false)
        }
    }.padding(24).frame(width: 640).environment(\.colorScheme, .light)
    let hosting = NSHostingView(rootView: root)
    hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 1000)
    hosting.layoutSubtreeIfNeeded()
    let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
    let screenshot = bitmap.representation(using: .png, properties: [:])!
    try screenshot.write(to: URL(fileURLWithPath: ".build/native-formatting-light.png"))
    precondition(screenshot.count > 1000)
    print("Streaming/final Markdown, safe links, feed/date output, per-turn observation, glass snapshots and native rendering passed")
}
