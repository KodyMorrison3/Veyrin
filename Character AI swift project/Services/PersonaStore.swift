import Foundation
import Combine
import OSLog

private let logger = Logger(subsystem: "CharacterAI", category: "PersonaStore")

/// Manages user personas with remote fetching from `neo.character.ai/character/v1/get_user_personas`
/// and persona overrides syncing with `plus.character.ai/chat/user/settings/?v=2` / `update_settings/`.
@MainActor
final class PersonaStore: ObservableObject {
    static let shared = PersonaStore()

    private enum Keys {
        static let personasList = "preferences.personas.list"
        static let activePersonaID = "preferences.personas.activeID"
        static let characterOverrides = "preferences.personas.characterOverrides"
        static let defaultPersonaID = "preferences.personas.defaultPersonaID"
    }

    @Published private(set) var personas: [Persona] = []
    @Published private(set) var activePersona: Persona
    @Published private(set) var characterOverrides: [String: String] = [:]
    @Published private(set) var defaultPersonaID: String?
    @Published private(set) var isLoadingPersonas = false

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Cached selectable personas are always server personas. Drop legacy local
        // placeholder entries (including the former "User Default") during migration.
        let initialPersonas: [Persona]
        if let data = defaults.data(forKey: Keys.personasList),
           let saved = try? JSONDecoder().decode([Persona].self, from: data) {
            initialPersonas = saved.filter {
                !$0.isDefaultUser && $0.id != "default_user"
                    && !$0.id.hasPrefix("persona_")
            }
            if initialPersonas.count != saved.count,
               let migrated = try? JSONEncoder().encode(initialPersonas) {
                defaults.set(migrated, forKey: Keys.personasList)
            }
        } else {
            initialPersonas = []
        }

        let savedOverrides = defaults.dictionary(forKey: Keys.characterOverrides) as? [String: String] ?? [:]
        self.characterOverrides = savedOverrides
        self.defaultPersonaID = defaults.string(forKey: Keys.defaultPersonaID)

