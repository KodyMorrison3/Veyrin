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
private func runRoleplayPersonaChecks(folder: URL, source: Persona, character: LocalCharacter) async throws {
    let suite = "RoleplayChecks.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let root = folder.appendingPathComponent("roleplay")
    let local = LocalPersonaStore(supportDirectory: root)
    let file = folder.appendingPathComponent("roleplay-persona.json")
    try source.portableJSON().write(to: file)
    _ = try await local.importPersonas(from: file)
    let account = PersonaStore(defaults: defaults)
    let saved = RoleplayPersonaSelections(defaults: defaults)
    let reference = RoleplayPersonaReference(source: .local, personaID: source.externalID)
    let context = RoleplayPersonaContext(characterID: character.id, local: local, account: account, saved: saved)
    precondition(context.persona == nil && !context.unavailable)
    context.select(reference)
    precondition(context.persona?.displayName == source.displayName)
    precondition(context.persona?.definition == source.definition)
    let persistedData = defaults.data(forKey: "providers.characterPersonas")!
    precondition(!String(decoding: persistedData, as: UTF8.self).contains(source.definition!),
                 "Selections persist references, never copies of persona definitions")
    let restored = RoleplayPersonaSelections(defaults: defaults)
    let restoredLocal = LocalPersonaStore(supportDirectory: root)
    let reopened = RoleplayPersonaContext(characterID: character.id, local: restoredLocal, account: account, saved: restored)
    precondition(reopened.reference == reference && reopened.persona?.displayName == source.displayName)
    reopened.setCharacter("another-character")
    precondition(reopened.persona == nil, "Each character has its own choice")
    reopened.setCharacter(character.id)
    precondition(reopened.persona?.id == source.id)
    let secondWindow = RoleplayPersonaContext(characterID: character.id, local: local, account: account, saved: saved)
    context.select(nil)
    precondition(secondWindow.persona == nil && !secondWindow.unavailable)
    precondition(RoleplayPersonaSelections(defaults: defaults).selections[character.id] == nil,
                 "No Persona must persist across reopening")
    context.select(reference)
    let temporary = RoleplayPersonaContext(local: local, account: account, saved: saved)
    temporary.select(reference)
    temporary.setCharacter("character-without-persona")
    precondition(temporary.persona == nil && temporary.reference == nil,
                 "A temporary persona must not leak into an unconfigured character")
    temporary.setCharacter(nil)
    precondition(temporary.persona?.id == source.id, "Chats without characters retain their temporary selection")
    let transcript = LocalCharacterConversation(character: character)
    let transport = ProviderHTTPClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProviderStubHTTP.self]
        return config
    }
    let sessionConfig = URLSessionConfiguration.ephemeral
    sessionConfig.protocolClasses = [ProviderStubHTTP.self]
    let session = URLSession(configuration: sessionConfig)
    defer { session.invalidateAndCancel() }
    let ollama = try LocalOllamaService(baseURL: URL(string: ProviderEndpoint.defaultOllama), session: session,
                                       startsApplicationWhenUnavailable: false)
    ProviderStubHTTP.configure(#"{"message":{"role":"assistant","content":"Local reply"}}"#)
    let reply = try await ollama.reply(model: "fixture", character: character,
                                       messages: transcript.messages + [LocalChatMessage(role: "user", content: "Continue")],
                                       persona: context.persona)
    precondition(reply == "Local reply")
    var body = ProviderStubHTTP.state.withLock { $0.bodies[0] }
    var wire = try JSONSerialization.jsonObject(with: body) as! [String: Any]
    let localMessages = wire["messages"] as! [[String: String]]
    precondition(localMessages[0]["content"]?.contains(character.characterPrompt) == true)
    precondition(localMessages[0]["content"]?.contains(source.portableSystemPrompt) == true)
    precondition(localMessages[1]["content"] == character.greeting)
    precondition(!String(decoding: body, as: UTF8.self).contains("avatar")
                 && !String(decoding: body, as: UTF8.self).contains("base64"))

    for kind in [ProviderKind.ollama, .openAI, .openAIResponses, .anthropic] {
        let provider: TextChatProvider
        let fixture: String
        if kind == .ollama {
            provider = try TextChatProvider(localEndpoint: ProviderEndpoint.defaultOllama, transport: transport)
            fixture = #"{"message":{"content":"Reply"},"done":true}"# + "\n"
        } else {
            let configuration = ProviderConfiguration(name: "Fixture", kind: kind,
                endpoint: kind == .anthropic ? ProviderEndpoint.defaultAnthropic : ProviderEndpoint.defaultOpenAI)
            provider = try TextChatProvider(configuration: configuration, apiKey: "FIXTURE", transport: transport)
            switch kind {
            case .anthropic:
                fixture = "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Reply\"}}\n\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n"
            case .openAIResponses:
                fixture = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Reply\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\"}]}}\n\n"
            default:
                fixture = "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Reply\"}}]}\n\ndata: [DONE]\n\n"
            }
        }
        let chat = ProviderChatViewModel(provider: provider, model: "fixture", character: character)
        chat.usePersonaContext(context)
        precondition(chat.messages.map(\.content) == [character.greeting])
        ProviderStubHTTP.configure(fixture)
        chat.send("Continue")
        for _ in 0..<400 where chat.isGenerating { try await Task.sleep(for: .milliseconds(5)) }
        precondition(!chat.isGenerating && chat.errorMessage == nil)
        body = ProviderStubHTTP.state.withLock { $0.bodies[0] }
        wire = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let prompt: String?
        if kind == .anthropic { prompt = wire["system"] as? String }
        else {
            let messages = wire[kind == .openAIResponses ? "input" : "messages"] as! [[String: String]]
            prompt = messages.first?["content"]
        }
        precondition(prompt?.contains(character.characterPrompt) == true && prompt?.contains(source.portableSystemPrompt) == true,
                     "Both character and user persona must reach every API")
        precondition(chat.messages.first?.content == character.greeting)
        precondition(!String(decoding: body, as: UTF8.self).contains("avatar")
                     && !String(decoding: body, as: UTF8.self).contains("base64"),
                     "Persona pictures are display-only, not provider attachments")
    }

    let log = PersonaMessageLog()
    let chat = ProviderChatViewModel(provider: PersonaPromptProvider(log: log), model: "fixture", character: character)
    chat.usePersonaContext(context)
    let originalMessages = chat.messages
    context.select(nil)
    precondition(chat.messages == originalMessages, "Changing persona must not rewrite messages or greeting")
    chat.send("No persona")
    for _ in 0..<400 where chat.isGenerating { try await Task.sleep(for: .milliseconds(5)) }
    var history = await log.snapshot()
    precondition(history.first?.content == character.characterPrompt)
    context.select(reference)
    var revised = source
    revised.definition = "Updated roleplay details"
    try revised.portableJSON().write(to: file)
    _ = try await local.importPersonas(from: file)
    chat.send("Updated persona")
    for _ in 0..<400 where chat.isGenerating { try await Task.sleep(for: .milliseconds(5)) }
    history = await log.snapshot()
    precondition(history.first?.content.contains("Updated roleplay details") == true)
    chat.setCharacter(try LocalCharacter(accountExportRecord: ["id": "other", "name": "Other"]))
    precondition(context.persona == nil)
    chat.setCharacter(character)
    precondition(context.persona?.definition == revised.definition)
    try await local.delete(revised)
    precondition(context.unavailable && context.persona == nil && chat.persona == nil)
    chat.send("Deleted persona")
    for _ in 0..<400 where chat.isGenerating { try await Task.sleep(for: .milliseconds(5)) }
    history = await log.snapshot()
    precondition(history.first?.content == character.characterPrompt, "Deleted persona text must not be sent")

    let snapshot: [String: Any] = ["accountID": "account-a", "personas": [["id": "same-id", "external_id": "same-id",
        "display_name": "Account A", "definition": "Account A private details"]],
        "activePersonaID": "same-id", "characterOverrides": [:]]
    defaults.set(try JSONSerialization.data(withJSONObject: snapshot), forKey: "preferences.personas.accountSnapshot")
    account.setAccount("account-a")
    let accountReference = RoleplayPersonaReference(source: .account, personaID: "same-id", accountID: "account-a")
    context.select(accountReference)
    precondition(context.persona?.displayName == "Account A")
    account.setAccount(nil)
    precondition(context.unavailable && context.persona == nil)
    var accountBSnapshot = snapshot
    accountBSnapshot["accountID"] = "account-b"
    accountBSnapshot["personas"] = [["id": "same-id", "external_id": "same-id",
                                    "display_name": "Account B", "definition": "Account B private details"]]
    defaults.set(try JSONSerialization.data(withJSONObject: accountBSnapshot), forKey: "preferences.personas.accountSnapshot")
    account.setAccount("account-b")
    precondition(account.personas.first?.externalID == "same-id")
    precondition(context.unavailable && context.persona == nil, "An identical persona ID from another account cannot resolve")
    defaults.set(try JSONSerialization.data(withJSONObject: snapshot), forKey: "preferences.personas.accountSnapshot")
    account.setAccount("account-a")
    precondition(context.persona?.displayName == "Account A")
    defaults.set(Data("broken".utf8), forKey: "providers.characterPersonas")
    let broken = RoleplayPersonaSelections(defaults: defaults)
    precondition(!broken.isReadable)
    do {
        try broken.select(reference, for: character.id)
        preconditionFailure("Corrupt selections must not be overwritten")
    } catch LocalPersonaStoreError.selectionStorageUnavailable {}
    precondition(defaults.data(forKey: "providers.characterPersonas") == Data("broken".utf8))

    _ = NSApplication.shared
    for scheme in [ColorScheme.light, .dark] {
        let views: [AnyView] = [AnyView(PersonaAvatarView(persona: source, size: 48)),
            AnyView(PersonaAvatarView(persona: .defaultUser(), size: 22)),
            AnyView(RoleplayPersonaControl(context: context)),
            AnyView(LocalCharacterLibraryView())]
        for view in views {
            let host = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
            host.frame = NSRect(x: 0, y: 0, width: 600, height: 560)
            host.layoutSubtreeIfNeeded()
            precondition(host.fittingSize.width.isFinite && host.fittingSize.height.isFinite)
        }
    }
    print("Per-character persona persistence, local/cloud wire prompts, removal/deletion/re-import/account isolation and native controls passed")
}

