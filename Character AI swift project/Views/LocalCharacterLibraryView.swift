import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LocalCharacterLibraryView: View {
    @StateObject private var library = LocalCharacterLibrary.shared
    @State private var query = ""
    @State private var source = "All sources"
    @State private var tag = "All tags"
    @State private var selectedCharacter: LocalCharacter?
    @State private var notice: String?

    let onStartChat: (LocalCharacter) -> Void

    private var results: [LocalCharacter] { library.matching(query, source: source, tag: tag) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("My Library").font(.largeTitle.weight(.semibold))
                Spacer()
                Button("Import archive…", systemImage: "square.and.arrow.down") { importArchive() }
                Button("Import Character.AI export…", systemImage: "person.crop.square.badge.plus") { importCharacterAIExport() }
                Button("Export library…", systemImage: "square.and.arrow.up") { exportArchive() }
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
                        ForEach(results) { character in
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
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 1100)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("My Library")
        .popover(item: $selectedCharacter) { character in
            LocalCharacterDetailView(
                character: character,
                onStartChat: {
                    selectedCharacter = nil
                    onStartChat(character)
                },
                onDismiss: { selectedCharacter = nil }
            )
            .frame(width: 480, height: 560)
            .background { ShellEnvironmentalBackground() }
            .presentationBackground(.regularMaterial)
        }
        .alert("Library Error", isPresented: Binding(
            get: { library.errorMessage != nil },
            set: { if !$0 { library.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { library.errorMessage = nil }
        } message: { Text(library.errorMessage ?? "Please try again.") }
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

private struct LocalCharacterDetailView: View {
    let character: LocalCharacter
    let onStartChat: () -> Void
    let onDismiss: () -> Void
    @ObservedObject private var preferences = AppPreferences.shared

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
            VStack(alignment: .leading, spacing: 18) {
                header
                if !character.description.isEmpty {
                    section("About") { Text(character.description).textSelection(.enabled) }
                }
                if !character.tags.isEmpty {
                    section("Tags") {
                        Label(character.tags.joined(separator: " · "), systemImage: "tag")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !character.greeting.isEmpty {
                    section("Greeting") { Text(character.greeting).textSelection(.enabled) }
                }
                if !character.examples.isEmpty {
                    section("Example dialogue") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(character.examples.prefix(4).enumerated()), id: \.offset) { _, example in
                                Text(example).textSelection(.enabled)
                                if example != character.examples.prefix(4).last { Divider() }
                            }
                        }
                    }
                }
                DisclosureGroup("Source and rights details") {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Creator: \(character.creatorName.isEmpty ? "Not stated" : character.creatorName)")
                        Text("Licence claim: \(character.licence)")
                        Text("Source: \(character.sourceURL.isEmpty ? character.sourceName : character.sourceURL)")
                        Text("Imported: \(character.importedAt)")
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

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            if let fileName = character.avatarFileName,
               let url = CharacterImageURL.makeURL(avatarFileName: fileName) {
                CachedAvatarView(url: url) { avatarFallback(character.name, size: 64) }
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                avatarFallback(character.name, size: 64)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(character.name)
                    .font(.title2.weight(.semibold))
                if !character.tagline.isEmpty {
                    Text(character.tagline)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                Text(character.origin + " · " + character.sourcePlatform)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    if let count = character.interactionCount {
                        Label(count.formatted(), systemImage: "bubble.left")
                    }
                    if let visibility = character.visibility {
                        Text(visibility.replacingOccurrences(of: "VISIBILITY_", with: "").lowercased().capitalized)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Start chat", systemImage: "bubble.left.and.bubble.right", action: onStartChat)
                .buttonStyle(.borderedProminent)
        }
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