        let savedID = defaults.string(forKey: Keys.activePersonaID)
        let defaultID = defaults.string(forKey: Keys.defaultPersonaID)
        let resolved = initialPersonas.first(where: { $0.id == savedID || $0.externalID == savedID })
            ?? initialPersonas.first(where: { $0.id == defaultID || $0.externalID == defaultID })
            ?? initialPersonas.first
            ?? Persona.defaultUser()
        self.personas = initialPersonas
        self.activePersona = resolved
    }

    /// Resolves the active persona for a specific character, taking into account
    /// characterOverrides or default persona settings.
    func resolvePersona(forCharacterID characterID: String?) -> Persona {
        if let characterID, let overridePersonaID = characterOverrides[characterID],
           let matched = personas.first(where: { $0.externalID == overridePersonaID || $0.id == overridePersonaID }) {
            return matched
        }
        if let defaultID = defaultPersonaID,
           let matched = personas.first(where: { $0.externalID == defaultID || $0.id == defaultID }) {
            return matched
        }
        if let selected = personas.first(where: {
            $0.externalID == activePersona.externalID || $0.id == activePersona.id
        }) {
            return selected
        }
        return activePersona
    }

    /// Fetches real user personas from Character.AI backend
    func fetchRemotePersonas(
        authenticatedClient: AuthenticatedHTTPClient,
        currentCharacterID: String? = nil
    ) async {
        guard !isLoadingPersonas else { return }
        isLoadingPersonas = true
        defer { isLoadingPersonas = false }

        // 1. Fetch Personas List
        if let url = URL(string: "https://neo.character.ai/character/v1/get_user_personas?force_refresh=0") {
            do {
                let response: UserPersonasResponse = try await authenticatedClient.get(url)
                let remoteList = response.personas.map { $0.toPersona() }
                self.personas = remoteList
                persistPersonas()

                // Keep an existing local selection if it is still an actual remote persona.
                // The server's default is resolved after settings load below.
                if let currentActive = remoteList.first(where: {
                    $0.id == activePersona.id || $0.externalID == activePersona.externalID
                }) {
                    self.activePersona = currentActive
                } else if let defaultID = defaultPersonaID,
                          let defaultPersona = remoteList.first(where: {
                              $0.id == defaultID || $0.externalID == defaultID
                          }) {
                    self.activePersona = defaultPersona
                } else if let firstPersona = remoteList.first {
                    self.activePersona = firstPersona
                }
            } catch {
                logger.error("Failed to load user personas: \(error.localizedDescription, privacy: .public)")
            }
        }

        // 2. Fetch User Settings & Persona Overrides
        if let settingsURL = URL(string: "https://plus.character.ai/chat/user/settings/?v=2") {
            do {
                let response: UserSettingsResponse = try await authenticatedClient.get(settingsURL)
                if let settings = response.personaSettings {
                    if let defID = settings.defaultPersonaId {
                        self.defaultPersonaID = defID
                        defaults.set(defID, forKey: Keys.defaultPersonaID)
                    }
                    if let overrides = settings.characterOverrides {
                        self.characterOverrides = overrides
                        defaults.set(overrides, forKey: Keys.characterOverrides)
                    }
                    let selectedID = currentCharacterID.flatMap { settings.characterOverrides?[$0] }
                        ?? settings.defaultPersonaId
                    if let selectedID,
                       let selectedPersona = personas.first(where: {
                           $0.id == selectedID || $0.externalID == selectedID
                       }) {
                        self.activePersona = selectedPersona
                        defaults.set(selectedPersona.id, forKey: Keys.activePersonaID)
                    }
                } else if let overrides = response.personaOverrides {
                    self.characterOverrides = overrides
                    defaults.set(overrides, forKey: Keys.characterOverrides)
                    if let defID = response.defaultPersonaId {
                        self.defaultPersonaID = defID
                        defaults.set(defID, forKey: Keys.defaultPersonaID)
                    }
                    let selectedID = currentCharacterID.flatMap { response.personaOverrides?[$0] }
                        ?? response.defaultPersonaId
                    if let selectedID,
                       let selectedPersona = personas.first(where: {
                           $0.id == selectedID || $0.externalID == selectedID
                       }) {
                        self.activePersona = selectedPersona
                        defaults.set(selectedPersona.id, forKey: Keys.activePersonaID)
                    }
                }
            } catch {
                logger.error("Failed to load persona settings: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Selects a persona and optionally updates the Character.AI backend override for a specific character
    func selectPersona(
        _ persona: Persona,
        forCharacterID characterID: String? = nil,
        authenticatedClient: AuthenticatedHTTPClient? = nil
    ) async {
        guard personas.contains(where: { $0.externalID == persona.externalID }) else { return }

        guard let characterID, !characterID.isEmpty else { return }

        guard personas.contains(where: { $0.externalID == persona.externalID }) else { return }
        guard let characterID, !characterID.isEmpty else { return }
        guard let authenticatedClient else {
            logger.error("Persona selection could not be saved because no authenticated client was provided")
            return
        }

        var updated = characterOverrides
        updated[characterID] = persona.externalID

        do {
            guard let url = URL(string: "https://plus.character.ai/chat/user/update_settings/") else { return }
            let request = UpdatePersonaOverridesRequest(personaOverrides: updated)
            let _: UpdateSettingsResponse = try await authenticatedClient.post(url, body: request)
            characterOverrides = updated
            defaults.set(updated, forKey: Keys.characterOverrides)
        } catch {
            logger.error("Failed to update persona override: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Syncs the default persona with the signed-in user profile if available
    /// Updates the private no-persona fallback identity; it is never included in
    /// `personas` and can therefore never appear as a selectable Persona.
    func syncDefaultUser(username: String, avatarFileName: String?) {
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUsername.isEmpty, activePersona.isDefaultUser else { return }
        activePersona = Persona.defaultUser(
            username: cleanUsername,
            avatarFileName: avatarFileName
        )
    }

    private func persistPersonas() {
        if let data = try? JSONEncoder().encode(personas) {
            defaults.set(data, forKey: Keys.personasList)
        }
    }
}
