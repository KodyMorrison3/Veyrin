# Veyrin providers

Implemented and checked locally on 23 October 2026. This is an incremental addition to the existing native app, not a replacement for Character.AI's chat stack. No new package dependency, embedded inference runtime or Metal code was added.

## Launch and navigation

The provider chooser is the root of each existing SwiftUI `WindowGroup` window. It is not a separate modal window that can be dismissed over an empty chat. Closing it closes that window normally; creating another application window presents a usable root again.

By default, every new window starts with **Character.AI**, **Local Models** and **Cloud Providers**. The chooser has Settings access and Command-1/2/3 shortcuts. **Switch Provider** is available from Character.AI and text chat; setup screens have a Providers back button.

**Remember my last provider** is off by default. When enabled:

- Character.AI enters the existing authentication gate. A saved token must still pass `AuthStore`/`SessionValidator` validation before the account UI appears.
- Local/cloud text selection remembers its provider kind, configuration ID where applicable and model ID. Launch requests the model list and verifies that the selected model is still listed before opening chat.
- A failed connection, missing key/configuration or removed model returns to the chooser with an error. Choose the category again to retry or change settings. An obsolete reconnect cannot override a newer manual selection.
- Cloud endpoints without model discovery can still be used by entering a documented model ID manually, but automatic launch restoration cannot verify them. Use the chooser in that case.

Turning the preference off removes the remembered selection, not provider configurations, API keys or the Character.AI session. Changing it while already in chat affects subsequent selections/launches; it does not move the current window.

Character.AI sign-in continues straight into its existing interface. Selecting it again while the session is valid does not require another login. Logout/current-session rejection returns a window displaying Character.AI to the chooser. A late Character.AI auth change does not take over a local/cloud chat.

## Setup

### Character.AI

Use the existing session-token sign-in flow. Session validation, Keychain persistence, account IDs, generation-guarded invalidation, history, characters, personas, candidates, pins, images and WebSocket routing remain in their existing implementation. No generic chat endpoint stands in for Character.AI.

### Ollama