@MainActor
private func runPersonaImageChecks(folder: URL, source: Persona) async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ProviderStubHTTP.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let cache = ImageCacheService(session: session)
    let library = LocalPersonaStore(supportDirectory: folder.appendingPathComponent("images"), imageCache: cache)
    var remote = source
    remote.avatarData = nil
    ProviderStubHTTP.configure()
    ProviderStubHTTP.state.withLock { $0.body = source.avatarData! }
    let exportedFile = folder.appendingPathComponent("with-picture.json")
    try await library.export(remote, to: exportedFile)
    let requests = ProviderStubHTTP.state.withLock { $0.requests }
    precondition(requests.count == 1 && requests[0].url == source.avatarURL)
    precondition(requests[0].value(forHTTPHeaderField: "Authorization") == nil,
                 "Persona pictures must not receive account or provider credentials")
    let imported = try await library.importPersonas(from: exportedFile)[0]
    precondition(imported.avatarFileName == remote.avatarFileName && imported.avatarData != nil)
    let decoded = ImageProcessing.thumbnail(from: imported.avatarData!, maxPixelSize: 160)!
    precondition(decoded.size.width == 40 && decoded.size.height == 20)
    let color = NSBitmapImageRep(data: imported.avatarData!)!.colorAt(x: 0, y: 0)!.usingColorSpace(.sRGB)!
    precondition(color.redComponent > 0.9 && color.blueComponent < 0.1, "The imported picture must keep its pixels")
    let reloaded = LocalPersonaStore(supportDirectory: folder.appendingPathComponent("images"), imageCache: cache)
    precondition(reloaded.personas.first?.avatarData == imported.avatarData, "Embedded pictures survive reopening")

    // Once imported, individual and library exports no longer need the CDN.
    ProviderStubHTTP.configure(fail: true)
    for ext in ["json", "md", "txt"] {
        let file = folder.appendingPathComponent("offline-picture.\(ext)")
        try await reloaded.export(imported, to: file)
        let restored = try await PersonaTransfer.parseAll(data: Data(contentsOf: file), filename: file.lastPathComponent)[0]
        precondition(restored.avatarData != nil && restored.definition == source.definition)
        precondition(NSBitmapImageRep(data: restored.avatarData!)?.pixelsWide == 40)
        precondition(!restored.portableSystemPrompt.contains("base64") && !restored.portableSystemPrompt.contains("avatar"))
    }
    let all = folder.appendingPathComponent("image-library.json")
    try await reloaded.exportAll(to: all)
    let restored = try await PersonaTransfer.parseAll(data: Data(contentsOf: all), filename: all.lastPathComponent)
    precondition(restored.count == 1 && restored[0].avatarData != nil)
    precondition(ProviderStubHTTP.state.withLock { $0.requests.isEmpty }, "Embedded images must work offline")

    let oldJSON = Data(#"{"id":"old","display_name":"Legacy","description":"No picture"}"#.utf8)
    let oldDecoded = try JSONDecoder().decode(Persona.self, from: oldJSON)
    precondition(oldDecoded.avatarData == nil)
    let oldImported = try await PersonaTransfer.parseAll(data: oldJSON, filename: "old.json")
    precondition(oldImported[0].avatarData == nil && oldImported[0].avatarURL == nil)
    let referenceOnly = try await PersonaTransfer.parseAll(data: remote.portableJSON(), filename: "reference.json")[0]
    precondition(referenceOnly.avatarFileName == remote.avatarFileName && referenceOnly.avatarData == nil)
    let referenceMarkdown = try await PersonaTransfer.parseAll(data: Data(remote.portableMarkdown.utf8), filename: "reference.md")[0]
    precondition(referenceMarkdown.avatarFileName == remote.avatarFileName)

    for invalid in ["not-base64", Data("not an image".utf8).base64EncodedString(), String(repeating: "A", count: 6 * 1024 * 1024 + 1)] {
        var payload = source.portablePayload
        payload["avatar_data"] = invalid
        let file = folder.appendingPathComponent("invalid-picture.json")
        try JSONSerialization.data(withJSONObject: payload).write(to: file)
        do {
            _ = try await reloaded.importPersonas(from: file)
            preconditionFailure("Invalid images must not silently replace an imported persona")
        } catch PersonaTransferError.invalidAvatar {}
        precondition(reloaded.personas == [imported])
    }
    let sentinel = Data("Keep existing export".utf8)
    try sentinel.write(to: exportedFile)
    do {
        var unavailable = remote
        unavailable.avatarFileName = "unavailable.png"
        try await library.export(unavailable, to: exportedFile)
        preconditionFailure("Unavailable images must not be silently omitted from an export")
    } catch PersonaTransferError.avatarUnavailable {}
    let untouched = try Data(contentsOf: exportedFile)
    precondition(untouched == sentinel)

    // A text-only re-import must keep the picture already stored.
    var textOnly = source
    textOnly.avatarData = nil
    textOnly.avatarFileName = nil
    textOnly.definition = "Revised definition"
    let textOnlyFile = folder.appendingPathComponent("text-only.json")
    try textOnly.portableJSON().write(to: textOnlyFile)
    _ = try await reloaded.importPersonas(from: textOnlyFile)
    precondition(reloaded.personas.first?.definition == "Revised definition")
    precondition(reloaded.personas.first?.avatarData == imported.avatarData,
                 "A text-only re-import must keep the stored picture")

    // Prose under "## Avatar" is not an image; importing must still work.
    let prose = Data("""
    # Writer

    ## Avatar

    Tall, dark hair, green eyes, usually in a leather jacket.

    ## Definition

    Answer briefly.
    """.utf8)
    let prosePersona = try await PersonaTransfer.parseAll(data: prose, filename: "writer.md")[0]
    precondition(prosePersona.displayName == "Writer" && prosePersona.avatarData == nil)
    precondition(prosePersona.definition == "Answer briefly.")

    // Large pictures are downsampled before storage, keeping the aspect ratio.
    let big = CGContext(data: nil, width: 640, height: 320, bitsPerComponent: 8, bytesPerRow: 640 * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    big.setFillColor(red: 0, green: 0.4, blue: 1, alpha: 1)
    big.fill(CGRect(x: 0, y: 0, width: 640, height: 320))
    let bigPNG = NSBitmapImageRep(cgImage: big.makeImage()!).representation(using: .png, properties: [:])!
    var bigPayload = source.portablePayload
    bigPayload["avatar_data"] = bigPNG.base64EncodedString()
    let bigFile = folder.appendingPathComponent("big-picture.json")
    try JSONSerialization.data(withJSONObject: bigPayload).write(to: bigFile)
    _ = try await reloaded.importPersonas(from: bigFile)
    let storedRep = NSBitmapImageRep(data: reloaded.personas.first!.avatarData!)!
    precondition(storedRep.pixelsWide == PersonaTransfer.avatarPixelSize && storedRep.pixelsHigh == 128,
                 "Stored pictures must be downsampled to 256 pixels")

    // An empty picture field from another tool means "no picture", not a broken file.
    var emptyPayload = source.portablePayload
    emptyPayload["avatar_data"] = ""
    let emptyFile = folder.appendingPathComponent("empty-picture.json")
    try JSONSerialization.data(withJSONObject: emptyPayload).write(to: emptyFile)
    let emptyParsed = try await PersonaTransfer.parseAll(data: Data(contentsOf: emptyFile), filename: "empty.json")
    precondition(emptyParsed.first?.avatarData == nil && emptyParsed.first?.displayName == source.displayName)
    print("Persona image JSON/Markdown/text/library round-trips, offline persistence, legacy files, invalid images, re-import preservation, prose avatars and failed-export preservation passed")
}

/// Offscreen render so layout regressions show up in the verification output.
@MainActor
private func capture<V: View>(_ view: V, size: CGSize, name: String,
                             scheme: ColorScheme = .light) async throws {
    _ = NSApplication.shared
    let host = NSHostingView(rootView: view
        .environment(\.colorScheme, scheme)
        .background(scheme == .light ? Color.white : Color(white: 0.12)))
    // AppKit materials follow the window appearance, not the SwiftUI environment.
    host.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    // Pictures decode in a task; give it a moment so the snapshot shows them.
    try await Task.sleep(for: .milliseconds(400))
    host.layoutSubtreeIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        preconditionFailure("Could not render \(name)")
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        preconditionFailure("Could not encode \(name)")
    }
    let directory = URL(fileURLWithPath: ".build")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try png.write(to: directory.appendingPathComponent("\(name).png"))
}

