import Foundation
import ZipArchive
import SystemPackage

struct CharacterAIAccountExportImportResult {
    let importedCount: Int
    let skippedCount: Int
    let missingDefinitionCount: Int
}

enum CharacterAIAccountExportError: LocalizedError {
    case invalidExport
    case invalidZip
    case characterFileNotFound
    case ambiguousCharacterFiles
    case exportTooLarge
    case noUsableCharacters

    var errorDescription: String? {
        switch self {
        case .invalidExport:
            "This does not look like a Character.AI character export. Select the character.json file from your extracted account export."
        case .invalidZip:
            "This ZIP file could not be read. Check that it is a valid, unencrypted Character.AI account export."
        case .characterFileNotFound:
            "No character.json file was found in the export."
        case .ambiguousCharacterFiles:
            "More than one character JSON file was found in the export. Select an extracted character.json file instead."
        case .exportTooLarge:
            "The character export is too large to import safely."
        case .noUsableCharacters:
            "The export did not contain any characters with a name and stable ID."
        }
    }
}

enum CharacterAIAccountExportImporter {
    private static let maximumFileSize = 100 * 1024 * 1024
    private static let maximumArchiveSize = 2 * 1024 * 1024 * 1024

    static func readCharacters(
        from url: URL,
        existing: [String: LocalCharacter]
    ) throws -> (characters: [LocalCharacter], result: CharacterAIAccountExportImportResult) {
        let data: Data
        if url.pathExtension.lowercased() == "zip" {
            data = try characterData(in: url)
        } else {
            let fileURL = try characterFile(in: url)
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { throw CharacterAIAccountExportError.invalidExport }
            guard (values.fileSize ?? 0) <= maximumFileSize else { throw CharacterAIAccountExportError.exportTooLarge }
            data = try Data(contentsOf: fileURL)
        }
        let json = try JSONSerialization.jsonObject(with: data)
        let extracted = try records(in: json)
        var characters: [LocalCharacter] = []
        var skipped = extracted.skipped
        var missingDefinitions = 0

        for row in extracted.rows {
            do {
                let id = LocalCharacter.accountExportID(in: row)
                let character = try LocalCharacter(
                    accountExportRecord: row,
                    existing: existing[id]
                )
                if character.definition.isEmpty { missingDefinitions += 1 }
                characters.append(character)
            } catch {
                skipped += 1
            }
        }
        guard !characters.isEmpty else { throw CharacterAIAccountExportError.noUsableCharacters }
        return (characters, CharacterAIAccountExportImportResult(
            importedCount: characters.count,
            skippedCount: skipped,
            missingDefinitionCount: missingDefinitions
        ))
    }

    private static func characterData(in url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw CharacterAIAccountExportError.invalidExport }
        guard (values.fileSize ?? 0) <= maximumArchiveSize else { throw CharacterAIAccountExportError.exportTooLarge }

        do {
            return try ZipArchiveReader.withFile(url.path) { reader in
                let files = try reader.readDirectory().filter { file in
                    guard !file.isDirectory else { return false }
                    let components = file.filename.string.split(separator: "/")
                    guard let name = components.last?.lowercased(),
                          ["character.json", "characters.json"].contains(name) else { return false }
                    return components.count == 1 || components.dropLast().contains("data")
                }
                guard !files.isEmpty else { throw CharacterAIAccountExportError.characterFileNotFound }
                guard files.count == 1, let file = files.first else {
                    throw CharacterAIAccountExportError.ambiguousCharacterFiles
                }
                guard file.uncompressedSize >= 0,
                      file.uncompressedSize <= Int64(maximumFileSize) else {
                    throw CharacterAIAccountExportError.exportTooLarge
                }
                return Data(try reader.readFile(file))
            }
        } catch let error as CharacterAIAccountExportError {
            throw error
        } catch {
            throw CharacterAIAccountExportError.invalidZip
        }
    }

    private static func characterFile(in url: URL) throws -> URL {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            guard ["character.json", "characters.json"].contains(url.lastPathComponent.lowercased()) else {
                throw CharacterAIAccountExportError.invalidExport
            }
            return url
        }

        var matches: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw CharacterAIAccountExportError.characterFileNotFound
        }
        for case let candidate as URL in enumerator {
            guard ["character.json", "characters.json"].contains(candidate.lastPathComponent.lowercased()),
                  let candidateValues = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  candidateValues.isRegularFile == true,
                  candidateValues.isSymbolicLink != true else { continue }
            matches.append(candidate)
            if matches.count > 1 { throw CharacterAIAccountExportError.ambiguousCharacterFiles }
        }
        guard let match = matches.first else { throw CharacterAIAccountExportError.characterFileNotFound }
        return match
    }

    private static func records(in value: Any) throws -> (rows: [[String: Any]], skipped: Int) {
        if let array = value as? [Any] {
            let rows = array.compactMap { $0 as? [String: Any] }
            return (rows, array.count - rows.count)
        }
        guard let object = value as? [String: Any] else { throw CharacterAIAccountExportError.invalidExport }

        if isCharacter(object) { return ([object], 0) }
        for key in ["characters", "character", "data"] {
            if let nested = object[key] {
                return try records(in: nested)
            }
        }

        let entries = object.compactMap { key, value -> [String: Any]? in
            guard var row = value as? [String: Any] else { return nil }
            if !hasIdentifier(row) { row["id"] = key }
            return row
        }
        guard !entries.isEmpty else { throw CharacterAIAccountExportError.invalidExport }
        return (entries, object.count - entries.count)
    }

    private static func isCharacter(_ row: [String: Any]) -> Bool {
        ["name", "title", "character_name", "characterName"].contains { row[$0] != nil }
    }

    private static func hasIdentifier(_ row: [String: Any]) -> Bool {
        ["external_id", "externalId", "character_id", "characterId", "id", "uuid"].contains { row[$0] != nil }
    }
}