1. Install and run Ollama using its [quickstart](https://docs.ollama.com/quickstart). Install a model yourself using Ollama; Veyrin never chooses or downloads one for you.
2. For local-only inference, disable Ollama cloud features and restart Ollama. The [official FAQ](https://docs.ollama.com/faq) documents `OLLAMA_NO_CLOUD=1` or `disable_ollama_cloud: true` in Ollama's server configuration. Veyrin does not modify these settings for you. The environment variable must reach the actual Ollama process; exporting it in an unrelated terminal does not configure an already-running Mac app.
3. Choose **Local Models**, then **Test Connection / Refresh Models**. The default endpoint is `http://127.0.0.1:11434`. Only HTTP/HTTPS loopback endpoints (`localhost`, `127.0.0.1`, `::1`) without paths, credentials, queries or fragments are accepted.
4. Choose an installed model, confirm downloaded-model/local-only setup and start chat. The same endpoint and model can be saved from **Settings → Providers → Local Models**.

A reachable server with no models is shown separately from a failed connection. Discovery uses [`GET /api/tags`](https://docs.ollama.com/api/tags). Generation uses [`POST /api/chat`](https://docs.ollama.com/api/chat) with `stream: true`; NDJSON content is accumulated until `done: true`. There is no polling loop. Stop, leaving chat and switching providers cancel the owning URLSession task. This closes the HTTP request; Veyrin does not claim to forcibly unload the server's model or guarantee remote compute stops immediately.

**A loopback endpoint is not proof that inference is local.** [Ollama also supports cloud models](https://docs.ollama.com/cloud), including access through its local service. Veyrin cannot attest to a separately configured server's routing or cloud-disabled setting. The UI requires confirmation before starting from setup and remembers the selected model only when the user opts into remembered-provider restoration. Keep Ollama configured local-only when using that option. The existing saved-character library has the same server trust boundary.

The new provider chooser never starts Ollama automatically. The older saved-character library retains its separate automatic-start preference and disk-backed, non-streaming chat path. It now uses the configured endpoint, handles invalid endpoints without a force-try crash and cancels generation when leaving that view. No Metal Toolchain is needed to send HTTP requests; Ollama owns inference.

### Cloud providers

1. Choose **Cloud Providers → Add Provider…**, or open **Settings → Providers → Cloud Providers**.
2. Choose **OpenAI** for the fixed `https://api.openai.com/v1` base URL, or **OpenAI-compatible Chat Completions** only when the chosen service explicitly documents that API and Bearer authentication.
3. Supply your own API key in the secure field and confirm that you trust the endpoint. Saving does not make a network request or imply the key works. API billing may be separate from a chat subscription.
4. Select the saved configuration and test it. Model-list success means the endpoint and credential accepted that request; it does not prove generation access or Chat Completions compatibility for every returned model.
5. Select a listed text-chat model or enter a documented model ID. Start chat to send the first message deliberately. Edit and remove controls are on the same management screen. Removing a configuration also removes its Keychain item after confirmation.

The real adapter implements [OpenAI model listing](https://developers.openai.com/api/reference/resources/models/methods/list) and [streamed Chat Completions chunks](https://developers.openai.com/api/reference/resources/chat/subresources/completions/streaming-events/). It sends `model`, role/content `messages` and `stream: true`, accepts SSE text deltas and requires the terminal `[DONE]` event. Native OpenAI and compatible endpoints share this limited wire adapter, not a claim of universal API compatibility.

It does not implement the Responses API, image/audio input, tools/function execution, provider-specific reasoning controls, arbitrary auth schemes or non-streaming fallbacks. Tool/refusal/unsupported-format responses produce an error rather than a fake successful reply. Some model-list entries are not text-chat models. Select one documented for Chat Completions; Veyrin does not hardcode a model that an account may not have.

## Architecture and concurrency

| Responsibility | Source |
|---|---|
| Kinds, descriptors, capabilities, configuration, model/message/role/event types, endpoint rules and safe errors | [ChatProvider.swift](Character%20AI%20swift%20project/Models/ChatProvider.swift) |
| Non-secret configuration/preferences and separate credential lookup | [ProviderStore.swift](Character%20AI%20swift%20project/Services/ProviderStore.swift) |
| Cancellable ephemeral URLSession transport and bounded data collection | [ProviderHTTPTransport.swift](Character%20AI%20swift%20project/Networking/ProviderHTTPTransport.swift) |
| Ollama/OpenAI request contracts and actor-owned NDJSON/SSE parser | [TextChatProvider.swift](Character%20AI%20swift%20project/Services/TextChatProvider.swift) |
| Generation state, partial text, retry, switching and remembered launch | [ProviderChatViewModel.swift](Character%20AI%20swift%20project/ViewModels/ProviderChatViewModel.swift) |
| Native selection/setup/editor/settings UI and cancellable discovery controller | [ProviderSelectionView.swift](Character%20AI%20swift%20project/Views/ProviderSelectionView.swift) |
| Text chat using existing formatting, glass surfaces and layout metrics | [ProviderChatView.swift](Character%20AI%20swift%20project/Views/ProviderChatView.swift) |
| Existing root/authentication routing and Settings integration | [ContentView.swift](Character%20AI%20swift%20project/Views/ContentView.swift), [SettingsView.swift](Character%20AI%20swift%20project/Views/SettingsView.swift) |

`ChatProvider` is a Sendable text-chat contract: descriptor/capabilities, asynchronous model discovery and an async streamed-event callback. Cancellation follows the owning Swift Task; no second provider-global cancellation registry is needed. A different API can add its own conformer rather than teach SwiftUI how to parse that API. New credential/configuration kinds must also be wired into store validation and setup intentionally.

Character.AI is represented by its descriptor and explicit character/account-history capabilities but deliberately does **not** implement ordinary completion-style message sending. Its `ChatView`, `ChatViewModel`, `ConversationService`, `TurnState`, authenticated HTTP client and WebSocket router remain the boundary for those features. This avoids an all-at-once migration of turns, candidates, attachments or account features. Local/cloud chat reuses `CharacterMessageFormattingView` and the existing native visual primitives rather than duplicating Markdown parsing. It does not present Character.AI-only controls.

Stores, navigation, view models and UI publication remain MainActor-isolated. Adapter value types/DTOs are nonisolated and Sendable. Discovery decoding and request encoding cross explicit `@concurrent` boundaries. URLSession delegate I/O and parser actors do not perform expensive stream parsing on the main actor. UI text publication is coalesced at 40 ms with an immediate finish/cancel flush, matching the existing approach. Revisions protect discovery, launch restoration and generation from cancelled/late results.

Framing happens on bytes before UTF-8 decoding, including CRLF and split Unicode. SSE comments are ignored and multiple data lines join into one event. Unexpected EOF is an interrupted response, not silent success. Retry explicitly replaces the previous partial assistant response without duplicating the user's prompt; a retry may incur another API charge. No automatic generation retry was added.

Bounds: model-list bodies 8 MiB; a stream 4 MiB; individual lines/events 256 KiB; transport queue 64 chunks of at most 16 KiB. Buffer overflow fails instead of silently dropping text. Requests allow at most 200 messages and 2 MiB of message text. Existing transcripts stay visible when that request limit is hit; start a new chat to continue. These are application safeguards, not model context/token guarantees or a measured performance improvement.

## Credentials and conversation data

- `ProviderStore` reuses the existing `SessionStorage` boundary with production `KeychainStore`. Cloud secrets have `cloud-provider.<UUID>` item names, separate from Character.AI's `authSession`.
- UserDefaults stores only the remember toggle, local endpoint/model, cloud configuration metadata and optional last selection. API keys are never part of encoded `ProviderConfiguration`.
- An edited endpoint/API kind requires a newly entered key. The editor resets trust consent when the destination changes. Existing keys are never prefilled or displayed.
- Local/cloud transport refuses redirects, uses ephemeral sessions with no persistent cache/cookie/credential store, and maps errors to fixed safe text without echoing server bodies, prompts, headers or keys. It adds no conversation logging.
- Cloud URLs require HTTPS and reject embedded credentials/query/fragment, literal IP endpoints and local/internal suffixes. This is input validation, **not** a DNS-rebinding firewall or proof of a service's identity. Custom endpoints are user-trusted destinations; DNS may resolve differently later. A successful TLS connection/model list is not a privacy certification.
- Corrupt cloud configuration data is reported and not silently overwritten. Keychain failures remain errors rather than falling back to plaintext.
- New local/cloud transcripts are in-memory only. New Chat, switching away or closing the window discards them. No messages move from Character.AI/local chat to cloud, or between configured cloud providers automatically.
- Existing saved-character catalogue/conversations remain in their separate unencrypted Application Support files; Character.AI's existing account caches/history handling are unchanged. See [README security notes](README.md#security-and-privacy).

## Verification

Environment: Apple Silicon macOS, Xcode 27, macOS 27 SDK, Swift 6.4 compiler in the project's Swift 5 language mode, complete concurrency checking and MainActor default isolation. Baseline Debug and final Debug/Release builds succeeded with signing disabled. Final Swift build output had no compiler/concurrency warnings; Xcode reported only skipped AppIntents metadata extraction because the app does not use AppIntents.

Executed successfully against the final Swift sources:

```bash
xcodebuild -project 'Character AI swift project.xcodeproj' \
  -scheme 'Character AI swift project' -configuration Debug \
  -sdk macosx -destination 'generic/platform=macOS' \
  -derivedDataPath build/ProviderDerivedData \
  CODE_SIGNING_ALLOWED=NO SWIFT_STRICT_CONCURRENCY=complete build
# Repeated with -configuration Release.

VEYRIN_DERIVED_DATA=build/ProviderDerivedData bash Verification/run-checks.sh
VEYRIN_DERIVED_DATA=build/ProviderDerivedData bash Verification/auth/run-auth-checks.sh
VEYRIN_DERIVED_DATA=build/ProviderDerivedData bash Verification/decode-diagnostics/run-decode-diagnostics-checks.sh
VEYRIN_DERIVED_DATA=build/ProviderDerivedData bash Verification/model-default/run-model-default-checks.sh
VEYRIN_DERIVED_DATA=build/ProviderDerivedData bash Verification/run-profile-navigation-checks.sh
bash PerformanceChecks/run-checks.sh
git diff --check
```

Build/suite logs and captured exit statuses are in ignored `.build/provider-work/`. No XCTest target was introduced; the new [ProviderChecks.swift](Verification/ProviderChecks.swift) runs through the existing [verification entry point](Verification/ReliabilityChecks.swift).

Provider checks use URLProtocol and synthetic in-memory credential/preferences fixtures, not real accounts or live services. They exercise:

- Default launch; remembering enabled/disabled; reload persistence; Character.AI routing after sign-in/logout; missing and server-accepted/rejected stored sessions using the existing validator.
- Loopback/cloud URL validation, model/key validation, endpoint edits requiring new credentials, separate secret storage, retained credentials when remembering is disabled, removal, storage failures and corrupt configuration preservation.
- Ollama unavailable/empty/model discovery; cloud model discovery and Authorization destination; HTTP 401/403/404/429/500 and redirects rejected as errors without server error text.
- Actual streamed request paths/methods/role-content bodies; NDJSON/SSE text through the production HTTP transport; byte-by-byte Unicode/CRLF framing, missing terminators, server/malformed/tool/empty-response errors and line limits.
- Owning HTTP task cancellation during model discovery and generation; partial-text flush; retry without duplicated user messages; switching during generation with a deliberately cancellation-ignoring producer; successful/failed/missing-model launch restoration and stale discovery/reconnect rejection.
- Capabilities distinguishing ordinary text from Character.AI features; actual native chooser/setup/chat view instantiation in light/dark appearance at 600×560 and 1100×800. These are layout smoke checks, not visual approval or complete interactive navigation tests.

Existing auth checks passed all 19 scenarios. Existing conversation, filtered-response, HTTP, images/rendering, decode diagnostics, model default, profile navigation and performance regression suites also passed. The feed-without-participants regression visible in the earlier error report remains covered by the existing rendering checks.

Failed intermediate attempts were repaired and rerun: two new assertions initially put throwing calls inside `precondition` autoclosures; one decode-check compile overlapped a source edit and was restarted after edits stopped; the held-open URLProtocol stream fixture needed an explicit NDJSON Content-Type to deliver incremental data on this Foundation version. The production parser/cancellation assertions were retained, not weakened.

### Still needs live/manual verification

No live Ollama generation, cloud key, paid request or authenticated Character.AI conversation was used in this work. No production Keychain item was read/written by the provider tests. Mock validation proves the implemented contract, not current service compatibility or real credential accessibility/signing behavior.

Before treating this as release-ready, test the signed sandboxed app's full keyboard/focus/hover experience, VoiceOver, window close/reopen and multiple windows; actual Keychain save/update/remove; a downloaded Ollama model (including cloud-disabled setup, no-model and stopped-server cases); one real cloud text model; and Character.AI restore/login/logout/switching with real account history and generation. Verify cancellation against those actual services and check normal scrolling with long streamed replies. No speed, energy or GPU improvement is claimed.

The Xcode project already had unrelated signing/serialization changes in the working checkout during continuation; those were left untouched. No commit, push, packaging, notarisation or release was performed.
