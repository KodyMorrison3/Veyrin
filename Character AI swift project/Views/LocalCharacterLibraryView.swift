import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LocalCharacterLibraryView: View {
    /// Nil hides Start chat, which is what the Character.AI window wants: there
    /// the provider window owns chatting, so the library only edits characters.
    var onStartChat: ((LocalCharacter?) -> Void)? = nil
    @StateObject private var library = LocalCharacterLibrary.shared
    @State private var query = ""
    @State private var source = "All sources"
    @State private var tag = "All tags"
    @State private var selectedCharacter: LocalCharacter?
    @State private var notice: String?
    @State private var pendingRightsAction: LibraryRightsAction?
    @State private var showingRightsConfirmation = false
    @State private var pendingRemoval: LocalCharacter?

    private var results: [LocalCharacter] { library.matching(query, source: source, tag: tag) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("My Library").font(.largeTitle.weight(.semibold))
                Spacer()
                Button("Import archive…", systemImage: "square.and.arrow.down") { confirmRights(for: .importArchive) }
                Button("Import Character.AI export…", systemImage: "person.crop.square.badge.plus") { confirmRights(for: .importAccountExport) }
                Button("Export library…", systemImage: "square.and.arrow.up") { confirmRights(for: .exportLibrary) }
            }
            .padding(20)

            HStack(spacing: 12) {
                TextField("Search name, tags, source…", text: $query)
                    .textFieldStyle(.roundedBorder)
                Picker("Source", selection: $source) {
                    ForEach(library.sources, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 220)
                Picker("Tag", selection: $tag) {
                    ForEach(library.tags, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 180)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            if let notice {
                Text(notice).font(.callout).foregroundStyle(.secondary).padding(.horizontal)
            }
            if let error = library.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).padding()
            }

            if results.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "Your Library Is Empty" : "No Matching Characters",
                    systemImage: "books.vertical",
                    description: Text(query.isEmpty ? "Import a Veyrin archive or Character.AI export to add characters." : "Try another name, tag, or source.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                        // In a provider chat the grid also picks the provider itself,
                        // which replaces the old "No Character" menu entry.
                        if let onStartChat {
                            Button { onStartChat(nil) } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    ZStack {
                                        Rectangle().fill(.secondary.opacity(0.10))
                                        Image(systemName: "person.crop.circle.badge.xmark")
                                            .font(.system(size: 34))
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 168)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("No character").font(.headline.weight(.semibold))
                                        Text("Send messages straight to this provider, with no character prompt or greeting.")
                                            .font(.callout).foregroundStyle(.secondary).lineLimit(3)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.bottom, 12)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentSurface(cornerRadius: 14)
                                .contentShape(RoundedRectangle(cornerRadius: 14))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Chat without a character")
                        }

                        ForEach(results) { character in
                            ZStack(alignment: .topTrailing) {
                                Button { selectedCharacter = character } label: {
                                    VStack(alignment: .leading, spacing: 10) {
                                        ZStack(alignment: .bottomLeading) {
                                            if let fileName = character.avatarFileName,
                                               let url = CharacterImageURL.makeURL(avatarFileName: fileName) {
                                                CachedAvatarView(url: url) {
                                                    avatarFallback(character.name)
                                                }
                                                .frame(maxWidth: .infinity)
                                                .frame(height: 168)
                                                .clipped()
                                            } else {
                                                avatarFallback(character.name)
                                                    .frame(maxWidth: .infinity)
                                                    .frame(height: 168)
                                            }
                                            Text(character.name)
                                                .font(.headline.weight(.semibold))
                                                .foregroundStyle(.white)
                                                .lineLimit(2)
                                                .shadow(color: .black.opacity(0.6), radius: 5)
                                                .padding(12)
                                        }
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(character.tagline.isEmpty ? character.description : character.tagline)
                                                .font(.callout).foregroundStyle(.secondary).lineLimit(3)
                                            HStack(spacing: 6) {
                                                Text(character.sourcePlatform)
                                                if let count = character.interactionCount {
                                                    Text("· \(count.formatted()) chats")
                                                }
                                            }
                                            .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.bottom, 12)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentSurface(cornerRadius: 14)
                                    .contentShape(RoundedRectangle(cornerRadius: 14))
                                }
                                .buttonStyle(.plain)

                                Button { pendingRemoval = character } label: {
                                    Image(systemName: "trash")
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 32, height: 32)
                                        .background(.black.opacity(0.38), in: Circle())
                                        .overlay(Circle().strokeBorder(.white.opacity(0.22)))
                                        .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .padding(10)
                                .help("Remove \(character.name) from My Library")
                                .accessibilityLabel("Remove \(character.name) from My Library")
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 1100)
                    .frame(maxWidth: .infinity)
                }
                .alert(
                    "Remove from My Library?",
                    isPresented: Binding(
                        get: { pendingRemoval != nil },
                        set: { if !$0 { pendingRemoval = nil } }
                    ),
                    presenting: pendingRemoval
                ) { character in
                    Button("Remove from My Library", role: .destructive) { remove(character) }
                    Button("Cancel", role: .cancel) { pendingRemoval = nil }
                } message: { character in
                    Text("\(character.name) and its saved local chat history will be removed from this Mac. This cannot be undone.")
                }
            }
        }
        .navigationTitle("My Library")
        .popover(item: $selectedCharacter) { character in
            LocalCharacterDetailView(
                character: character,
                library: library,
                onStartChat: onStartChat,
                onDismiss: { selectedCharacter = nil }
            )
            .frame(width: 520, height: 560)
            .background { ShellEnvironmentalBackground() }
            .presentationBackground(.regularMaterial)
        }
        .confirmationDialog(
            pendingRightsAction?.confirmationTitle ?? "Character content notice",
            isPresented: $showingRightsConfirmation,
            titleVisibility: .visible
        ) {
            Button(pendingRightsAction?.continueTitle ?? "Continue") {
                guard let action = pendingRightsAction else { return }
                pendingRightsAction = nil
                perform(action)
            }
            Button("Cancel", role: .cancel) { pendingRightsAction = nil }
        } message: {
            Text("Characters may be third-party content and their rights may not be specified. You are responsible for respecting the source service’s terms and creators’ rights. This is general information, not legal advice.")
        }
        .alert("Library Error", isPresented: Binding(
            get: { library.errorMessage != nil },
            set: { if !$0 { library.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { library.errorMessage = nil }
        } message: { Text(library.errorMessage ?? "Please try again.") }
    }

    private func remove(_ character: LocalCharacter) {
        do {
            try library.remove(character.id, deletingConversation: true)
            if selectedCharacter?.id == character.id { selectedCharacter = nil }
            notice = "Removed \(character.name) from your library."
        } catch {
            library.errorMessage = error.localizedDescription
        }
        pendingRemoval = nil
    }

    private func confirmRights(for action: LibraryRightsAction) {
        pendingRightsAction = action
        showingRightsConfirmation = true
    }

    private func perform(_ action: LibraryRightsAction) {
        switch action {
        case .importArchive: importArchive()
        case .importAccountExport: importCharacterAIExport()
        case .exportLibrary: exportArchive()
        }
    }

    private func importArchive() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do { notice = "Imported \(try library.importArchive(from: url)) archive records." }
            catch { library.errorMessage = error.localizedDescription }
        }
    }

    private func importCharacterAIExport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = "Select the Character.AI export ZIP, its extracted folder, or character.json."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let result = try library.importCharacterAIAccountExport(from: url)
                var message = "Imported \(result.importedCount) characters from your account export."
                if result.skippedCount > 0 {
                    message += " Skipped \(result.skippedCount) records without usable names or IDs."
                }
                if result.missingDefinitionCount > 0 {
                    message += " \(result.missingDefinitionCount) did not include a character definition."
                }
                notice = message
            } catch {
                library.errorMessage = error.localizedDescription
            }
        }
    }

    private func avatarFallback(_ name: String) -> some View {
        ZStack {
            Rectangle().fill(.secondary.opacity(0.14))
            Text(String(name.prefix(1)).uppercased())
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func exportArchive() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "veyrin-library.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try library.exportArchive(to: url); notice = "Library exported." }
            catch { library.errorMessage = error.localizedDescription }
        }
    }
}

