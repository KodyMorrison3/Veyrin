import AppKit
import Foundation
import SwiftUI

private actor PersonaMessageLog {
    private var stored: [ProviderChatMessage] = []
    func record(_ messages: [ProviderChatMessage]) { stored = messages }
    func snapshot() -> [ProviderChatMessage] { stored }
}

nonisolated private struct PersonaPromptProvider: ChatProvider {
    let log: PersonaMessageLog
    let descriptor = ProviderDescriptor(id: "persona-fixture", name: "Persona Fixture", kind: .ollama,
                                        capabilities: [.textChat, .streaming])

    func models() async throws -> [ModelDescriptor] { [ModelDescriptor(id: "fixture-model")] }

    func stream(model: String, messages: [ProviderChatMessage],
                receive: @escaping @Sendable (ChatStreamEvent) async throws -> Void) async throws {
        await log.record(messages)
        try await receive(.text("Acknowledged"))
        try await receive(.finished)
    }
}

@MainActor
func runPersonaChecks() async throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("VeyrinPersonaChecks-\(UUID().uuidString)")
    let archiveFolder = folder.appendingPathComponent("archive")
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: archiveFolder, withIntermediateDirectories: true)

    let source = Persona(
        id: "persona-ada",
        externalID: "persona-ada",
        displayName: "Ada",
        title: "Concise editor",
        greeting: "Hello, shall we edit?",
        description: "A careful writing partner.",
        definition: "Answer with three short bullet points. Never pad the answer."
    )

    let json = try source.portableJSON()
    let parsedJSON = try PersonaTransfer.parseAll(data: json, filename: "ada.persona.json")
    precondition(parsedJSON.count == 1)
    precondition(parsedJSON[0].displayName == "Ada")
    precondition(parsedJSON[0].description == source.description)
    precondition(parsedJSON[0].definition == source.definition)
    precondition(parsedJSON[0].portableSystemPrompt.contains("three short bullet points"))

    let markdown = Data(source.portableMarkdown.utf8)
    let parsedMarkdown = try PersonaTransfer.parseAll(data: markdown, filename: "ada.md")
    precondition(parsedMarkdown.first?.displayName == "Ada")
    precondition(parsedMarkdown.first?.title == "Concise editor")
    precondition(parsedMarkdown.first?.description == source.description)
    precondition(parsedMarkdown.first?.definition == source.definition)

    let characterCard = Data("""
    {"spec":"chara_card_v2","data":{"name":"Mentor","description":"A patient mentor.",
     "personality":"Calm and direct.","scenario":"Reviewing a pull request.","first_mes":"Ready?"}}
    """.utf8)
    let parsedCard = try PersonaTransfer.parseAll(data: characterCard, filename: "mentor.json")
    precondition(parsedCard.first?.displayName == "Mentor")
    precondition(parsedCard.first?.description == "A patient mentor.")
    let cardDefinition = parsedCard.first?.definition ?? ""
    precondition(cardDefinition.contains("Calm and direct."))
    precondition(cardDefinition.contains("Reviewing a pull request."))
    precondition(parsedCard.first?.greeting == "Ready?")

    let personaFile = archiveFolder.appendingPathComponent("ada.persona.json")
    try json.write(to: personaFile)
    let library = LocalPersonaStore(supportDirectory: folder)
    let imported = try library.importPersonas(from: personaFile)
    precondition(imported.count == 1 && library.personas.count == 1)
    _ = try library.importPersonas(from: personaFile)
    precondition(library.personas.count == 1, "Re-importing the same persona must update rather than duplicate")

    let allFile = archiveFolder.appendingPathComponent("all-personas.json")
    try library.exportAll(to: allFile)
    let restoredLibrary = LocalPersonaStore(supportDirectory: archiveFolder.appendingPathComponent("restored"))
    let restored = try restoredLibrary.importPersonas(from: allFile)
    precondition(restored.count == 1 && restoredLibrary.personas.first?.displayName == "Ada")

    let markdownFile = archiveFolder.appendingPathComponent("ada.md")
    try library.export(source, to: markdownFile)
    let exportedMarkdown = try String(contentsOf: markdownFile, encoding: .utf8)
    precondition(exportedMarkdown.contains("# Ada") && exportedMarkdown.contains("## Definition"))

    try library.delete(library.personas[0])
    precondition(library.personas.isEmpty)

    let log = PersonaMessageLog()
    let chat = ProviderChatViewModel(provider: PersonaPromptProvider(log: log), model: "fixture-model")
    chat.setPersona(source)
    chat.send("Tighten this paragraph")
    for _ in 0..<200 where chat.isGenerating {
        try await Task.sleep(for: .milliseconds(5))
    }
    precondition(!chat.isGenerating)
    let sent = await log.snapshot()
    precondition(sent.first?.role == .system, "An attached persona must be sent as a system message")
    precondition(sent.first?.content.contains("Ada") == true)
    precondition(sent.first?.content.contains("three short bullet points") == true)
    precondition(sent.count == 2 && sent.last?.role == .user)
    chat.setPersona(nil)
    precondition(chat.persona == nil)

    _ = NSApplication.shared
    let suite = "PersonaChecks.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { preconditionFailure("Defaults fixture unavailable") }
    defer { defaults.removePersistentDomain(forName: suite) }
    let accountStore = PersonaStore(defaults: defaults)
    for scheme in [ColorScheme.light, .dark] {
        let host = NSHostingView(rootView: PersonaSettingsView(accountPersonas: accountStore)
            .environment(\.colorScheme, scheme))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 520)
        host.layoutSubtreeIfNeeded()
        precondition(host.fittingSize.width.isFinite && host.fittingSize.height.isFinite)
    }
    print("Persona JSON/Markdown/character-card transfer, local library merge/export, provider system-prompt injection and layout checks passed")
}