@MainActor
func runPersonaChecks() async throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("VeyrinPersonaChecks-\(UUID().uuidString)")
    let archiveFolder = folder.appendingPathComponent("archive")
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: archiveFolder, withIntermediateDirectories: true)

    let pixels = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 40 * 4,
                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    pixels.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    pixels.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
    let picture = NSBitmapImageRep(cgImage: pixels.makeImage()!).representation(using: .png, properties: [:])!
    let source = Persona(
        id: "persona-ada",
        externalID: "persona-ada",
        displayName: "Ada",
        title: "Concise editor",
        greeting: "Hello, shall we edit?",
        description: "A careful writing partner.",
        definition: "Answer with three short bullet points. Never pad the answer.",
        avatarFileName: "persona-ada.png",
        avatarData: picture
    )

    let json = try source.portableJSON()
    let parsedJSON = try await PersonaTransfer.parseAll(data: json, filename: "ada.persona.json")
    precondition(parsedJSON.count == 1)
    precondition(parsedJSON[0].displayName == "Ada")
    precondition(parsedJSON[0].description == source.description)
    precondition(parsedJSON[0].definition == source.definition)
    precondition(parsedJSON[0].avatarFileName == source.avatarFileName && parsedJSON[0].avatarData != nil)
    precondition(parsedJSON[0].portableSystemPrompt.contains("three short bullet points"))

    let markdown = Data(source.portableMarkdown.utf8)
    let parsedMarkdown = try await PersonaTransfer.parseAll(data: markdown, filename: "ada.md")
    precondition(parsedMarkdown.first?.displayName == "Ada")
    precondition(parsedMarkdown.first?.title == "Concise editor")
    precondition(parsedMarkdown.first?.description == source.description)
    precondition(parsedMarkdown.first?.definition == source.definition)
    precondition(parsedMarkdown.first?.avatarData != nil)

    let characterCard = Data("""
    {"spec":"chara_card_v2","data":{"name":"Mentor","description":"A patient mentor.",
     "personality":"Calm and direct.","scenario":"Reviewing a pull request.","first_mes":"Ready?"}}
    """.utf8)
    let parsedCard = try await PersonaTransfer.parseAll(data: characterCard, filename: "mentor.json")
    precondition(parsedCard.first?.displayName == "Mentor")
    precondition(parsedCard.first?.description == "A patient mentor.")
    let cardDefinition = parsedCard.first?.definition ?? ""
    precondition(cardDefinition.contains("Calm and direct."))
    precondition(cardDefinition.contains("Reviewing a pull request."))
    precondition(parsedCard.first?.greeting == "Ready?")

    let personaFile = archiveFolder.appendingPathComponent("ada.persona.json")
    try json.write(to: personaFile)
    let library = LocalPersonaStore(supportDirectory: folder)
    let imported = try await library.importPersonas(from: personaFile)
    precondition(imported.count == 1 && library.personas.count == 1)
    _ = try await library.importPersonas(from: personaFile)
    precondition(library.personas.count == 1, "Re-importing the same persona must update rather than duplicate")

    let allFile = archiveFolder.appendingPathComponent("all-personas.json")
    try await library.exportAll(to: allFile)
    let restoredLibrary = LocalPersonaStore(supportDirectory: archiveFolder.appendingPathComponent("restored"))
    let restored = try await restoredLibrary.importPersonas(from: allFile)
    precondition(restored.count == 1 && restoredLibrary.personas.first?.displayName == "Ada")

    let markdownFile = archiveFolder.appendingPathComponent("ada.md")
    try await library.export(source, to: markdownFile)
    let exportedMarkdown = try String(contentsOf: markdownFile, encoding: .utf8)
    precondition(exportedMarkdown.contains("# Ada") && exportedMarkdown.contains("## Definition"))

    try await library.delete(library.personas[0])
    precondition(library.personas.isEmpty)

    // Both mutations must see the preceding committed state, not competing
    // snapshots taken before the background encoder returns.
    let concurrentRoot = folder.appendingPathComponent("concurrent")
    let concurrent = LocalPersonaStore(supportDirectory: concurrentRoot)
    let one = Persona(id: "one", displayName: "One", definition: "Synthetic persona one")
    let two = Persona(id: "two", displayName: "Two", definition: "Synthetic persona two")
    let pairFile = archiveFolder.appendingPathComponent("pair.json")
    try LocalPersonaArchive.encode([one, two]).write(to: pairFile)
    _ = try await concurrent.importPersonas(from: pairFile)
    async let deleteOne: Void = concurrent.delete(one)
    async let deleteTwo: Void = concurrent.delete(two)
    _ = try await (deleteOne, deleteTwo)
    precondition(concurrent.personas.isEmpty, "Concurrent deletes must not resurrect either persona")
    precondition(LocalPersonaStore(supportDirectory: concurrentRoot).personas.isEmpty)

    let oneFile = archiveFolder.appendingPathComponent("one.json")
    let twoFile = archiveFolder.appendingPathComponent("two.json")
    try one.portableJSON().write(to: oneFile)
    try two.portableJSON().write(to: twoFile)
    async let importOne = concurrent.importPersonas(from: oneFile)
    async let importTwo = concurrent.importPersonas(from: twoFile)
    _ = try await (importOne, importTwo)
    precondition(Set(concurrent.personas.map(\.externalID)) == ["one", "two"])
    precondition(Set(LocalPersonaStore(supportDirectory: concurrentRoot).personas.map(\.externalID)) == ["one", "two"])

    // Cancellation before committing leaves the current catalogue alone.
    let cancelledDelete = Task { try await concurrent.delete(one) }
    cancelledDelete.cancel()
    do { try await cancelledDelete.value; preconditionFailure("Cancelled deletion committed") }
    catch is CancellationError { }
    precondition(concurrent.personas.count == 2)

    if let supportRoot = ProcessInfo.processInfo.environment["VEYRIN_SUPPORT_DIRECTORY"] {
        let defaultStore = LocalPersonaStore()
        _ = try await defaultStore.importPersonas(from: oneFile)
        let isolatedURL = URL(fileURLWithPath: supportRoot).appendingPathComponent("local-personas.json")
        precondition(FileManager.default.fileExists(atPath: isolatedURL.path))
        precondition(LocalPersonaStore(supportDirectory: URL(fileURLWithPath: supportRoot)).personas.contains { $0.externalID == "one" })
    }

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

    // The full profile greeting must survive summary saves, account export,
    // archive transfer, first-message initialization and subsequent API history.
    let greeting = "*The door opens.*\n\n**Hello**, {{user}}! 👋"
    let characterRecord: [String: Any] = ["external_id": "greeting-character", "name": "Mentor",
                                          "greeting": greeting, "definition": "Stay patient."]
    let character = try LocalCharacter(accountExportRecord: characterRecord)
    let characterLibrary = LocalCharacterLibrary(supportDirectory: folder.appendingPathComponent("characters"))
    let accountFile = archiveFolder.appendingPathComponent("character.json")
    try JSONSerialization.data(withJSONObject: [characterRecord]).write(to: accountFile)
    _ = try characterLibrary.importCharacterAIAccountExport(from: accountFile)
    precondition(characterLibrary.characters.first?.greeting == greeting)
    let archiveFile = archiveFolder.appendingPathComponent("characters.json")
    try characterLibrary.exportArchive(to: archiveFile)
    let restoredCharacters = LocalCharacterLibrary(supportDirectory: folder.appendingPathComponent("restored-characters"))
    _ = try restoredCharacters.importArchive(from: archiveFile)
    precondition(restoredCharacters.characters.first?.greeting == greeting)
    let localConversation = try restoredCharacters.conversation(for: character)
    precondition(localConversation.messages.count == 1 && localConversation.messages[0].role == "assistant")
    precondition(localConversation.messages[0].content == greeting)
    try restoredCharacters.append(LocalChatMessage(role: "user", content: "Existing conversation"), characterID: character.id)
    let reopened = try LocalCharacterLibrary(supportDirectory: folder.appendingPathComponent("restored-characters"))
        .conversation(for: character)
    precondition(reopened.messages.count == 2, "Reopening an existing chat cannot insert another greeting")

    let characterLog = PersonaMessageLog()
    let characterChat = ProviderChatViewModel(provider: PersonaPromptProvider(log: characterLog), model: "fixture-model",
                                             persona: source, character: character)
    precondition(characterChat.messages.map(\.content) == [greeting] && !characterChat.isGenerating)
    let initialRequests = await characterLog.snapshot()
    precondition(initialRequests.isEmpty, "Showing the greeting must not generate an API request")
    characterChat.send("Continue")
    for _ in 0..<200 where characterChat.isGenerating { try await Task.sleep(for: .milliseconds(5)) }
    precondition(!characterChat.isGenerating)
    let characterHistory = await characterLog.snapshot()
    precondition(characterHistory.map(\.role) == [.system, .assistant, .user])
    precondition(characterHistory[0].content.contains("roleplaying as Mentor") && characterHistory[0].content.contains("Ada"))
    precondition(characterHistory[1].content == greeting)
    characterChat.newConversation()
    characterChat.newConversation()
    precondition(characterChat.messages.map(\.content) == [greeting], "New Chat seeds exactly one greeting")
    characterChat.setCharacter(nil)
    precondition(characterChat.messages.isEmpty && characterChat.persona?.id == source.id)

    let httpConfiguration = URLSessionConfiguration.ephemeral
    httpConfiguration.protocolClasses = [ProviderStubHTTP.self]
    let httpSession = URLSession(configuration: httpConfiguration)
    defer { httpSession.invalidateAndCancel() }
    let auth = AuthStore(session: AuthSession(sessionToken: "SYNTHETIC", userID: "greeting-test", username: "Fixture"))
    let profileService = CharacterService(httpClient: AuthenticatedHTTPClient(session: httpSession, authStore: auth))
    let summary = DiscoverFeedCharacter(externalID: character.id, name: character.name, participantName: nil,
                                        interactionCount: nil, title: nil, description: nil, greeting: nil,
                                        visibility: nil, avatarFileName: nil, username: nil, shortHash: nil)
    let profileBody: [String: Any] = ["character": ["external_id": character.id, "name": character.name, "greeting": greeting]]
    ProviderStubHTTP.configure(String(decoding: try JSONSerialization.data(withJSONObject: profileBody), as: UTF8.self))
    try await characterLibrary.saveFromDiscover(summary, service: profileService)
    precondition(characterLibrary.characters.first?.greeting == greeting)
    precondition(characterLibrary.characters.first?.definition == "Stay patient.")
    let request = ProviderStubHTTP.state.withLock { $0.requests.first }
    precondition(request?.url?.path == "/character/v1/get_character_info" && request?.httpMethod == "POST")
    let searchResult = CharacterSearchResult(externalID: character.id, name: "Mentor", title: nil, description: nil,
                                            avatarFileName: nil, interactionCount: nil, creatorUsername: nil, tagLabel: nil)
    try await characterLibrary.saveFromDiscover(searchResult, service: profileService)
    precondition(characterLibrary.characters.first?.greeting == greeting)
    let sparseProfile = try JSONDecoder().decode(CharacterProfile.self, from: Data("{\"external_id\":\"greeting-character\"}".utf8))
    let preserved = try LocalCharacter(discoverCharacter: summary, existing: character, profile: sparseProfile)
    precondition(preserved.greeting == greeting, "A missing greeting must not erase an imported opening")
    let failingSummary = DiscoverFeedCharacter(externalID: "failed-character", name: "Failure", participantName: nil,
                                               interactionCount: nil, title: nil, description: nil, greeting: nil,
                                               visibility: nil, avatarFileName: nil, username: nil, shortHash: nil)
    ProviderStubHTTP.configure("private error", status: 500)
    do {
        try await characterLibrary.saveFromDiscover(failingSummary, service: profileService)
        preconditionFailure("Failed greeting fetch was silently saved")
    } catch is NetworkError {}
    precondition(!characterLibrary.containsCharacter("failed-character"))

    try await runPersonaImageChecks(folder: folder, source: source)
    try await runRoleplayPersonaChecks(folder: folder, source: source, character: character)

    _ = NSApplication.shared
    let suite = "PersonaChecks.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { preconditionFailure("Defaults fixture unavailable") }
    defer { defaults.removePersistentDomain(forName: suite) }
    let accountStore = PersonaStore(defaults: defaults)
    let visualFile = folder.appendingPathComponent("visual-personas.json")
    try JSONSerialization.data(withJSONObject: [
        "format": "veyrin.persona-library", "version": 1,
        "personas": [source.portablePayload,
                     ["id": "visual-long", "display_name": "A Very Long Persona Name That Should Not Push The Menu Off Screen",
                      "title": "Long names must truncate instead of widening the row",
                      "description": "A description long enough to fill the two allowed lines and then stop cleanly."],
                     ["id": "visual-plain", "display_name": "No Picture", "description": "Shows initials."]]
    ]).write(to: visualFile)
    let visualStore = LocalPersonaStore(supportDirectory: folder.appendingPathComponent("visual"))
    _ = try await visualStore.importPersonas(from: visualFile)
    let visualSuite = "RoleplayVisual.\(UUID().uuidString)"
    let visualDefaults = UserDefaults(suiteName: visualSuite)!
    defer { visualDefaults.removePersistentDomain(forName: visualSuite) }
    let visualContext = RoleplayPersonaContext(characterID: "visual-character", local: visualStore,
                                               account: accountStore,
                                               saved: RoleplayPersonaSelections(defaults: visualDefaults))
    visualContext.select(RoleplayPersonaReference(source: .local, personaID: source.externalID))
    for scheme in [ColorScheme.light, .dark] {
        let host = NSHostingView(rootView: PersonaSettingsView(accountPersonas: accountStore, localPersonas: visualStore)
            .environment(\.colorScheme, scheme))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 520)
        host.layoutSubtreeIfNeeded()
        precondition(host.fittingSize.width.isFinite && host.fittingSize.height.isFinite)
        try await capture(PersonaSettingsView(accountPersonas: accountStore, localPersonas: visualStore),
                          size: CGSize(width: 560, height: 520),
                          name: "persona-settings-\(scheme == .light ? "light" : "dark")", scheme: scheme)
    }
    // The toolbar label must stay usable in a narrow window.
    try await capture(HStack { Spacer(minLength: 0); RoleplayPersonaControl(context: visualContext) }.padding(8)
        .frame(width: 260, height: 56), size: CGSize(width: 260, height: 56), name: "persona-control-narrow")
    print("Persona transfer, full-profile greeting saves, character archive round-trip, local/provider greeting history, system prompts and layout checks passed")
}
