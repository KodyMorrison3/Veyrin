import Combine
import SwiftUI

struct ProviderSelectionView: View {
    @ObservedObject var coordinator: ProviderCoordinator
    @ObservedObject var store: ProviderStore
    @ObservedObject var authStore: AuthStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .foregroundStyle(.tint)
                    Text("Veyrin").font(.title2.weight(.semibold))
                    Spacer()
                    SettingsLink { Label("Settings", systemImage: "gearshape") }
                        .labelStyle(.iconOnly)
                        .help("Open Veyrin settings")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Choose your provider").font(.largeTitle.weight(.semibold))
                    Text("Choose where your AI conversations run.")
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 10) {
                    ProviderChoiceRow(title: "Character.AI", symbol: "bubble.left.and.bubble.right",
                                      description: "Continue your conversations with your Character.AI account.",
                                      status: authStore.isRestoringSession ? "Checking saved session…" : authStore.isAuthenticated ? "Signed in · Ready" : "Sign in required") {
                        coordinator.show(.characterAI)
                    }
                    .keyboardShortcut("1", modifiers: .command)
                    ProviderChoiceRow(title: "Local Models", symbol: "desktopcomputer",
                                      description: "Run conversations with models hosted locally on your Mac.",
                                      status: "Ollama · Choose an installed model") { coordinator.show(.local) }
                        .keyboardShortcut("2", modifiers: .command)
                    ProviderChoiceRow(title: "Cloud Providers", symbol: "cloud",
                                      description: "Connect cloud AI services and choose from their available models.",
                                      status: store.configurations.isEmpty ? "Configuration required" : "\(store.configurations.count) configured") {
                        coordinator.show(.cloud)
                    }
                    .keyboardShortcut("3", modifiers: .command)
                }
                if coordinator.isRestoring {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Connecting to your last provider…").font(.callout)
                        Button("Cancel") { coordinator.show(.selector) }
                    }
                }
                if let error = coordinator.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                Toggle("Remember my last provider", isOn: $store.rememberLastProvider)
                Text("Off by default: show this chooser at launch. When enabled, reconnect to the last successfully selected provider and model. This does not change your saved sign-in or API keys.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .background { ShellEnvironmentalBackground(vignetteStrength: 0.4).ignoresSafeArea() }
        .frame(minWidth: 560, minHeight: 560)
        .navigationTitle("Veyrin")
    }
}

private struct ProviderChoiceRow: View {
    let title: String
    let symbol: String
    let description: String
    let status: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: symbol).font(.title2).frame(width: 30).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.headline)
                    Text(description).font(.callout).foregroundStyle(.secondary)
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(18)
            .background(.primary.opacity(hovering ? 0.07 : 0.025), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(hovering ? 0.18 : 0.1)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovering)
        .accessibilityElement(children: .combine)
    }
}

/// This controller owns discovery, not the view. Revision checks cover both
/// task cancellation and providers that deliver a result after cancellation.
@MainActor
final class ProviderConnection: ObservableObject {
    @Published private(set) var models: [ModelDescriptor] = []
    @Published private(set) var isLoading = false
    @Published private(set) var status: String?
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?
    private var revision = UUID()

    func reset() {
        cancel()
        models = []
        status = nil
        error = nil
    }

    func test(_ makeProvider: () throws -> any ChatProvider) {
        reset()
        do {
            let provider = try makeProvider()
            isLoading = true
            let revision = revision
            task = Task { [weak self] in
                do {
                    let models = try await provider.models()
                    try Task.checkCancellation()
                    guard let self, self.revision == revision else { return }
                    self.models = models
                    self.status = models.isEmpty ? "Connected · No models available" : "Connected · \(models.count) models available"
                    self.isLoading = false
                } catch is CancellationError { }
                catch {
                    guard let self, self.revision == revision else { return }
                    self.error = (error as? ProviderError ?? .unavailable).localizedDescription
                    self.isLoading = false
                }
            }
        } catch { self.error = (error as? ProviderError ?? .invalidConfiguration).localizedDescription }
    }

    func cancel() {
        revision = UUID()
        task?.cancel()
        task = nil
        isLoading = false
    }
}

struct LocalProviderSetupView: View {
    @ObservedObject var store: ProviderStore
    var onStart: ((any ChatProvider, ProviderSelection) -> Void)?
    var embedded = false
    @StateObject private var connection = ProviderConnection()
    @State private var endpoint = ""
    @State private var model = ""
    @State private var error: String?
    @State private var localOnlyConfirmed = false

