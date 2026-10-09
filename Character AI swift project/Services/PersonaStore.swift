import Foundation
import Combine
import OSLog

private let logger = Logger(subsystem: "CharacterAI", category: "PersonaStore")

/// Server personas belong to one authenticated account, never the application singleton.
@MainActor
final class PersonaStore: ObservableObject {
    private static let snapshotKey = "preferences.personas.accountSnapshot"
    private static let legacyKeys = ["preferences.personas.list", "preferences.personas.activeID",
                                     "preferences.personas.characterOverrides", "preferences.personas.defaultPersonaID"]

    private struct Snapshot: Codable {
        let accountID: String
        let personas: [Persona]
        let activePersonaID: String
        let characterOverrides: [String: String]
        let defaultPersonaID: String?
    }

    @Published private(set) var personas: [Persona] = []
    @Published private(set) var activePersona = Persona.defaultUser()
    @Published private(set) var characterOverrides: [String: String] = [:]
    @Published private(set) var defaultPersonaID: String?
    @Published private(set) var isLoadingPersonas = false
    @Published private(set) var personaSelectionErrorMessage: String?
    @Published private(set) var isSelectingPersona = false
    @Published private(set) var personaListErrorMessage: String?
    @Published private(set) var personaSettingsErrorMessage: String?

