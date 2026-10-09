import Foundation

@MainActor
enum MarkdownChecks {
    static func run() {
        typealias Inline = CharacterMessageMarkdown.Inline
        precondition(CharacterMessageMarkdown.parse("").isEmpty)
        precondition(CharacterMessageMarkdown.parseInline("plain") == [.text("plain")])
        precondition(CharacterMessageMarkdown.parseInline("[**label**](https://example.com)") == [
            .link(label: [.strong([.text("label")])], destination: "https://example.com")
        ])
        precondition(CharacterMessageMarkdown.parseInline("*a* **b** `c`") == [
            .emphasis([.text("a")]), .text(" "), .strong([.text("b")]), .text(" "), .code("c")
        ])
        for size in [1, 1024, 8192, 65536] {
            let value = String(repeating: "[", count: size)
            precondition(CharacterMessageMarkdown.parseInline(value) == [.text(value)])
        }
        let examples = [
            "", "[]", "[[[", "[[label](url)", "[bad] [valid](https://example.com)",
            "[missing](", "***nested***", "**missing", "*a **b** c*", "`code`", "``a`b``",
            "a <script>bad</script> b", "<broken", "a <b>text</b>", "[🙂](https://example.com)",
            "# Heading\n\n- one\n- **two**\n\n```swift\nlet x = 1\n```", "[bad [[ **good** and *text*",
            String(repeating: "[x] ", count: 200), String(repeating: "[x](", count: 200),
            String(repeating: "*x ", count: 200), String(repeating: "<x ", count: 200),
            String(repeating: "`", count: 200), String(repeating: "Valid **bold** [link](https://example.com).\n\n", count: 200)
        ]
        for source in examples {
            precondition(CharacterMessageMarkdown.parse(source) == CharacterMessageMarkdown.parse(source, cacheCompletedContent: false))
            #if BASELINE_COMPARE
            compare(source)
            #endif
        }
        #if BASELINE_COMPARE
        // Small malformed strings cover delimiter combinations, not just the benchmark.
        let alphabet = Array("[]()*`<>a ")
        var seed: UInt64 = 42
        for _ in 0..<10000 {
            var text = ""
            seed = seed &* 6364136223846793005 &+ 1
            let length = Int(seed % 80)
            for _ in 0..<length {
                seed = seed &* 6364136223846793005 &+ 1
                text.append(alphabet[Int(seed % UInt64(alphabet.count))])
            }
            compare(text)
        }
        print("PASS Markdown baseline equivalence: examples and 10,000 seeded malformed strings")
        #endif
        print("PASS Markdown: links, emphasis, code, empty, malformed, long, cached/uncached")
        for size in [1024, 4096, 8192] {
            benchmark("unmatched brackets \(size)", source: String(repeating: "[", count: size))
        }
        benchmark("valid Markdown 8 KiB", source: String(repeating: "A **bold** phrase, *italics*, `code` and [link](https://example.com).\n\n", count: 120))
    }

    #if BASELINE_COMPARE
    private static func compare(_ source: String) {
        let old = String(reflecting: LegacyCharacterMessageMarkdown.parse(source, cacheCompletedContent: false))
            .replacingOccurrences(of: "LegacyCharacterMessageMarkdown", with: "CharacterMessageMarkdown")
        let new = String(reflecting: CharacterMessageMarkdown.parse(source, cacheCompletedContent: false))
        precondition(old == new, "Markdown changed for \(String(reflecting: source))\nOLD \(old)\nNEW \(new)")
    }
    #endif

    private static func benchmark(_ label: String, source: String) {
        #if BASELINE_COMPARE
        measure("before \(label)") { LegacyCharacterMessageMarkdown.parse(source, cacheCompletedContent: false).count }
        #endif
        measure("after \(label)") { CharacterMessageMarkdown.parse(source, cacheCompletedContent: false).count }
    }

    static func measure(_ label: String, repetitions: Int = 7, work: () -> Int) {
        var samples: [Double] = []
        var checksum = 0
        for _ in 0..<repetitions {
            let start = ContinuousClock.now
            checksum &+= work()
            let elapsed = start.duration(to: .now).components
            samples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
        }
        samples.sort()
        print("\(label): median \(String(format: "%.3f", samples[samples.count / 2])) ms, worst \(String(format: "%.3f", samples.last!)) ms, repetitions \(repetitions), checksum \(checksum)")
    }
}
