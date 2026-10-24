import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Shared read-only picker/inspector for the identity the user roleplays as.
/// Observing each store keeps unavailable/deleted/account-switched identities
/// visible as unavailable rather than silently selecting another persona.
struct RoleplayPersonaControl: View {
    @ObservedObject var context: RoleplayPersonaContext
    @ObservedObject private var local: LocalPersonaStore
    @ObservedObject private var account: PersonaStore
    @ObservedObject private var saved: RoleplayPersonaSelections
    @State private var isPresented = false
    @State private var isChoosingPersona = false
    var isGenerating = false

    init(context: RoleplayPersonaContext, isGenerating: Bool = false) {
        self.context = context
        self.local = context.local
        self.account = context.account
        self.saved = context.saved
        self.isGenerating = isGenerating
    }

    private var title: String {
        context.persona?.displayName ?? (context.unavailable ? "Persona unavailable" : "No Persona")
    }

    var body: some View {
        Button { isPresented.toggle() } label: {
            Label {
                Text(title).lineLimit(1)
            } icon: {
                if let persona = context.persona { PersonaAvatarView(persona: persona, size: 22) }
                else { Image(systemName: "person.crop.circle") }
            }
        }
        .help("Your roleplay persona: \(title)")
        .accessibilityLabel("Your roleplay persona: \(title)")
        .popover(isPresented: $isPresented) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Your Roleplay Persona").font(.headline)
                    Text("This describes you, not the AI character. Changes apply to future replies; existing messages and greetings stay unchanged.")
                        .font(.caption).foregroundStyle(.secondary)
                    // One scroll view for the whole popover. A second one here
                    // chained its leftover scroll to the window behind, which
                    // moved the chat and closed the popover.
                    DisclosureGroup(isExpanded: $isChoosingPersona) {
                        VStack(alignment: .leading, spacing: 8) {
                            Button("No Persona") {
                                context.select(nil)
                                isChoosingPersona = false
                            }
                            if !local.personas.isEmpty {
                                Text("Imported").font(.caption).foregroundStyle(.secondary)
                                ForEach(local.personas) { persona in
                                    choice(persona, reference: RoleplayPersonaReference(source: .local, personaID: persona.externalID))
                                }
                            }
                            if let owner = account.ownerID, !account.personas.isEmpty {
                                Text("Character.AI · Loaded Account").font(.caption).foregroundStyle(.secondary)
                                ForEach(account.personas) { persona in
                                    choice(persona, reference: RoleplayPersonaReference(source: .account,
                                            personaID: persona.externalID, accountID: owner))
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    } label: { Text("Choose Persona") }
                    .disabled(isGenerating || !saved.isReadable)
                    if isGenerating {
                        Text("Wait for the current reply to finish before changing persona.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let persona = context.persona {
                        HStack(spacing: 10) {
                            PersonaAvatarView(persona: persona, size: 48)
                            Text(persona.displayName).font(.title3.weight(.semibold))
                        }
                        detail("Title", persona.title)
                        detail("Description", persona.description)
                        detail("Definition", persona.definition)
                        Text("Persona names and details are included with the character instructions when you send a message.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if context.unavailable {
                        Text("The saved persona is deleted or its Character.AI account is not loaded. No persona details will be sent. Choose an available persona or No Persona.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("No user persona is attached. The AI still uses the selected character’s roleplay instructions.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if local.personas.isEmpty && account.personas.isEmpty {
                        Text("Import a persona in Settings → Personas, or open a Character.AI chat to load your account personas.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = context.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
                    } else if !saved.isReadable {
                        Text(LocalPersonaStoreError.selectionStorageUnavailable.localizedDescription)
                            .font(.caption).foregroundStyle(.red)
                    }
                    Text(context.characterID == nil
                         ? "This selection is temporary until you choose a saved character."
                         : "Remembered for this character across local and cloud chats. Selecting a persona sends nothing by itself.")
                        .font(.caption).foregroundStyle(.secondary)
                    SettingsLink { Label("Manage Personas…", systemImage: "gearshape") }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 340, height: 420)
            .background { ShellEnvironmentalBackground() }
            .presentationBackground(.regularMaterial)
        }
    }

    private func choice(_ persona: Persona, reference: RoleplayPersonaReference) -> some View {
        Button {
            context.select(reference)
            isChoosingPersona = false
        } label: {
            HStack(spacing: 8) {
                PersonaAvatarView(persona: persona, size: 26)
                Text(persona.displayName).lineLimit(1)
                Spacer()
                if context.reference == reference { Image(systemName: "checkmark") }
            }
            .padding(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Select persona \(persona.displayName)")
        .accessibilityAddTraits(context.reference == reference ? .isSelected : [])
    }

    @ViewBuilder private func detail(_ heading: String, _ value: String?) -> some View {
        if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(heading).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(value).font(.callout).textSelection(.enabled)
            }
        }
    }
}

/// Settings pane for moving personas between Character.AI and Veyrin's local
/// and cloud text chats. Account personas are read-only; imported personas are
/// stored locally so they keep working offline and with any provider.
struct PersonaSettingsView: View {
    @ObservedObject var accountPersonas: PersonaStore
    @ObservedObject var localPersonas: LocalPersonaStore
    @State private var pendingDeletion: Persona?
    @State private var notice: String?

    init(accountPersonas: PersonaStore, localPersonas: LocalPersonaStore = .shared) {
        self.accountPersonas = accountPersonas
        self.localPersonas = localPersonas
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 8) {
                section(
                    title: "For Local & Cloud Chats",
                    footer: "Import Veyrin persona JSON, character-card JSON, or a plain-text/Markdown prompt. Persona text is sent to Ollama or your cloud provider only when you send a message with that persona selected. Pictures are shown here and in chats, not sent to text models; exports include the picture."
                ) {
                    HStack(spacing: 8) {
                        Button("Import Persona…", systemImage: "square.and.arrow.down") { importPersonas() }
                        Spacer()
                        Button("Export All…", systemImage: "square.and.arrow.up") { exportAll() }
                            .disabled(localPersonas.personas.isEmpty)
                    }
                    .padding(.vertical, 4)
                }

                if let error = localPersonas.errorMessage {
                    message(error, color: .red)
                } else if let notice {
                    message(notice, color: .secondary)
                }

                if localPersonas.personas.isEmpty {
                    ContentUnavailableView("No Imported Personas",
                                           systemImage: "person.crop.rectangle.stack",
                                           description: Text("Import a persona file to use it with local and cloud providers."))
                        .frame(maxWidth: .infinity, minHeight: 190)
                } else {
                    VStack(spacing: 0) {
                        ForEach(localPersonas.personas) { persona in
                            localRow(persona)
                            if persona.id != localPersonas.personas.last?.id { Divider() }
                        }
                    }
                    .padding(.horizontal, 20)
                }

                section(
                    title: "Character.AI Personas",
                    footer: accountPersonas.personas.isEmpty
                        ? "Sign in and open a Character.AI chat to load your account personas, then export one to bring it into local or cloud chats."
                        : "These stay on your Character.AI account. Exporting creates a portable copy; importing it above makes it available to local and cloud providers."
                ) {
                    if let error = accountPersonas.personaListErrorMessage {
                        message("Personas couldn't be loaded: \(error)", color: .red)
                    } else if accountPersonas.isLoadingPersonas {
                        ProgressView("Loading personas…")
                            .controlSize(.small)
                            .padding(.vertical, 6)
                    } else if accountPersonas.personas.isEmpty {
                        Text("No account personas are loaded.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(accountPersonas.personas) { persona in
                            accountRow(persona)
                            if persona.id != accountPersonas.personas.last?.id { Divider() }
                        }
                    }
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .confirmationDialog(
            "Delete \(pendingDeletion?.displayName ?? "this persona")?",
            isPresented: Binding(get: { pendingDeletion != nil },
                                 set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Persona", role: .destructive) {
                guard let persona = pendingDeletion else { return }
                pendingDeletion = nil
                Task {
                    do {
                        try await localPersonas.delete(persona)
                        notice = "Persona deleted."
                    } catch {
                        localPersonas.errorMessage = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("This removes the imported copy from Veyrin. The Character.AI persona and any exported files are not affected.")
        }
    }

    private func localRow(_ persona: Persona) -> some View {
        HStack(alignment: .top, spacing: 12) {
            PersonaAvatarView(persona: persona)
            VStack(alignment: .leading, spacing: 4) {
                Text(persona.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if let title = persona.title, !title.isEmpty {
                    Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let description = persona.description, !description.isEmpty {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            Menu {
                Button("Export JSON…", systemImage: "doc.badge.arrow.up") { export(persona, markdown: false) }
                Button("Export Markdown Prompt…", systemImage: "text.alignleft") { export(persona, markdown: true) }
                Divider()
                Button("Delete Persona…", systemImage: "trash", role: .destructive) { pendingDeletion = persona }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("\(persona.displayName) actions")
        }
        .padding(.vertical, 10)
    }

    private func accountRow(_ persona: Persona) -> some View {
        HStack(alignment: .top, spacing: 12) {
            PersonaAvatarView(persona: persona)
            VStack(alignment: .leading, spacing: 4) {
                Text(persona.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if let title = persona.title, !title.isEmpty {
                    Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Menu {
                Button("Export JSON…", systemImage: "doc.badge.arrow.up") { export(persona, markdown: false) }
                Button("Export Markdown Prompt…", systemImage: "text.alignleft") { export(persona, markdown: true) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Export \(persona.displayName)")
        }
        .padding(.vertical, 10)
    }

    private func message(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(color)
            .padding(.horizontal, 20)
    }

    private func section<Content: View>(title: String? = nil, footer: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title { Text(title).font(.headline) }
            content()
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private func importPersonas() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .markdown, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a Veyrin persona, character-card JSON, or text prompt."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    let imported = try await localPersonas.importPersonas(from: url)
                    notice = imported.count == 1
                        ? "Imported \(imported[0].displayName)."
                        : "Imported \(imported.count) personas."
                    localPersonas.errorMessage = nil
                } catch {
                    localPersonas.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func export(_ persona: Persona, markdown: Bool) {
        let panel = NSSavePanel()
        if markdown {
            panel.allowedContentTypes = [.markdown]
            panel.nameFieldStringValue = filename(for: persona.displayName, suffix: ".md")
        } else {
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = filename(for: persona.displayName, suffix: ".persona.json")
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    try await localPersonas.export(persona, to: url)
                    notice = markdown ? "Markdown prompt exported." : "Persona exported."
                    localPersonas.errorMessage = nil
                } catch {
                    localPersonas.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func filename(for name: String, suffix: String) -> String {
        let safe = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (safe.isEmpty ? "persona" : safe) + suffix
    }

    private func exportAll() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "veyrin-personas.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    try await localPersonas.exportAll(to: url)
                    notice = "Personas exported."
                    localPersonas.errorMessage = nil
                } catch {
                    localPersonas.errorMessage = error.localizedDescription
                }
            }
        }
    }
}