    private let defaults: UserDefaults
    private var accountID: String?
    private var generation = UUID()
    private var loadID: UUID?
    private var selectionID: UUID?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Old records carry no owner. Assigning them to the next login would
        // recreate the cross-account leak, so only these persona keys migrate away.
        for key in Self.legacyKeys { defaults.removeObject(forKey: key) }
    }

    func setAccount(_ accountID: String?) {
        generation = UUID()
        self.accountID = accountID
        loadID = nil
        selectionID = nil
        personas = []
        activePersona = .defaultUser()
        characterOverrides = [:]
        defaultPersonaID = nil
        isLoadingPersonas = false
        isSelectingPersona = false
        personaSelectionErrorMessage = nil
        personaListErrorMessage = nil
        personaSettingsErrorMessage = nil
        guard let accountID, let data = defaults.data(forKey: Self.snapshotKey),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.accountID == accountID else { return }
        personas = snapshot.personas
        characterOverrides = snapshot.characterOverrides
        defaultPersonaID = snapshot.defaultPersonaID
        activePersona = personas.first { $0.externalID == snapshot.activePersonaID }
            ?? personas.first ?? .defaultUser()
    }

    func resolvePersona(forCharacterID characterID: String?) -> Persona {
        if let characterID, let id = characterOverrides[characterID],
           let persona = personas.first(where: { $0.externalID == id || $0.id == id }) { return persona }
        if let defaultPersonaID,
           let persona = personas.first(where: { $0.externalID == defaultPersonaID || $0.id == defaultPersonaID }) { return persona }
        return activePersona
    }

    func fetchRemotePersonas(authenticatedClient: AuthenticatedHTTPClient, currentCharacterID: String? = nil) async {
        guard !isSelectingPersona, accountID != nil, accountID == authenticatedClient.accountID else { return }
        let expectedGeneration = generation
        let session = authenticatedClient.sessionGeneration
        let id = UUID()
        loadID = id
        isLoadingPersonas = true
        personaListErrorMessage = nil
        personaSettingsErrorMessage = nil
        defer { if loadID == id { isLoadingPersonas = false; loadID = nil } }
        guard let personasURL = URL(string: "https://neo.character.ai/character/v1/get_user_personas?force_refresh=0"),
              let settingsURL = URL(string: "https://plus.character.ai/chat/user/settings/?v=2") else { return }

        async let list: UserPersonasResponse = authenticatedClient.resources.value(
            for: "personas:list", ttl: 120, cost: { response in
                response.personas.reduce(256) { $0 + 1024 + ($1.definition?.utf8.count ?? 0) * 4 + ($1.description?.utf8.count ?? 0) * 4 }
            }) { try await authenticatedClient.get(personasURL) }
        async let settings: UserSettingsResponse = authenticatedClient.resources.value(
            for: "personas:settings", ttl: 120, cost: { response in
                512 + (response.personaSettings?.characterOverrides?.count ?? response.personaOverrides?.count ?? 0) * 256
            }) { try await authenticatedClient.get(settingsURL) }
        do {
            let response = try await list
            guard generation == expectedGeneration, loadID == id,
                  session == authenticatedClient.sessionGeneration, !Task.isCancelled else { return }
            personas = response.personas.map { $0.toPersona() }
            activePersona = personas.first { $0.externalID == activePersona.externalID }
                ?? personas.first ?? .defaultUser()
        } catch is CancellationError { return }
        catch {
            guard generation == expectedGeneration, loadID == id, !Task.isCancelled else { return }
            personaListErrorMessage = error.localizedDescription
        }
        do {
            let response = try await settings
            guard generation == expectedGeneration, loadID == id,
                  session == authenticatedClient.sessionGeneration, !Task.isCancelled else { return }
            defaultPersonaID = response.personaSettings?.defaultPersonaId ?? response.defaultPersonaId
            characterOverrides = response.personaSettings?.characterOverrides ?? response.personaOverrides ?? [:]
            activePersona = resolvePersona(forCharacterID: currentCharacterID)
            persist()
        } catch is CancellationError { return }
        catch {
            guard generation == expectedGeneration, loadID == id, !Task.isCancelled else { return }
            personaSettingsErrorMessage = error.localizedDescription
        }
    }

    /// The write contract still needs live confirmation; failure never commits a local selection.
    func selectPersona(_ persona: Persona, forCharacterID characterID: String?,
                       authenticatedClient: AuthenticatedHTTPClient?) async -> Bool {
        guard !isSelectingPersona else { return false }
        personaSelectionErrorMessage = nil
        guard let characterID, !characterID.isEmpty else {
            personaSelectionErrorMessage = "Persona selection requires a character conversation."
            return false
        }
        guard let authenticatedClient, accountID != nil, accountID == authenticatedClient.accountID,
              let url = URL(string: "https://plus.character.ai/chat/user/update_settings/") else {
            personaSelectionErrorMessage = "An authenticated persona settings request is unavailable."
            return false
        }
        guard personas.contains(where: { $0.externalID == persona.externalID }) else {
            personaSelectionErrorMessage = "That persona is no longer available."
            return false
        }
        let expectedGeneration = generation
        let session = authenticatedClient.sessionGeneration
        let id = UUID()
        selectionID = id
        // A read begun before this write must not undo its acknowledged result.
        loadID = nil
        isLoadingPersonas = false
        authenticatedClient.resources.invalidate("personas:settings")
        var updated = characterOverrides
        updated[characterID] = persona.externalID
        isSelectingPersona = true
        defer { if selectionID == id { isSelectingPersona = false; selectionID = nil } }
        do {
            let body = try JSONEncoder().encode(UpdatePersonaOverridesRequest(personaOverrides: updated))
            try await authenticatedClient.send(url, method: "POST", body: body)
            guard generation == expectedGeneration, session == authenticatedClient.sessionGeneration,
                  selectionID == id, !Task.isCancelled else { return false }
            characterOverrides = updated
            activePersona = persona
            authenticatedClient.resources.invalidate("personas:settings")
            persist()
            return true
        } catch is CancellationError { return false }
        catch {
            guard generation == expectedGeneration, selectionID == id, !Task.isCancelled else { return false }
            personaSelectionErrorMessage = error.localizedDescription
            logger.error("Failed to update persona override: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    private func persist() {
        guard let accountID else { return }
        let snapshot = Snapshot(accountID: accountID, personas: personas, activePersonaID: activePersona.externalID,
                                characterOverrides: characterOverrides, defaultPersonaID: defaultPersonaID)
        guard let data = try? JSONEncoder().encode(snapshot), data != defaults.data(forKey: Self.snapshotKey) else { return }
        // Keep one owner's snapshot, rather than accumulating every account's private definitions.
        defaults.set(data, forKey: Self.snapshotKey)
    }
}
