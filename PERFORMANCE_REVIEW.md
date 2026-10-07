# Native macOS optimisation and reliability review

Baseline: `b042e97bb1efce726df44023dbeb0feaface9880` — `Optimise streaming, rendering, and image performance`.

## Scope and audit

Read all tracked Swift source files, app entry point, Xcode project/workspace configuration, README, ignore/attribute rules and asset metadata before editing. The binary icon was left untouched. The ignored local Docs/ContractTests/Tests contents were access-blocked and were not inspected through alternate tools. No architecture conversion, authentication bypass, endpoint invention, commit or push was performed.

The project uses Xcode 27 / Swift 6.4, Swift language mode 5, MainActor default isolation and approachable concurrency. Those settings remain unchanged.

### Isolation and data-flow map

- Authentication, request construction, services, view models, observable stores and SwiftUI publication remain MainActor-isolated.
- URLSession performs asynchronous network work. HTTP decoding now crosses an explicit `@concurrent` boundary carrying Data and nonisolated Sendable value DTOs. Each decode owns its JSONDecoder; it is never shared concurrently. Tiny request encoders and Keychain session serialization remain on MainActor.
- WebSocketClient is an actor. URLSession task delegate callbacks enter that actor, checking task identity. WebSocketMessageProcessor remains the single actor-owned decoder. WebSocketRouter owns one receive loop and request routing on MainActor.
- Streaming updates still publish through stable per-turn TurnState objects, with the existing 40 ms coalescing and immediate final flush.
- Custom wallpaper decode, PNG persistence and average-colour extraction remain on the serial background queue. File-backed ImageIO sources replace loading entire source files into Data. Remote artwork preparation uses `@concurrent`, not Task.detached.
- Attachment I/O and ImageIO decode use `@concurrent`; original owned Data and a bounded NSImage preview return to UI state.
- Avatar cache/in-flight bookkeeping is MainActor-isolated; thumbnail decode is concurrent. AppKit image mutation finishes before publication. Current SDK Sendable conformances permit immutable NSImage/NSColor results without unchecked wrappers.
- Final attributed formatting is cached only on MainActor. Streaming strings bypass both completed-content caches.

## Changes made

### HTTP, requests and data efficiency

- All network response decoding paths (authenticated/public HTTP, history, profiles, feed/discover, personas, Charms, curated lists and search) use HTTPResponseDecoder.
- Added explicit nonisolated Sendable declarations for response DTOs and nested envelopes; AuthStore was not moved off MainActor.
- Removed blind loadChat refetch. A single decoder accepts the two shapes already supported by the application: wrapped chat or direct chat. Malformed wrapped data still fails; it is not silently reinterpreted.
- A late 401 only clears the session matching the original request Authorization header, preventing an old request from clearing a newly installed session.
- Pinned-only history is requested only when some loaded turn lacks isPinned. Present true/false flags remain authoritative.
- Recent-chat preview enrichment retains single-character wire requests, using structured waves of at most three concurrent requests. Result order remains stable; unavailable previews still retain base rows. Multi-character encoding was not inferred from the plural query name.
- Added repeated-pagination-cursor detection and cancellation checks to avoid an endless history request loop.
- Removed unused ConversationService HTTPClient storage, duplicate header and unreachable copy-source fallback branches. Public HTTPClient remains because CharacterAPI uses it.
- Added a TurnKey-to-TurnState index referencing the same ordered objects; replacement/rewind rebuild it and insertion maintains it. Composer emptiness/latest-turn checks no longer reconstruct all turns.

### WebSocket reliability

- resume() is no longer treated as a completed handshake. Connection state tracks connecting, connected, disconnected, failed and cancelled; handshake waiting is bounded to 10 seconds.
- Concurrent connection callers share one task. Delegate/send/receive failures clean up only the matching task, never a newer connection.
- One logical receive loop preserves the existing one-decode path and routes by existing request_id fields.
- Create-chat, generation, regeneration, editing and pins register consumers before sending. Pin errors cannot be consumed as generation errors.
- Pin ACK waiting times out after eight seconds, independently of generation. Create-chat ACK waiting is also bounded. Timeout/termination cleanup checks operation identity.
- Removed deferred-frame arrays and manual receive continuations. Pending operations are capped at 16, each stream at 64 frames. Overflow fails explicitly rather than silently losing a final frame or retaining unlimited data.
- Disconnect/failure invalidates the loop generation, cancels receivers, finishes pending operations and serializes transport closure before reconnect.
- Pin ACKs also update an already-buffered turn's pin flag, preventing a delayed coalesced flush from undoing a pin.
- No automatic retry of send/generation mutations was added.