private enum LibraryRightsAction {
    case importArchive
    case importAccountExport
    case exportLibrary

    var confirmationTitle: String {
        switch self {
        case .importArchive: "Import character archive?"
        case .importAccountExport: "Import account export?"
        case .exportLibrary: "Export character library?"
        }
    }

    var continueTitle: String {
        switch self {
        case .importArchive, .importAccountExport: "Continue to Import"
        case .exportLibrary: "Continue to Export"
        }
    }
}

private struct LocalCharacterDetailView: View {
    let character: LocalCharacter
    @ObservedObject var library: LocalCharacterLibrary
    var onStartChat: ((LocalCharacter?) -> Void)?
    let onDismiss: () -> Void
    @ObservedObject private var preferences = AppPreferences.shared

    @State private var isEditing = false
    @State private var aboutDraft = ""
    @State private var greetingDraft = ""
    @State private var editError: String?

    /// Read through the library so a saved edit shows straight away instead of
    /// the snapshot this popover was opened with.
    private var current: LocalCharacter {
        library.characters.first { $0.id == character.id } ?? character
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasUnsavedEdit: Bool {
        trimmed(aboutDraft) != current.description || trimmed(greetingDraft) != current.greeting
    }

    private func avatarFallback(_ name: String, size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(preferences.environmentalPalette.glassSurfaceTint)
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(Color.caiText)
        }
        .frame(width: size, height: size)
    }

