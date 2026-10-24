import AppKit
import Foundation

/// Portable persona files let a Character.AI persona move into Veyrin's local
/// and cloud text chats, or into any other AI that accepts a system prompt.
/// The native JSON keeps every field; Markdown is a human-readable prompt.
nonisolated extension Persona {
    static let maxPortableNameLength = 80

    /// A system prompt describing the user's persona to a local or cloud model.
    /// Character.AI uses the same fields server-side; provider chats send this
    /// text instead so the identity stays consistent across providers.
    var portableSystemPrompt: String {
        var lines = ["The user you are speaking with uses the persona “\(displayName)”."]
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           title != displayName {
            lines.append("Title: \(title)")
        }
        if let description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Description: \(description)")
        }
        if let definition, !definition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Definition: \(definition)")
        }
        return lines.joined(separator: "\n\n")
    }

    var portableMarkdown: String {
        var lines = ["# \(displayName)", ""]
        if let title, !title.isEmpty { lines += ["> \(title)", ""] }
        if let description, !description.isEmpty {
            lines += ["## Description", "", description, ""]
        }
        if let definition, !definition.isEmpty {
            lines += ["## Definition", "", definition, ""]
        }
        if let greeting, !greeting.isEmpty {
            lines += ["## Greeting", "", greeting, ""]
        }
        if let avatarData {
            lines += ["## Avatar", "", "data:image/png;base64,\(avatarData.base64EncodedString())", ""]
        } else if let avatarFileName, !avatarFileName.isEmpty {
            lines += ["## Avatar File Name", "", avatarFileName, ""]
        }
        return lines.joined(separator: "\n")
    }

    var portablePayload: [String: Any] {
        var payload: [String: Any] = [
            "id": externalID,
            "display_name": displayName
        ]
        payload["title"] = title
        payload["greeting"] = greeting
        payload["description"] = description
        payload["definition"] = definition
        payload["avatar_file_name"] = avatarFileName
        payload["avatar_data"] = avatarData?.base64EncodedString()
        return payload
    }

    func portableJSON() throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "format": "veyrin.persona",
            "version": 1,
            "persona": portablePayload
        ], options: [.prettyPrinted, .sortedKeys])
    }
}

/// The portable bundle exported from Settings when the user wants a backup of
/// every locally imported persona.
nonisolated enum LocalPersonaArchive {
    static func encode(_ personas: [Persona]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "format": "veyrin.persona-library",
            "version": 1,
            "personas": personas.map(\.portablePayload)
        ], options: [.prettyPrinted, .sortedKeys])
    }
}