### Images and files

- Local wallpaper import/reload uses URL-backed CGImageSource thumbnails at the existing 1800-pixel bound; remote artwork retains the 1200-pixel bound.
- Directory creation and persisted-wallpaper existence/decode work no longer perform synchronous filesystem operations during appearance updates.
- Wallpaper generation guards are per preferences instance, not global. Stale selection checks and serial persistence ordering remain.
- Corrupt/missing persisted wallpaper restores default mode. A valid transparent wallpaper no longer fails solely because it has no average colour.
- Attachment imports run sequentially off-main, preserve owned original bytes, retain 512-pixel previews and cancel when the view disappears. No unsupported upload protocol was added; existing staging-only behaviour is preserved.
- Repeated profile/character/persona/feed avatars use CachedAvatarView. Scene backgrounds and post media remain separate AsyncImage paths.
- Avatar loads deduplicate in-flight requests and cancel shared network work when its last consumer cancels. ImageIO limits decoded images to 160 pixels, sufficient for current avatar display sizes.
- CachedAvatarView now resets when URL changes and keeps its loading task attached after success/failure, fixing stale avatars and failed-URL reuse.
- Removed unchecked Sendable from image-cache and processed-wallpaper wrappers. The remaining production unchecked class is the documented lock-protected generation counter.

### SwiftUI and formatting

- Streaming partials do not populate completed Markdown or attributed-formatting caches.
- Completed paragraphs/headings/lists reuse attributed blocks with the same fixed Font/Color/link styling. Layout expansion does not affect the cached representation. Future formatting preferences must extend the cache key.
- Removed enumerated-array allocations from message blocks/list rendering.
- TurnState does not publish when the new Turn is equal.
- Shared MainActor ISO8601 parsers replace per-row formatter creation in history, Charms and Feed; both fractional and whole-second timestamps are accepted.
- Feed reaction sorting/mapping/joining is precomputed during off-main DTO decoding without changing the displayed separator/order.
- Fixed the glass-opacity snapshot's @Published willSet lag by updating after assignment. Removed duplicate transparency persistence/snapshot updates.
- Account control now observes its profile view model rather than relying on unrelated parent updates.
- Character profile requests use structured async-let children rather than untracked Tasks.
- Updated stale blur comments. Tiny profile greetings/prompts filters, small menu transformations and inexpensive view calculations were intentionally not complicated.

## Cache/memory audit

| Cache/state | Bounds and lifetime |
|---|---|
| Parsed Markdown | NSCache: 128 entries, 8 MiB estimated cost; source cost multiplier now accounts conservatively for AST overhead; completed content only |
| Final attributed formatting | NSCache: 128 entries, 8 MiB estimated cost; MainActor-only, completed content only |
| Decoded avatars | NSCache: 150 entries, 40 MiB estimated pixel cost; 160-pixel thumbnails |
| Existing avatar HTTP URLCache | 20 MiB memory / 80 MiB disk; retained, not newly introduced |
| Prepared default artwork | Existing NSCache: 12 entries / 48 MiB estimated pixel cost; 1200-pixel images |
| Custom wallpaper | One bounded 1800-pixel image and persisted bounded PNG; two image properties refer to the same object |
| Attachments | User-owned staged originals plus 512-pixel previews; retained until explicit removal, not an indiscriminate cache |
| Socket routing | Up to 16 operations, 64 buffered frames each; timeout/termination/disconnect cleanup |
| Turn index | References existing TurnState objects; bounded by current loaded history and updated on rewind/replacement |
| Search | No new results cache; active debounce/results task cancellation and generation-guarded publication |

