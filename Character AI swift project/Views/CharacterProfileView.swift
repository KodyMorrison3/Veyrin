import SwiftUI

struct CharacterProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var preferences = AppPreferences.shared
    @StateObject private var viewModel: CharacterViewModel

    let characterID: String
    let onStartConversation: (CharacterProfile) async -> Bool
    let onSelectSimilarCharacter: (String) -> Void
    let onBack: (() -> Void)?

    @State private var traceTag = String(UUID().uuidString.prefix(6))
    @State private var isStartingConversation = false
    @State private var startConversationError: String?

    init(
        characterID: String,
        authStore: AuthStore,
        onStartConversation: @escaping (CharacterProfile) async -> Bool,
        onSelectSimilarCharacter: @escaping (String) -> Void,
        onBack: (() -> Void)? = nil
    ) {
        self.characterID = characterID
        self.onStartConversation = onStartConversation
        self.onSelectSimilarCharacter = onSelectSimilarCharacter
        self.onBack = onBack
        _viewModel = StateObject(wrappedValue: CharacterViewModel(authStore: authStore))
    }

    var body: some View {
        Group {
            switch viewModel.profileState {
            case .idle, .loading:
                ProgressView("Loading character…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Unable to Load Profile", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") {
                        Task { await viewModel.load(externalID: characterID) }
                    }
                }
            case .loaded(let profile):
                profileContent(profile)
            }
        }
        .frame(minWidth: 460, minHeight: 520)
        .background { ShellEnvironmentalBackground() }
        .presentationBackground(.regularMaterial)
        .safeAreaInset(edge: .top) {
            if let onBack {
                HStack {
                    Button(action: onBack) {
                        Label("Back", systemImage: "chevron.backward")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(.bar)
                .onAppear { ProfileNavigationTrace.log("backBar appear id=\(characterID) tag=\(traceTag)") }
            }
        }
        .onAppear { ProfileNavigationTrace.log("view appear id=\(characterID) tag=\(traceTag)") }
        .onDisappear { ProfileNavigationTrace.log("view disappear id=\(characterID) tag=\(traceTag)") }
        .onChange(of: traceBranch) { _, branch in
            ProfileNavigationTrace.log("branch=\(branch) id=\(characterID) tag=\(traceTag)")
        }
        .task(id: characterID) {
            ProfileNavigationTrace.log("task start id=\(characterID) tag=\(traceTag)")
            await viewModel.load(externalID: characterID)
            ProfileNavigationTrace.log("task end id=\(characterID) tag=\(traceTag) cancelled=\(Task.isCancelled)")
        }
    }

    private var traceBranch: String {
        switch viewModel.profileState {
        case .idle: "idle"
        case .loading: "loading"
        case .failed: "failed"
        case .loaded(let profile): "loaded:\(profile.externalID)"
        }
    }

    private func profileContent(_ profile: CharacterProfile) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(profile)

                if let description = nonempty(profile.description) {
                    section("About") {
                        Text(description)
                            .textSelection(.enabled)
                    }
                }

                if let greeting = nonempty(profile.greeting) {
                    section("Greeting") {
                        Text(greeting)
                            .textSelection(.enabled)
                    }
                }

                if let greetings = profile.additionalGreetings,
                   !greetings.filter({ !$0.isEmpty }).isEmpty {
                    section("More greetings") {
                        ForEach(Array(greetings.enumerated()), id: \.offset) { _, greeting in
                            if !greeting.isEmpty {
                                Text(greeting)
                                    .padding(.vertical, 4)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

                if let prompts = profile.starterPrompts {
                    let prompts = prompts.filter { nonempty($0) != nil }
                    if !prompts.isEmpty {
                        section("Start with a prompt") {
                            ForEach(Array(prompts.enumerated()), id: \.offset) { _, prompt in
                                Label(prompt, systemImage: "quote.bubble")
                                    .font(.body)
                            }
                        }
                    }
                }

                switch viewModel.similarState {
                case .loading, .idle:
                    ProgressView("Loading similar characters…")
                case .failed(let message):
                    Text("Similar characters unavailable: \(message)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .loaded(let characters):
                    if characters.isEmpty {
                        Text("No similar characters found.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        section("Similar characters") {
                            ForEach(Array(characters.enumerated()), id: \.offset) { _, similar in
                                similarCharacterRow(similar)
                            }
                        }
                    }
                }

                Button {
                    Task {
                        startConversationError = nil
                        isStartingConversation = true
                        let started = await onStartConversation(profile)
                        isStartingConversation = false
                        guard started else {
                            startConversationError = "Unable to start conversation. Please try again."
                            return
                        }
                        dismiss()
                    }
                } label: {
                    if isStartingConversation {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Start Conversation", systemImage: "bubble.left.and.bubble.right")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isStartingConversation)

                if let startConversationError {
                    Label(startConversationError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { ProfileNavigationTrace.log("content appear id=\(profile.externalID) tag=\(traceTag)") }
    }

    private func header(_ profile: CharacterProfile) -> some View {
        HStack(alignment: .top, spacing: 16) {
            avatar(for: profile, size: 64)
            VStack(alignment: .leading, spacing: 6) {
                Text(profile.name ?? profile.title ?? "Character")
                    .font(.title2.weight(.semibold))
                if let title = nonempty(profile.title), title != profile.name {
                    Text(title)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    if let count = profile.interactionCount {
                        Label(count.formatted(), systemImage: "bubble.left")
                    }
                    if let upvotes = profile.upvotes {
                        Label(upvotes.formatted(), systemImage: "hand.thumbsup")
                    }
                    if let visibility = nonempty(profile.visibility) {
                        Text(visibility.replacingOccurrences(of: "VISIBILITY_", with: "").lowercased().capitalized)
                    }
                    if let commentsEnabled = profile.commentsEnabled {
                        Label(commentsEnabled ? "Comments on" : "Comments off", systemImage: "text.bubble")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func avatar(for profile: CharacterProfile, size: CGFloat) -> some View {
        avatar(fileName: profile.avatarFileName, name: profile.name ?? profile.title, size: size)
    }

    @ViewBuilder
    private func avatar(fileName: String?, name: String?, size: CGFloat) -> some View {
        if let fileName = nonempty(fileName),
           let url = CharacterImageURL.makeURL(avatarFileName: fileName) {
            CachedAvatarView(url: url) {
                    avatarFallback(name: name, size: size)
                }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            avatarFallback(name: name, size: size)
        }
    }

    private func avatarFallback(name: String?, size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(preferences.environmentalPalette.glassSurfaceTint)
            Text(String((name ?? "?").prefix(1)).uppercased())
                .font(.system(size: size * 0.4, weight: .semibold))
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func similarCharacterRow(_ similar: SimilarCharacter) -> some View {
        let content = HStack(spacing: 10) {
            avatar(fileName: similar.avatarFileName, name: similar.name ?? similar.title, size: 38)
            VStack(alignment: .leading) {
                Text(similar.name ?? similar.title ?? "Character")
                    .font(.headline)
                if let title = nonempty(similar.title), title != similar.name {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                }
                if let description = nonempty(similar.description) {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        // Without an external ID there is nothing to open, so the row stays static.
        if let externalID = similar.profileID {
            Button {
                onSelectSimilarCharacter(externalID)
            } label: {
                content
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .pointerStyle(.link)
        } else {
            content
        }
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}