nonisolated enum PersonaTransfer {
    /// Personas render at most at 48 points, so 256 pixels is plenty on a
    /// Retina display and keeps the persona library small at launch.
    static let avatarPixelSize = 256

    /// Reads Veyrin persona JSON, character-card JSON, and plain text or
    /// Markdown prompts. A library bundle can contain several personas.
    /// Decoding runs off the main actor because a library can carry images.
    @concurrent static func parseAll(data: Data, filename: String) async throws -> [Persona] {
        let fallbackName = defaultName(for: filename)
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let rows = root["personas"] as? [[String: Any]] {
                let personas = try rows.compactMap { try persona(from: $0, fallbackName: fallbackName) }
                guard !personas.isEmpty else { throw PersonaTransferError.noPersonasFound }
                return personas
            }
            guard let persona = try persona(from: root, fallbackName: fallbackName) else {
                throw PersonaTransferError.unsupportedFile
            }
            return [persona]
        }
        guard let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PersonaTransferError.unsupportedFile
        }
        return [try markdown(text, fallbackName: fallbackName)]
    }

    static func persona(from root: [String: Any], fallbackName: String) throws -> Persona? {
        var record = root
        if let nested = root["persona"] as? [String: Any] {
            record = nested
        } else if let data = root["data"] as? [String: Any],
                  (root["spec"] as? String)?.hasPrefix("chara_card") == true {
            record = data
            if record["name"] == nil { record["name"] = root["name"] }
        }

        let displayName = string(record, keys: ["display_name", "displayName", "name", "title"])
            ?? fallbackName
        var definitionParts: [String] = []
        for (key, heading) in [("personality", "Personality"), ("scenario", "Scenario"),
                               ("mes_example", "Example dialogue"), ("definition", "Definition")] {
            guard let value = string(record, keys: [key]) else { continue }
            if key == "definition" && definitionParts.isEmpty {
                definitionParts.append(value)
            } else if !definitionParts.contains(where: { $0.contains(value) }) {
                definitionParts.append("\(heading):\n\(value)")
            }
        }
        let definition = definitionParts.joined(separator: "\n\n")
        let description = string(record, keys: ["description", "summary", "tagline"])
        guard !definition.isEmpty || description != nil else { return nil }

        let portableID = string(record, keys: ["external_id", "externalID", "id"])
            ?? UUID().uuidString
        return Persona(
            id: portableID,
            externalID: portableID,
            displayName: clamped(displayName, to: Persona.maxPortableNameLength),
            title: string(record, keys: ["title", "tagline"]),
            greeting: string(record, keys: ["greeting", "first_mes"]),
            description: description,
            definition: definition.isEmpty ? nil : definition,
            avatarFileName: string(record, keys: ["avatar_file_name", "avatarFileName"]),
            avatarData: try avatarData(record["avatar_data"]),
            isDefaultUser: false
        )
    }

    static func markdown(_ text: String, fallbackName: String) throws -> Persona {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var name = fallbackName
        var title: String?
        var sections: [String: [String]] = [:]
        var currentSection: String?
        var preamble: [String] = []

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if index == 0, trimmed.hasPrefix("# ") {
                name = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if trimmed.hasPrefix("## ") {
                currentSection = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces).lowercased()
                continue
            }
            if currentSection == nil, trimmed.hasPrefix(">") {
                let value = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { title = value }
                continue
            }
            if let currentSection {
                sections[currentSection, default: []].append(line)
            } else if !trimmed.isEmpty {
                preamble.append(line)
            }
        }

        func section(_ keys: [String]) -> String? {
            for key in keys {
                if let value = sections[key]?.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !value.isEmpty { return value }
            }
            return nil
        }

        let description = section(["description"])
        var definition = section(["definition", "instructions", "system instructions", "prompt"])
        let extraSections = ["personality", "scenario", "example dialogue"]
            .compactMap { key in section([key]).map { "\(key.capitalized):\n\($0)" } }
        if definition == nil { definition = extraSections.isEmpty ? preamble.joined(separator: "\n") : nil }
        if let base = definition, !extraSections.isEmpty {
            definition = ([base] + extraSections).joined(separator: "\n\n")
        } else if definition == nil, !extraSections.isEmpty {
            definition = extraSections.joined(separator: "\n\n")
        }

        let portableID = UUID().uuidString
        return Persona(
            id: portableID,
            externalID: portableID,
            displayName: clamped(name, to: Persona.maxPortableNameLength),
            title: title,
            greeting: section(["greeting"]),
            description: description,
            definition: definition?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? definition : nil,
            avatarFileName: section(["avatar file name"]),
            avatarData: try avatarData(section(["avatar"]), lenient: true),
            isDefaultUser: false
        )
    }

    static func avatarPNG(from image: NSImage) throws -> Data {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw PersonaTransferError.invalidAvatar
        }
        return png
    }

    private static func avatarData(_ value: Any?, lenient: Bool = false) throws -> Data? {
        guard let value, !(value is NSNull) else { return nil }
        guard let text = value as? String else {
            if lenient { return nil }
            throw PersonaTransferError.invalidAvatar
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Files written by other tools often use an empty field for "no picture".
        if trimmed.isEmpty { return nil }
        guard let encoded = embeddedBase64(trimmed) else {
            // A hand-written "## Avatar" note is prose, not a broken picture.
            if lenient { return nil }
            throw PersonaTransferError.invalidAvatar
        }
        guard encoded.utf8.count <= 6 * 1024 * 1024,
              let data = Data(base64Encoded: encoded), data.count <= 4 * 1024 * 1024,
              let image = ImageProcessing.thumbnail(from: data, maxPixelSize: avatarPixelSize) else {
            if lenient { return nil }
            throw PersonaTransferError.invalidAvatar
        }
        return try avatarPNG(from: image)
    }

    private static func embeddedBase64(_ text: String) -> String? {
        if text.hasPrefix("data:image/"), let comma = text.firstIndex(of: ","),
           text[..<comma].hasSuffix(";base64") {
            return String(text[text.index(after: comma)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        guard text.count >= 64, text.allSatisfy({ alphabet.contains($0) }) else { return nil }
        return text
    }

    private static func string(_ record: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = record[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func defaultName(for filename: String) -> String {
        let name = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Imported Persona" : clamped(name, to: Persona.maxPortableNameLength)
    }

    private static func clamped(_ text: String, to limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit))
    }
}

nonisolated enum PersonaTransferError: LocalizedError, Equatable {
    case unsupportedFile
    case noPersonasFound
    case invalidAvatar
    case avatarUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedFile:
            "This file is not a Veyrin persona, a character-card JSON, or a text prompt."
        case .noPersonasFound:
            "No personas were found in this file."
        case .invalidAvatar:
            "The persona image is invalid or larger than 4 MiB. Existing personas have not been changed."
        case .avatarUnavailable:
            "The persona image could not be loaded. Connect to the internet and retry the export; the destination file has not been changed."
        }
    }
}