NSCache limits are eviction targets, not precise hard heap ceilings. Cost multipliers are estimates, not measured allocation totals. Large remote response Data and staged attachment originals still necessarily occupy memory. Full conversation history remains eager.

## Verification actually performed

- Debug builds after each logical group; final Debug and Release builds with `SWIFT_STRICT_CONCURRENCY=complete` both succeeded.
- Final compiler output has no actor/Sendable warnings. The remaining Xcode message is skipped AppIntents metadata extraction because no AppIntents dependency exists.
- git diff --check passed after final source edits.
- Executable offline checks were written and compiled with MainActor default isolation and nonisolated-nonsending semantics. Successful runs checked:
  - HTTP decode executed off the main thread; cancellation propagation.
  - Interleaved request-ID routing, unrelated messages, missing ACK timeout, late response cleanup and send failure propagation.
  - Wrapped/direct chat shapes with one HTTP fetch and no retry on a synthetic 403.
  - Conditional pinned-history request counts.
  - Ordered preview results with measured simultaneous request count between two and three.
  - Rapid autocomplete changes cancelling an active URLSession request; short/cleared query reset.
  - Generated 4096×2048 image attachment originals, preview dimensions, URL-backed wallpaper bounds and one shared avatar fetch.
  - Rapid wallpaper replacement/clear, transparent reload and corrupt persisted fallback.
  - Streaming/completed formatting equivalence, safe-link behaviour, feed/date text, equal-turn observation suppression and immediate glass snapshots.
  - Native NSHostingView/AppKit formatting rendering, producing a 1280×2000 light-appearance PNG.
- Instruments Time Profiler captured an approximately five-second synthetic verification run, target exit status zero. A trace and exported table of contents exist under .build.

### Important limits

The ignored Verification directory became access-blocked during final review. That restriction was respected. The passing offline suite and Instruments capture precede the final router generation/operation cleanup hardening, stale-401 guard, preview-concurrency compiler repair, owned attachment Data adjustment and lifecycle/deinit changes. Final source changes were rebuilt in Debug/Release but the blocked suite could not be rerun. An additional conversation end-to-end synthetic test was written but was not executed.

No live account login/logout/Keychain, invalid-session end-to-end test, Character.AI handshake/send/server-disconnect/reconnect, live pin/create/copy/send/regenerate/edit flow, long-chat scrolling, dark appearance, complete Settings/Liquid Glass interactions or feed/discover scrolling test was performed. Native formatting render is not a full application UI test. No protocol captures were collected, and no undocumented response behaviour was invented.

**No before/after measured benchmark or demonstrated application speedup was obtained.** Instruments was available and produced a synthetic trace, but realistic CPU/allocations/memory/GPU/energy/SwiftUI cause-and-effect comparisons remain outstanding.

## Remaining genuine opportunities

1. Restore authorised access to the local verification sources and rerun the complete suite on final code; add a real URLSession WebSocket loopback fixture for handshake/failure/reconnect coverage.
2. Run the authenticated regression matrix on the existing app login flow, without exposing credentials or bypassing search's web-session requirement. Validate live response request IDs and mutation semantics.
3. Measure long history/streaming, idle chat, feed/discover scrolling, large image import and rapid searches against the baseline in Instruments. Consider incremental history loading only if that demonstrates a bottleneck.
4. Scene/post media still use AsyncImage and can decode large images; a separate display-size-aware media loader needs profiling and visual validation rather than applying the avatar thumbnail size indiscriminately.
5. Attachment original bytes have no user-facing aggregate size budget; choosing a limit requires a product decision, not silently dropping attachments.
6. HTTP preview request count remains one per unique character, although sequential waiting is reduced. Batching requires a verified multi-ID wire contract.
7. Streaming still parses/formats each coalesced partial on MainActor. It avoids cache pollution but a cheaper incremental representation needs profiling and Markdown correctness tests.
8. Full app observation remains Combine-based; several views still observe broad preferences. Narrowing those further should be driven by SwiftUI cause-and-effect measurements.
9. Account/persona settings and search results retain their existing unverified/unavailable protocol boundaries. This pass does not claim to make those endpoints supported.
