import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings pane for moving personas between Character.AI and Veyrin's local
/// and cloud text chats. Account personas are read-only; imported personas are
/// stored locally so they keep working offline and with any provider.
struct PersonaSettingsView: View {
    @ObservedObject var accountPersonas: PersonaStore
    @StateObject private var localPersonas = LocalPersonaStore.shared
    @State private var pendingDeletion: Persona?
    @State private var notice: String?

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 8) {
                section(
                    title: "For Local & Cloud Chats",
                    footer: "Personas imported here are sent as the system prompt to Ollama and cloud providers. Files can be Veyrin persona JSON, character-card JSON, or a plain-text/Markdown prompt. Nothing is uploaded until you choose a persona in a provider chat."
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
        .confirmationDialog(
            "Delete \(pendingDeletion?.displayName ?? "this persona")?",
            isPresented: Binding(get: { pendingDeletion != nil },
                                 set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Persona", role: .destructive) {
                guard let persona = pendingDeletion else { return }
                do {
                    try localPersonas.delete(persona)
                    notice = "Persona deleted."
                } catch {
                    localPersonas.errorMessage = error.localizedDescription
                }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("This removes the imported copy from Veyrin. The Character.AI persona and any exported files are not affected.")
        }
    }

    private func localRow(_ persona: Persona) -> some View {
        HStack(alignment: .top, spacing: 12) {
            personaIcon(persona)
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
            personaIcon(persona)
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

    private func personaIcon(_ persona: Persona) -> some View {
        ZStack {
            Circle().fill(Color.caiPrimary.opacity(0.28))
            Text(persona.displayName.prefix(1).uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.caiText)
        }
        .frame(width: 26, height: 26)
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
            do {
                let imported = try localPersonas.importPersonas(from: url)
                notice = imported.count == 1
                    ? "Imported \(imported[0].displayName)."
                    : "Imported \(imported.count) personas."
                localPersonas.errorMessage = nil
            } catch {
                localPersonas.errorMessage = error.localizedDescription
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
            do {
                try localPersonas.export(persona, to: url)
                notice = markdown ? "Markdown prompt exported." : "Persona exported."
                localPersonas.errorMessage = nil
            } catch {
                localPersonas.errorMessage = error.localizedDescription
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
            do {
                try localPersonas.exportAll(to: url)
                notice = "Personas exported."
                localPersonas.errorMessage = nil
            } catch {
                localPersonas.errorMessage = error.localizedDescription
            }
        }
    }
}
