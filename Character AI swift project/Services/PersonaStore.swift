import Foundation
import Combine

/// Manages local user personas with persistence.
/// Ensures that switching personas updates the composer, message sessions,
/// and future turn authors without breaking existing conversations.
@MainActor
final class PersonaStore: ObservableObject {
    static let shared = PersonaStore()

    private enum Keys {
        static let personasList = "preferences.personas.list"
        static let activePersonaID = "preferences.personas.activeID"
    }

    @Published private(set) var personas: [Persona] = []
    @Published private(set) var activePersona: Persona

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Load saved personas or provide defaults
        if let data = defaults.data(forKey: Keys.personasList),
           let saved = try? JSONDecoder().decode([Persona].self, from: data),
           !saved.isEmpty {
            self.personas = saved
        } else {
            let initial = [
                Persona.defaultUser(username: "User"),
                Persona(
                    id: "persona_creative",
                    name: "Storyteller",
                    displayName: "Storyteller",
                    avatarFileName: nil,
                    isDefaultUser: false
                ),
                Persona(
                    id: "persona_scholar",
                    name: "Researcher",
                    displayName: "Researcher",
                    avatarFileName: nil,
                    isDefaultUser: false
                )
            ]
            self.personas = initial
            if let data = try? JSONEncoder().encode(initial) {
                defaults.set(data, forKey: Keys.personasList)
            }
        }

        let savedID = defaults.string(forKey: Keys.activePersonaID)
        let resolved = personas.first(where: { $0.id == savedID }) ?? personas.first ?? Persona.defaultUser()
        self.activePersona = resolved
    }

    /// Syncs the default persona with the signed-in user profile if available
    func syncDefaultUser(username: String, avatarFileName: String?) {
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUsername.isEmpty else { return }

        var updated = personas
        if let idx = updated.firstIndex(where: { $0.isDefaultUser || $0.id == "default_user" }) {
            let existing = updated[idx]
            updated[idx] = Persona(
                id: existing.id,
                name: cleanUsername,
                displayName: cleanUsername,
                avatarFileName: avatarFileName ?? existing.avatarFileName,
                isDefaultUser: true
            )
        } else {
            updated.insert(
                Persona(
                    id: "default_user",
                    name: cleanUsername,
                    displayName: cleanUsername,
                    avatarFileName: avatarFileName,
                    isDefaultUser: true
                ),
                at: 0
            )
        }
        self.personas = updated
        persistPersonas()

        if activePersona.isDefaultUser || activePersona.id == "default_user" {
            self.activePersona = updated.first(where: { $0.isDefaultUser }) ?? activePersona
            defaults.set(activePersona.id, forKey: Keys.activePersonaID)
        }
    }

    /// Selects an active persona
    func selectPersona(_ persona: Persona) {
        guard personas.contains(where: { $0.id == persona.id }) else { return }
        self.activePersona = persona
        defaults.set(persona.id, forKey: Keys.activePersonaID)
    }

    /// Adds a custom persona
    func addPersona(name: String, avatarFileName: String? = nil) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return }
        let newPersona = Persona(
            id: UUID().uuidString.lowercased(),
            name: cleanName,
            displayName: cleanName,
            avatarFileName: avatarFileName,
            isDefaultUser: false
        )
        personas.append(newPersona)
        persistPersonas()
    }

    private func persistPersonas() {
        if let data = try? JSONEncoder().encode(personas) {
            defaults.set(data, forKey: Keys.personasList)
        }
    }
}