    var body: some View {
        ScrollView {
            if isEditing {
                editor
            } else {
                details
            }
        }
        .overlay(alignment: .topLeading) {
            Button(action: onDismiss) {
                Label("Back", systemImage: "chevron.backward")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .glassSurface(.floatingControl, cornerRadius: 16)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .padding(.leading, 20)
            .padding(.top, 12)
            .accessibilityLabel("Close character details")
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if !current.description.isEmpty {
                section("About") { Text(current.description).textSelection(.enabled) }
            }
            if !current.tags.isEmpty {
                section("Tags") {
                    Label(current.tags.joined(separator: " · "), systemImage: "tag")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !current.greeting.isEmpty {
                section("Greeting") { Text(current.greeting).textSelection(.enabled) }
            }
            if !current.examples.isEmpty {
                section("Example dialogue") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(current.examples.prefix(4).enumerated()), id: \.offset) { _, example in
                            Text(example).textSelection(.enabled)
                            if example != current.examples.prefix(4).last { Divider() }
                        }
                    }
                }
            }
            DisclosureGroup("Source and rights details") {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Creator: \(current.creatorName.isEmpty ? "Not stated" : current.creatorName)")
                    Text("Licence claim: \(current.licence)")
                    Text("Source: \(current.sourceURL.isEmpty ? current.sourceName : current.sourceURL)")
                    Text("Imported: \(current.importedAt)")
                }
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            }
        }
        .padding(.top, 56)
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    /// Editing lives inline: macOS sheets and dialogs are unreliable inside a
    /// popover, so the detail view swaps into a form instead of presenting one.
    private var editor: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Edit \(current.name)").font(.title3.weight(.semibold))
                Spacer(minLength: 8)
                Button("Cancel") {
                    editError = nil
                    isEditing = false
                }
                Button("Save", action: save)
                    .buttonStyle(GlassProminentButtonStyle())
                    .disabled(!hasUnsavedEdit)
                    .help(hasUnsavedEdit ? "Save changes to this character" : "Nothing to save yet")
            }

            editField("About", text: $aboutDraft, minHeight: 150,
                      help: "What this character is: setting, personality and history. Sent as part of the character prompt.")
            editField("Greeting", text: $greetingDraft, minHeight: 150,
                      help: "The first message of a new conversation. Saved conversations keep their existing messages.")

            if let editError {
                Label(editError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Only About and the greeting are editable here. The name, avatar, tags and source details stay as imported, so the character's origin is never rewritten.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Load the draft when the form appears, so cancelling and reopening —
        // or saving and editing again — always starts from the saved text.
        .onAppear {
            aboutDraft = current.description
            greetingDraft = current.greeting
        }
        .padding(.top, 56)
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    private func editField(_ title: String, text: Binding<String>, minHeight: CGFloat, help: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            TextEditor(text: text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: minHeight)
                .contentSurface(cornerRadius: 10)
                .accessibilityLabel(title)
            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func save() {
        do {
            try library.updateDetails(for: current.id, about: aboutDraft, greeting: greetingDraft)
            editError = nil
            isEditing = false
        } catch {
            editError = error.localizedDescription
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            if let fileName = current.avatarFileName,
               let url = CharacterImageURL.makeURL(avatarFileName: fileName) {
                CachedAvatarView(url: url) { avatarFallback(current.name, size: 64) }
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                avatarFallback(current.name, size: 64)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(current.name)
                    .font(.title2.weight(.semibold))
                if !current.tagline.isEmpty {
                    Text(current.tagline)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                Text(current.origin + " · " + current.sourcePlatform)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    if let count = current.interactionCount {
                        Label(count.formatted(), systemImage: "bubble.left")
                    }
                    if let visibility = current.visibility {
                        Text(visibility.replacingOccurrences(of: "VISIBILITY_", with: "").lowercased().capitalized)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            // Two pills do not fit beside the name at this width, and a wrapped
            // "Start / chat" reads as a layout bug, so the provider copy stacks
            // them and pins each to one line. The Character.AI copy keeps the
            // single Edit pill it always had.
            if let onStartChat {
                VStack(alignment: .trailing, spacing: 8) {
                    Button("Start chat", systemImage: "bubble.left.and.bubble.right") { onStartChat(current) }
                        .buttonStyle(GlassProminentButtonStyle())
                        .help("Open this character's conversation in the current provider chat")
                    editButton
                }
                .controlSize(.small)
                .lineLimit(1)
                .fixedSize()
            } else {
                editButton
            }
        }
    }

    /// From the Character.AI window there is no provider chat to start, so that
    /// copy edits the character instead.
    private var editButton: some View {
        Button("Edit", systemImage: "square.and.pencil") {
            editError = nil
            isEditing = true
        }
        .buttonStyle(GlassProminentButtonStyle())
        .help("Edit this character's About and greeting")
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
