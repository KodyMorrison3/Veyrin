import Foundation

/// Parses only the message formatting verified in the Character.AI frontend investigation.
enum CharacterMessageMarkdown {
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

    static func parse(_ source: String) -> [Block] {
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
                let markerLength = runLength("`" as Swift.Character, in: characters, at: index)
                let marker = String(repeating: "`", count: markerLength)
                if let end = find(marker, in: characters, from: index + markerLength) {
                    flush()
                    let code = String(characters[(index + markerLength)..<end])
                    result.append(.code(code.replacingOccurrences(of: "\n", with: " ")))
                    index = end + markerLength
                    continue
                }
            }

            if has("***", in: characters, at: index),
               let end = find("***", in: characters, from: index + 3) {
                flush()
                result.append(.strong([.emphasis(parseInline(String(characters[(index + 3)..<end])))]))
                index = end + 3
                continue
            }

            if has("**", in: characters, at: index),
               let end = find("**", in: characters, from: index + 2) {
                flush()
                result.append(.strong(parseInline(String(characters[(index + 2)..<end]))))
                index = end + 2
                continue
            }

            if characters[index] == ("*" as Swift.Character), !has("**", in: characters, at: index),
               let end = findSingleAsterisk(in: characters, from: index + 1) {
                flush()
                result.append(.emphasis(parseInline(String(characters[(index + 1)..<end]))))
                index = end + 1
                continue
            }

            if characters[index] == ("[" as Swift.Character),
               let closeBracket = characters[(index + 1)...].firstIndex(of: ("]" as Swift.Character)),
               closeBracket + 1 < characters.count,
               characters[closeBracket + 1] == ("(" as Swift.Character),
               let closeParen = characters[(closeBracket + 2)...].firstIndex(of: ")") {
                flush()
                let label = String(characters[(index + 1)..<closeBracket])
                let destination = String(characters[(closeBracket + 2)..<closeParen])
                result.append(.link(label: parseInline(label), destination: destination))
                index = closeParen + 1
                continue
            }

            if characters[index] == ("<" as Swift.Character), let end = htmlTagEnd(in: characters, from: index) {
                index = end + 1
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
            return (false, String(content.dropFirst().drop(while: { $0.isWhitespace })))
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
        let value = Array(marker)
        return index + value.count <= characters.count && Array(characters[index..<(index + value.count)]) == value
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
        guard next.isLetter || next == ("/" as Swift.Character) || next == ("!" as Swift.Character) || next == ("?" as Swift.Character) else { return nil }
        return characters[(start + 1)...].firstIndex(of: (">" as Swift.Character))
    }

}
