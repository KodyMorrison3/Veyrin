import Foundation
import Combine
import OSLog

private let logger = Logger(subsystem: "CharacterAI", category: "PersonaStore")

/// Manages server personas and their per-character settings overrides.
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
    @Published private(set) var personaSelectionErrorMessage: String?
    @Published private(set) var isSelectingPersona = false
    @Published private(set) var personaListErrorMessage: String?
    @Published private(set) var personaSettingsErrorMessage: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved: [Persona]
        if let data = defaults.data(forKey: Keys.personasList),
           let decoded = try? JSONDecoder().decode([Persona].self, from: data) {
            saved = decoded.filter { !$0.isDefaultUser && $0.id != "default_user" && !$0.id.hasPrefix("persona_") }
            if saved.count != decoded.count, let migrated = try? JSONEncoder().encode(saved) {
                defaults.set(migrated, forKey: Keys.personasList)
            }
        } else {
            saved = []
        }

        characterOverrides = defaults.dictionary(forKey: Keys.characterOverrides) as? [String: String] ?? [:]
        defaultPersonaID = defaults.string(forKey: Keys.defaultPersonaID)
        let storedDefaultID = defaults.string(forKey: Keys.defaultPersonaID)
        let savedID = defaults.string(forKey: Keys.activePersonaID)
        let resolved = saved.first(where: { $0.id == savedID || $0.externalID == savedID })
            ?? saved.first(where: { $0.id == storedDefaultID || $0.externalID == storedDefaultID })
            ?? saved.first
            ?? Persona.defaultUser()
        personas = saved
        activePersona = resolved
    }

    func resolvePersona(forCharacterID characterID: String?) -> Persona {
        if let characterID, let id = characterOverrides[characterID],
           let persona = personas.first(where: { $0.externalID == id || $0.id == id }) {
            return persona
        }
        if let defaultPersonaID,
           let persona = personas.first(where: { $0.externalID == defaultPersonaID || $0.id == defaultPersonaID }) {
            return persona
        }
        return personas.first(where: {
            $0.externalID == activePersona.externalID || $0.id == activePersona.id
        }) ?? activePersona
    }

    func fetchRemotePersonas(
        authenticatedClient: AuthenticatedHTTPClient,
        currentCharacterID: String? = nil
    ) async {
        if isLoadingPersonas { return }
        personaListErrorMessage = nil
        personaSettingsErrorMessage = nil
        isLoadingPersonas = true
        defer { isLoadingPersonas = false }

        guard let personasURL = URL(string: "https://neo.character.ai/character/v1/get_user_personas?force_refresh=0") else {
            personaListErrorMessage = "The persona list address is invalid."
            return
        }
        do {
            let response: UserPersonasResponse = try await authenticatedClient.get(personasURL)
            let fetched = response.personas.map { $0.toPersona() }
            personas = fetched
            persistPersonas()
            if let match = fetched.first(where: { $0.id == activePersona.id || $0.externalID == activePersona.externalID }) {
                activePersona = match
            } else if let first = fetched.first {
                activePersona = first
            }
        } catch {
            personaListErrorMessage = error.localizedDescription
            logger.error("Failed to load user personas: \(error.localizedDescription, privacy: .private)")
        }

        guard let settingsURL = URL(string: "https://plus.character.ai/chat/user/settings/?v=2") else {
            personaSettingsErrorMessage = "The persona settings address is invalid."
            return
        }
        do {
            let response: UserSettingsResponse = try await authenticatedClient.get(settingsURL)
            if let settings = response.personaSettings {
                if let defaultID = settings.defaultPersonaId {
                    defaultPersonaID = defaultID
                    defaults.set(defaultID, forKey: Keys.defaultPersonaID)
                }
                if let overrides = settings.characterOverrides {
                    characterOverrides = overrides
                    defaults.set(overrides, forKey: Keys.characterOverrides)
                }
                let selectedID = currentCharacterID.flatMap { settings.characterOverrides?[$0] }
                    ?? settings.defaultPersonaId
                updateActivePersona(matching: selectedID)
            } else {
                if let overrides = response.personaOverrides {
                    characterOverrides = overrides
                    defaults.set(overrides, forKey: Keys.characterOverrides)
                }
                if let defaultID = response.defaultPersonaId {
                    defaultPersonaID = defaultID
                    defaults.set(defaultID, forKey: Keys.defaultPersonaID)
                }
                let selectedID = currentCharacterID.flatMap { response.personaOverrides?[$0] }
                    ?? response.defaultPersonaId
                updateActivePersona(matching: selectedID)
            }
        } catch {
            personaSettingsErrorMessage = error.localizedDescription
            logger.error("Failed to load persona settings: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Writes the per-character override. The write endpoint's contract still
    /// needs live confirmation; no local selection is committed on failure.
    func selectPersona(
        _ persona: Persona,
        forCharacterID characterID: String?,
        authenticatedClient: AuthenticatedHTTPClient?
    ) async -> Bool {
        personaSelectionErrorMessage = nil
        guard !isSelectingPersona else { return false }
        guard let characterID, !characterID.isEmpty else {
            personaSelectionErrorMessage = "Persona selection requires a character conversation."
            return false
        }
        guard personas.contains(where: { $0.externalID == persona.externalID }) else {
            personaSelectionErrorMessage = "That persona is no longer available."
            return false
        }
        guard let authenticatedClient,
              let url = URL(string: "https://plus.character.ai/chat/user/update_settings/") else {
            personaSelectionErrorMessage = "An authenticated persona settings request is unavailable."
            return false
        }

        var updated = characterOverrides
        updated[characterID] = persona.externalID
        isSelectingPersona = true
        defer { isSelectingPersona = false }
        do {
            let body = try JSONEncoder().encode(UpdatePersonaOverridesRequest(personaOverrides: updated))
            try await authenticatedClient.send(url, method: "POST", body: body)
            characterOverrides = updated
            defaults.set(updated, forKey: Keys.characterOverrides)
            return true
        } catch {
            personaSelectionErrorMessage = error.localizedDescription
            logger.error("Failed to update persona override: \(error.localizedDescription, privacy: .private)")
            return false
        }
    }

    private func updateActivePersona(matching id: String?) {
        guard let id, let persona = personas.first(where: { $0.id == id || $0.externalID == id }) else { return }
        activePersona = persona
        defaults.set(persona.id, forKey: Keys.activePersonaID)
    }

    private func persistPersonas() {
        guard let data = try? JSONEncoder().encode(personas) else { return }
        defaults.set(data, forKey: Keys.personasList)
    }
}
