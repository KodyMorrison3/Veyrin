import Foundation

/// Parses only the message formatting verified in the Character.AI frontend investigation.
enum CharacterMessageMarkdown {
    private final class CachedBlocks: NSObject {
        let value: [Block]
        init(_ value: [Block]) { self.value = value }
    }

    private static let parsedBlocks: NSCache<NSString, CachedBlocks> = {
        let cache = NSCache<NSString, CachedBlocks>()
        cache.countLimit = 128
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()

    indirect enum Inline: Equatable {
        case text(String)
        case emphasis([Inline])
        case strong([Inline])
        case code(String)
        case link(label: [Inline], destination: String)
    }

    enum Block: Equatable {
        case paragraph([Inline])
        case heading(level: Int, content: [Inline])
        case list(ordered: Bool, items: [[Inline]])
        case code(language: String, content: String)
    }

    static func clearCache() { parsedBlocks.removeAllObjects() }

    static func parse(_ source: String, cacheCompletedContent: Bool = true) -> [Block] {
        guard cacheCompletedContent else { return parseUncached(source) }
        let key = source as NSString
        if let cached = parsedBlocks.object(forKey: key) {
            return cached.value
        }
        let blocks = parseUncached(source)
        parsedBlocks.setObject(CachedBlocks(blocks), forKey: key, cost: max(source.utf8.count * 4, 1))
        return blocks
    }

    private static func parseUncached(_ source: String) -> [Block] {
        let lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var blocks: [Block] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else {
                index += 1
                continue
            }

            if isFence(line) {
                let fence = line.drop(while: { $0 == " " || $0 == "\t" })
                let info = String(fence.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                let token = info.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
                let language = token.hasPrefix("language-") ? String(token.dropFirst(9)) : token
                index += 1
                var codeLines: [String] = []
                while index < lines.count, !isFence(lines[index]) {
                    codeLines.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(.code(
                    language: language.isEmpty ? "javascript" : language,
                    content: codeLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                ))
                continue
            }

            if isHTMLBlock(line) {
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    index += 1
                }
                continue
            }

            if containsHTMLTag(line) {
                blocks.append(.paragraph(parseInline(line)))
                index += 1
                continue
            }

            if let heading = heading(in: line) {
                blocks.append(.heading(level: heading.level, content: parseInline(heading.content)))
                index += 1
                continue
            }

            if let firstItem = listItem(in: line) {
                var items = [parseInline(firstItem.content)]
                index += 1
                while index < lines.count,
                      let item = listItem(in: lines[index]),
                      item.ordered == firstItem.ordered {
                    items.append(parseInline(item.content))
                    index += 1
                }
                blocks.append(.list(ordered: firstItem.ordered, items: items))
                continue
            }

            var paragraphLines = [line]
            index += 1
            while index < lines.count,
                  !lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                  !isFence(lines[index]),
                  !isHTMLBlock(lines[index]),
                  !containsHTMLTag(lines[index]),
                  heading(in: lines[index]) == nil,
                  listItem(in: lines[index]) == nil {
                paragraphLines.append(lines[index])
                index += 1
            }
            blocks.append(.paragraph(parseInline(paragraphLines.joined(separator: "\n"))))
        }
        return blocks
    }

    static func parseInline(_ source: String) -> [Inline] {
        let characters: [Swift.Character] = Array(source)
        var result: [Inline] = []
        var plain = ""
        var index = 0
        var closingBracket = -1
        var closingParen = -1
        var closingTag = -1
        var exhaustedMarkers: Set<String> = []
        var codeRunEnd = 0
        var exhaustedEmphasis = false

        // Search positions only move forward. Incomplete links must not scan
        // the same suffix again for every opening bracket in a streamed reply.
        func next(_ delimiter: Swift.Character, from start: Int, cursor: inout Int) -> Int? {
            if cursor < start {
                cursor = characters[start...].firstIndex(of: delimiter) ?? characters.count
            }
            return cursor < characters.count ? cursor : nil
        }

        func closingMarker(_ marker: String, from start: Int) -> Int? {
            guard !exhaustedMarkers.contains(marker) else { return nil }
            if let end = find(marker, in: characters, from: start) { return end }
            exhaustedMarkers.insert(marker)
            return nil
        }

        func flush() {
            guard !plain.isEmpty else { return }
            if case .text(let previous)? = result.last {
                result[result.count - 1] = .text(previous + plain)
            } else {
                result.append(.text(plain))
            }
            plain = ""
        }

        while index < characters.count {
            if characters[index] == ("`" as Swift.Character) {
                if codeRunEnd <= index {
                    codeRunEnd = index + runLength("`", in: characters, at: index)
                }
                let markerLength = codeRunEnd - index
                let marker = markerLength <= characters.count - codeRunEnd
                    ? String(repeating: "`", count: markerLength) : ""
                if !marker.isEmpty, let end = closingMarker(marker, from: codeRunEnd) {
                    flush()
                    let code = String(characters[(index + markerLength)..<end])
                    result.append(.code(code.replacingOccurrences(of: "\n", with: " ")))
                    index = end + markerLength
                    continue
                }
            }

            if has("***", in: characters, at: index),
               let end = closingMarker("***", from: index + 3) {
                flush()
                result.append(.strong([.emphasis(parseInline(String(characters[(index + 3)..<end])))]))
                index = end + 3
                continue
            }

            if has("**", in: characters, at: index),
               let end = closingMarker("**", from: index + 2) {
                flush()
                result.append(.strong(parseInline(String(characters[(index + 2)..<end]))))
                index = end + 2
                continue
            }

            if characters[index] == ("*" as Swift.Character), !has("**", in: characters, at: index),
               !exhaustedEmphasis {
                if let end = findSingleAsterisk(in: characters, from: index + 1) {
                    flush()
                    result.append(.emphasis(parseInline(String(characters[(index + 1)..<end]))))
                    index = end + 1
                    continue
                }
                exhaustedEmphasis = true
            }

            if characters[index] == ("[" as Swift.Character),
               let closeBracket = next("]", from: index + 1, cursor: &closingBracket),
               closeBracket + 1 < characters.count,
               characters[closeBracket + 1] == ("(" as Swift.Character),
               let closeParen = next(")", from: closeBracket + 2, cursor: &closingParen) {
                flush()
                let label = String(characters[(index + 1)..<closeBracket])
                let destination = String(characters[(closeBracket + 2)..<closeParen])
                result.append(.link(label: parseInline(label), destination: destination))
                index = closeParen + 1
                continue
            }

            if characters[index] == ("<" as Swift.Character),
               let end = next(">", from: index + 1, cursor: &closingTag),
               isHTMLTagName(in: characters, from: index + 1, through: end) {
                if let contentEnd = rawHTMLContentEnd(
                    in: characters,
                    tagStart: index,
                    openingTagEnd: end
                ) {
                    index = contentEnd
                } else {
                    index = end + 1
                }
                continue
            }

            plain.append(characters[index])
            index += 1
        }
        flush()
        return result
    }

    static func safeExternalURL(_ destination: String) -> URL? {
        guard !destination.contains(where: { $0.isWhitespace || $0.isNewline }),
              let components = URLComponents(string: destination),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              host != "localhost",
              !host.hasSuffix(".local"),
              let url = components.url else { return nil }
        return url
    }

    private static func isFence(_ line: String) -> Bool {
        line.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("```")
    }

    private static func containsHTMLTag(_ line: String) -> Bool {
        let characters = Array(line)
        var closingTag = -1
        for index in characters.indices where characters[index] == "<" {
            if closingTag <= index {
                closingTag = characters[(index + 1)...].firstIndex(of: ">") ?? characters.count
            }
            if closingTag < characters.count,
               isHTMLTagName(in: characters, from: index + 1, through: closingTag) { return true }
        }
        return false
    }

    private static func isHTMLBlock(_ line: String) -> Bool {
        let content = line.trimmingCharacters(in: .whitespaces)
        guard content.first == "<", content.count > 1 else { return false }
        let next = content[content.index(after: content.startIndex)]
        return next.isLetter || next == "/" || next == "!" || next == "?"
    }

    private static func heading(in line: String) -> (level: Int, content: String)? {
        let content = line.drop(while: { $0 == " " || $0 == "\t" })
        let level = content.prefix(while: { $0 == "#" }).count
        guard (1...3).contains(level), content.count > level,
              content[content.index(content.startIndex, offsetBy: level)].isWhitespace else { return nil }
        return (level, String(content.dropFirst(level).drop(while: { $0.isWhitespace })))
    }

    private static func listItem(in line: String) -> (ordered: Bool, content: String)? {
        let content = line.drop(while: { $0 == " " || $0 == "\t" })
        guard let first = content.first else { return nil }
        if (first == "-" || first == "*" || first == "+"), content.dropFirst().first?.isWhitespace == true {
            let item = String(content.dropFirst().drop(while: { $0.isWhitespace }))
            if item.hasPrefix("[ ] ") || item.hasPrefix("[x] ") || item.hasPrefix("[X] ") {
                return (false, "- " + item)
            }
            return (false, item)
        }
        let digits = content.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count < content.count else { return nil }
        let next = content[content.index(content.startIndex, offsetBy: digits.count)]
        guard next == "." || next == ")",
              content.dropFirst(digits.count + 1).first?.isWhitespace == true else { return nil }
        return (true, String(content.dropFirst(digits.count + 1).drop(while: { $0.isWhitespace })))
    }

    private static func runLength(_ marker: Swift.Character, in characters: [Swift.Character], at index: Int) -> Int {
        var end = index
        while end < characters.count, characters[end] == marker { end += 1 }
        return end - index
    }

    private static func has(_ marker: String, in characters: [Swift.Character], at index: Int) -> Bool {
        guard index + marker.count <= characters.count else { return false }
        return marker.enumerated().allSatisfy { characters[index + $0.offset] == $0.element }
    }

    private static func find(_ marker: String, in characters: [Swift.Character], from start: Int) -> Int? {
        guard start <= characters.count else { return nil }
        var index = start
        while index + marker.count <= characters.count {
            if has(marker, in: characters, at: index) { return index }
            index += 1
        }
        return nil
    }

    private static func findSingleAsterisk(in characters: [Swift.Character], from start: Int) -> Int? {
        var index = start
        while index < characters.count {
            if has("**", in: characters, at: index) {
                index += 2
            } else if characters[index] == ("*" as Swift.Character) {
                return index
            } else {
                index += 1
            }
        }
        return nil
    }

    private static func htmlTagEnd(in characters: [Swift.Character], from start: Int) -> Int? {
        guard start + 1 < characters.count else { return nil }
        let next = characters[start + 1]
        guard next.isLetter || next == ("/" as Swift.Character) || next == ("!" as Swift.Character) || next == ("?" as Swift.Character),
              let end = characters[(start + 1)...].firstIndex(of: (">" as Swift.Character)),
              isHTMLTagName(in: characters, from: start + 1, through: end) else { return nil }
        return end
    }

    private static func isHTMLTagName(
        in characters: [Swift.Character],
        from start: Int,
        through end: Int
    ) -> Bool {
        guard start < end else { return false }
        var index = start
        if characters[index] == "/" || characters[index] == "!" || characters[index] == "?" {
            index += 1
        }
        guard index < end, characters[index].isLetter else { return false }
        while index < end {
            let character = characters[index]
            if character.isWhitespace || character == "/" { return true }
            guard character.isLetter || character.isNumber || character == "-" || character == "_" else {
                return false
            }
            index += 1
        }
        return true
    }

    private static func rawHTMLContentEnd(
        in characters: [Swift.Character],
        tagStart: Int,
        openingTagEnd: Int
    ) -> Int? {
        guard tagStart + 1 < characters.count,
              characters[tagStart + 1] != "/" else { return nil }
        let nameStart = tagStart + 1
        var nameEnd = nameStart
        while nameEnd < openingTagEnd,
              !characters[nameEnd].isWhitespace,
              characters[nameEnd] != "/" {
            nameEnd += 1
        }
        let name = String(characters[nameStart..<nameEnd]).lowercased()
        guard name == "script" || name == "style" else { return nil }

        let closingTag = Array("</\(name)>")
        var index = openingTagEnd + 1
        while index + closingTag.count <= characters.count {
            let matches = closingTag.enumerated().allSatisfy { offset, expected in
                String(characters[index + offset]).lowercased() == String(expected)
            }
            if matches { return index + closingTag.count }
            index += 1
        }
        return characters.count
    }

}
