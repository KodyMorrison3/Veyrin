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
    @StateObject private var connection = ProviderConnection()
    @State private var endpoint = ""
    @State private var model = ""
    @State private var error: String?
    @State private var localOnlyConfirmed = false

    var body: some View {
        Form {
            Section {
                Text("Ollama").font(.title2.weight(.semibold))
                Text("Connect to the Ollama server on this Mac. No Character.AI sign-in is needed.")
                    .foregroundStyle(.secondary)
                TextField("Endpoint", text: $endpoint)
                    .onChange(of: endpoint) { connection.reset(); model = ""; localOnlyConfirmed = false }
                HStack {
                    Button("Test Connection / Refresh Models") { test() }.disabled(connection.isLoading)
                    if connection.isLoading {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { connection.cancel() }
                    }
                }
                if let status = connection.status { Label(status, systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                if !connection.models.isEmpty {
                    Picker("Installed model", selection: $model) {
                        Text("Choose a model").tag("")
                        ForEach(connection.models) { Text($0.name).tag($0.id) }
                    }
                }
                if let error = error ?? connection.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
            Section("Setup") {
                Text("Install Ollama, open it (or run ‘ollama serve’), then install a model using Ollama. Refresh here once it is ready. Veyrin does not download models.")
                if let guide = URL(string: "https://docs.ollama.com/quickstart") {
                    Link("Ollama installation and model guide", destination: guide)
                }
                Text("Only loopback endpoints are allowed. Testing connects to the address above; it does not automatically launch or install anything.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Ollama can also route requests to cloud models, even through a local address. For local-only chat, disable cloud features in Ollama (OLLAMA_NO_CLOUD=1, then restart Ollama) and use a downloaded model. Veyrin cannot verify the server’s cloud setting.")
                    .font(.caption).foregroundStyle(.secondary)
                if onStart != nil {
                    Toggle("I’m using a downloaded model with Ollama cloud features disabled.", isOn: $localOnlyConfirmed)
                }
            }
            HStack {
                Button(onStart == nil ? "Save Settings" : "Start Local Chat") {
                    do {
                        guard connection.models.contains(where: { $0.id == model }) else { throw ProviderError.missingModel }
                        let provider = try TextChatProvider(localEndpoint: endpoint)
                        try store.saveLocal(endpoint: endpoint, model: model)
                        onStart?(provider, ProviderSelection(kind: .ollama, model: model))
                        error = nil
                    } catch { self.error = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent)
                .disabled(connection.isLoading || model.isEmpty || (onStart != nil && !localOnlyConfirmed))
            }
        }
        .formStyle(.grouped)
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
}

struct CloudProviderSetupView: View {
    @ObservedObject var store: ProviderStore
    var onStart: ((any ChatProvider, ProviderSelection) -> Void)?
    @State private var editing: ProviderConfiguration?
    @State private var removing: ProviderConfiguration?
    @State private var selectedID: UUID?
    @State private var model = ""
    @State private var error: String?
    @StateObject private var connection = ProviderConnection()

    var body: some View {
        Form {
            Section {
                Text("Cloud Providers").font(.title2.weight(.semibold))
                Text("Your prompts are sent to the selected provider. Use your own API key; API usage may be billed separately from a chat subscription.")
                    .foregroundStyle(.secondary)
                Button("Add Provider…", systemImage: "plus") {
                    editing = ProviderConfiguration(name: "OpenAI", kind: .openAI, endpoint: ProviderEndpoint.defaultOpenAI)
                }
                if let error = store.errorMessage { Text(error).foregroundStyle(.red) }
                if store.configurations.isEmpty {
                    Text("No cloud providers configured. Add OpenAI or a service that explicitly documents Chat Completions compatibility.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.configurations) { configuration in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(configuration.name).font(.headline)
                            Text(configuration.kind.title).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Select") {
                            connection.reset()
                            selectedID = configuration.id
                            model = configuration.model
                            error = nil
                        }
                        Button("Edit") { editing = configuration }
                        Button("Remove", role: .destructive) { removing = configuration }
                    }
                }
            }
            if let configuration = store.configurations.first(where: { $0.id == selectedID }) {
                Section(configuration.name) {
                    Text(configuration.endpoint).font(.caption).textSelection(.enabled)
                    Button("Test Connection / Refresh Models") {
                        connection.test { try TextChatProvider(configuration: configuration, apiKey: store.key(for: configuration.id)) }
                    }
                    .disabled(connection.isLoading)
                    if connection.isLoading {
                        HStack { ProgressView().controlSize(.small); Button("Cancel") { connection.cancel() } }
                    }
                    if let status = connection.status { Text(status).foregroundStyle(.secondary) }
                    if !connection.models.isEmpty {
                        Picker("Available models", selection: $model) {
                            Text("Choose a model").tag("")
                            ForEach(connection.models) { Text($0.name).tag($0.id) }
                        }
                    }
                    TextField("Model ID", text: $model)
                    Text("A successful model-list request tests the connection and key, not chat access. Some listed models do not support Chat Completions. You can enter a documented text-chat model ID if discovery is unsupported.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(onStart == nil ? "Save Model" : "Start Cloud Chat") {
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
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isEmpty || connection.isLoading)
                }
            }
            if let error = error ?? connection.error { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
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
            Text("Configure Cloud Provider").font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $configuration.name)
                Picker("API type", selection: $configuration.kind) {
                    Text("OpenAI").tag(ProviderKind.openAI)
                    Text("OpenAI-compatible Chat Completions").tag(ProviderKind.openAICompatible)
                }
                TextField("API base URL", text: $configuration.endpoint)
                    .disabled(configuration.kind == .openAI)
                SecureField("API key (leave blank to keep existing)", text: $apiKey)
                TextField("Model ID (optional until starting chat)", text: $configuration.model)
            }
            Text("Keys are stored in macOS Keychain, not preferences. Changing the endpoint requires re-entering the key. Compatibility is limited to text Chat Completions and model listing, not tools, images or every provider API.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("I trust this endpoint to receive my API key and messages.", isOn: $consent)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel", action: onDismiss).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    do {
                        try store.save(configuration, newKey: apiKey.isEmpty ? nil : apiKey)
                        apiKey = ""
                        onDismiss()
                    } catch { self.error = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!consent)
            }
        }
        .padding(24)
        .frame(width: 540)
        .onChange(of: configuration.kind) {
            if configuration.kind == .openAI { configuration.endpoint = ProviderEndpoint.defaultOpenAI }
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
                LocalProviderSetupView(store: store).tabItem { Label("Local Models", systemImage: "desktopcomputer") }
                CloudProviderSetupView(store: store).tabItem { Label("Cloud Providers", systemImage: "cloud") }
            }
        }
    }
}