    var body: some View {
        ProviderSetupChrome(
            embedded: embedded,
            symbol: "desktopcomputer",
            title: "Ollama",
            subtitle: "Connect to the Ollama server on this Mac. No Character.AI sign-in is needed."
        ) {
            ProviderCard {
                ProviderFieldLabel("Endpoint")
                TextField("http://127.0.0.1:11434", text: $endpoint)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .accessibilityLabel("Endpoint")
                    .onChange(of: endpoint) { connection.reset(); model = ""; localOnlyConfirmed = false }
                HStack(spacing: 10) {
                    Button("Test Connection / Refresh Models") { test() }
                        .disabled(connection.isLoading)
                    if connection.isLoading {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { connection.cancel() }
                    }
                }
                if let status = connection.status {
                    Label(status, systemImage: "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if !connection.models.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ProviderFieldLabel("Installed model")
                        Picker("Installed model", selection: $model) {
                            Text("Choose a model").tag("")
                            ForEach(connection.models) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 320, alignment: .leading)
                    }
                }
                if let error = error ?? connection.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ProviderCard(title: "Setup") {
                Text("Install Ollama, open it (or run ‘ollama serve’), then install a model using Ollama. Refresh here once it is ready. Veyrin does not download models.")
                    .fixedSize(horizontal: false, vertical: true)
                if let guide = URL(string: "https://docs.ollama.com/quickstart") {
                    Link("Ollama installation and model guide", destination: guide)
                }
                Divider()
                Text("Only loopback endpoints are allowed. Testing connects to the address above; it does not automatically launch or install anything.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Ollama can also route requests to cloud models, even through a local address. For local-only chat, disable cloud features in Ollama (OLLAMA_NO_CLOUD=1, then restart Ollama) and use a downloaded model. Veyrin cannot verify the server’s cloud setting.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if onStart != nil {
                    Divider()
                    Toggle("I’m using a downloaded model with Ollama cloud features disabled.", isOn: $localOnlyConfirmed)
                        .toggleStyle(.switch)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ProviderPrimaryButton(
                title: onStart == nil ? "Save Settings" : "Start Local Chat",
                isEnabled: !connection.isLoading && !model.isEmpty && (onStart == nil || localOnlyConfirmed)
            ) {
                start()
            }
        }
        .navigationTitle("Local Models")
        .onAppear { endpoint = store.localEndpoint; model = store.localModel }
        .onChange(of: connection.models) {
            if !connection.models.contains(where: { $0.id == model }) {
                model = endpoint == store.localEndpoint && connection.models.contains(where: { $0.id == store.localModel })
                    ? store.localModel : connection.models.first?.id ?? ""
            }
        }
        .onDisappear { connection.cancel() }
    }

    private func test() {
        error = nil
        connection.test { try TextChatProvider(localEndpoint: endpoint) }
    }

    private func start() {
        do {
            guard connection.models.contains(where: { $0.id == model }) else { throw ProviderError.missingModel }
            let provider = try TextChatProvider(localEndpoint: endpoint)
            try store.saveLocal(endpoint: endpoint, model: model)
            onStart?(provider, ProviderSelection(kind: .ollama, model: model))
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct CloudProviderSetupView: View {
    @ObservedObject var store: ProviderStore
    var onStart: ((any ChatProvider, ProviderSelection) -> Void)?
    var embedded = false
    @State private var editing: ProviderConfiguration?
    @State private var removing: ProviderConfiguration?
    @State private var selectedID: UUID?
    @State private var model = ""
    @State private var error: String?
    @StateObject private var connection = ProviderConnection()

    var body: some View {
        ProviderSetupChrome(
            embedded: embedded,
            symbol: "cloud",
            title: "Cloud Providers",
            subtitle: "Your prompts are sent to the selected provider. Use your own API key; API usage may be billed separately from a chat subscription."
        ) {
            ProviderCard {
                HStack {
                    Text("Configured providers").font(.headline)
                    Spacer()
                    Menu("Free Providers", systemImage: "sparkles") {
                        ForEach(ProviderPreset.freeCloud) { preset in
                            Button(preset.name) { editing = preset.configuration }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Button("Add Provider…", systemImage: "plus") {
                        editing = ProviderConfiguration(name: "OpenAI", kind: .openAI, endpoint: ProviderEndpoint.defaultOpenAI)
                    }
                }
                if let error = store.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if store.configurations.isEmpty {
                    Text("No cloud providers configured. Add Claude, OpenAI, or an OpenAI-compatible Chat Completions service.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(ProviderPreset.freeCloud) { preset in
                            Button {
                                editing = preset.configuration
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "sparkles")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 16)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(preset.name).font(.callout.weight(.medium))
                                        Text(preset.note).font(.caption).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 4)
                } else {
                    VStack(spacing: 0) {
                        ForEach(store.configurations) { configuration in
                            providerRow(configuration)
                            if configuration.id != store.configurations.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }

            if let configuration = store.configurations.first(where: { $0.id == selectedID }) {
                ProviderCard(title: configuration.name) {
                    Text(configuration.endpoint)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    HStack(spacing: 10) {
                        Button("Test Connection / Refresh Models") {
                            connection.test { try TextChatProvider(configuration: configuration, apiKey: store.key(for: configuration.id)) }
                        }
                        .disabled(connection.isLoading)
                        if connection.isLoading {
                            ProgressView().controlSize(.small)
                            Button("Cancel") { connection.cancel() }
                        }
                    }
                    if let status = connection.status {
                        Text(status).font(.callout).foregroundStyle(.secondary)
                    }
                    if !connection.models.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ProviderFieldLabel("Available models")
                            Picker("Available models", selection: $model) {
                                Text("Choose a model").tag("")
                                ForEach(connection.models) { Text($0.name).tag($0.id) }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 320, alignment: .leading)
                        }
                    }
                    ProviderFieldLabel("Model ID")
                    TextField("Model ID", text: $model)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Model ID")
                    Text("A successful model-list request tests the connection and key, not chat access. Some listed models do not support the selected API type. You can enter a documented text-chat model ID if discovery is unsupported.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let error = error ?? connection.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                ProviderPrimaryButton(
                    title: onStart == nil ? "Save Model" : "Start Cloud Chat",
                    isEnabled: !model.isEmpty && !connection.isLoading
                ) {
                    start(configuration)
                }
            }
        }
        .navigationTitle("Cloud Providers")
        .sheet(item: $editing) { configuration in
            CloudProviderEditor(store: store, configuration: configuration) {
                editing = nil
                connection.cancel()
            }
        }
        .confirmationDialog("Remove provider and its API key?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                guard let removing else { return }
                do {
                    try store.remove(removing.id)
                    if selectedID == removing.id { selectedID = nil; connection.cancel() }
                } catch { self.error = error.localizedDescription }
                self.removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        }
        .onDisappear { connection.cancel() }
        .onChange(of: store.configurations) { connection.reset() }
    }

    private func providerRow(_ configuration: ProviderConfiguration) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(configuration.name).font(.headline)
                Text(configuration.kind.title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if selectedID == configuration.id {
                Text("Selected").font(.caption).foregroundStyle(.secondary)
            }
            Button("Select") {
                connection.reset()
                selectedID = configuration.id
                model = configuration.model
                error = nil
            }
            .buttonStyle(.borderless)
            Button("Edit") { editing = configuration }
                .buttonStyle(.borderless)
            Button("Remove", role: .destructive) { removing = configuration }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background {
            if selectedID == configuration.id {
                EnvironmentalSelectionBackground(cornerRadius: 9)
            }
        }
    }

    private func start(_ configuration: ProviderConfiguration) {
        do {
            guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProviderError.missingModel }
            var updated = configuration
            updated.model = model
            try store.save(updated, newKey: nil)
            let provider = try TextChatProvider(configuration: updated, apiKey: store.key(for: updated.id))
            onStart?(provider, ProviderSelection(kind: updated.kind, configurationID: updated.id, model: model))
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

private struct CloudProviderEditor: View {
    @ObservedObject var store: ProviderStore
    @State var configuration: ProviderConfiguration
    let onDismiss: () -> Void
    @State private var apiKey = ""
    @State private var consent = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 11) {
                GlassIconTile(systemName: "cloud.fill")
                Text("Configure Cloud Provider").font(.title2.weight(.semibold))
            }
            ProviderCard {
                ProviderFieldLabel("Name")
                TextField("Name", text: $configuration.name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Name")
                ProviderFieldLabel("API type")
                Picker("API type", selection: $configuration.kind) {
                    Text("OpenAI · Chat Completions").tag(ProviderKind.openAI)
                    Text("OpenAI · Responses").tag(ProviderKind.openAIResponses)
                    Text("Claude · Anthropic Messages").tag(ProviderKind.anthropic)
                    Text("OpenAI-compatible Chat Completions").tag(ProviderKind.openAICompatible)
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                ProviderFieldLabel("API base URL")
                TextField("API base URL", text: $configuration.endpoint)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("API base URL")
                    .disabled(configuration.kind != .openAICompatible)
                if let preset = ProviderPreset.freeCloud.first(where: { $0.endpoint == configuration.endpoint }) {
                    Text(preset.note)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ProviderFieldLabel("API key", hint: "Leave blank to keep existing")
                SecureField("Leave blank to keep existing", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("API key")
                ProviderFieldLabel("Model ID", hint: "Optional until starting chat")
                TextField("Optional until starting chat", text: $configuration.model)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Model ID")
            }
            Text("Keys are stored in macOS Keychain, not preferences. Changing the endpoint requires re-entering the key. Choose the API type supported by your model. Claude uses Messages; Responses supports additional OpenAI text models. API keys are separate from ChatGPT/Codex subscriptions. Text only; no tools or images.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("I trust this endpoint to receive my API key and messages.", isOn: $consent)
                .toggleStyle(.switch)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button("Cancel", action: onDismiss).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    do {
                        try store.save(configuration, newKey: apiKey.isEmpty ? nil : apiKey)
                        apiKey = ""
                        onDismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .buttonStyle(GlassProminentButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!consent)
            }
        }
        .padding(28)
        .frame(width: 560)
        .background { ShellEnvironmentalBackground(vignetteStrength: 0.7) }
        .onChange(of: configuration.kind) {
            if configuration.kind == .anthropic {
                configuration.endpoint = ProviderEndpoint.defaultAnthropic
            } else if configuration.kind == .openAI || configuration.kind == .openAIResponses {
                configuration.endpoint = ProviderEndpoint.defaultOpenAI
            }
            configuration.model = ""
            consent = false
        }
        .onChange(of: configuration.endpoint) { consent = false }
        .onDisappear { apiKey = "" }
    }
}

struct ProviderSettingsView: View {
    @ObservedObject var store: ProviderStore
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Remember my last provider", isOn: $store.rememberLastProvider)
                Text("Reconnect at launch only when enabled. Disabling this never removes credentials. Switching provider starts a separate, in-memory conversation; no context is transferred.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(20)
            TabView {
                LocalProviderSetupView(store: store, embedded: true).tabItem { Label("Local Models", systemImage: "desktopcomputer") }
                CloudProviderSetupView(store: store, embedded: true).tabItem { Label("Cloud Providers", systemImage: "cloud") }
            }
        }
    }
}

// MARK: - Shared provider setup presentation

/// Mirrors the shell used by the main window, Character.AI sign-in and
/// Settings: environmental background, clear window backing and the shared
/// window-transparency preference. Embedded in Settings it contributes only
/// its content so the Settings shell remains the single background owner.
private struct ProviderSetupChrome<Content: View>: View {
    let embedded: Bool
    let symbol: String
    let title: String
    let subtitle: String
    let content: () -> Content

    @ObservedObject private var preferences = AppPreferences.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(
        embedded: Bool = false,
        symbol: String,
        title: String,
        subtitle: String,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.embedded = embedded
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        if embedded {
            scroll
        } else {
            scroll
                .background {
                    ShellEnvironmentalBackground(vignetteStrength: 0.6)
                        .ignoresSafeArea()
                }
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .containerBackground(.clear, for: .window)
                .background {
                    WindowTransparencyBridge(
                        transparency: preferences.windowTransparency,
                        reduceTransparency: reduceTransparency
                    )
                }
        }
    }

    private var scroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 11) {
                        GlassIconTile(systemName: symbol)
                        Text(title).font(.title2.weight(.semibold))
                    }
                    .accessibilityElement(children: .combine)

                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                content()
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }
}

private struct ProviderCard<Content: View>: View {
    let title: String?
    let content: () -> Content

    init(title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title).font(.headline)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .glassSurface(.sheet, cornerRadius: 16)
    }
}

private struct ProviderFieldLabel: View {
    let text: String
    let hint: String?

    init(_ text: String, hint: String? = nil) {
        self.text = text
        self.hint = hint
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(text).font(.subheadline.weight(.semibold))
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProviderPrimaryButton: View {
    let title: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(GlassProminentButtonStyle())
        .controlSize(.large)
        .disabled(!isEnabled)
    }
}
