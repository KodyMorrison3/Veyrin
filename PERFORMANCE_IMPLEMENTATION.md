# Veyrin performance implementation

Baseline: `4085affe025a999668d3f0bcdbc8129d33686ea1` on `main`. The checkout was clean before this work. No commits, pushes, deployments, dependencies or live Character.AI credentials were used.

## Changes made

### Conversation history

- Initial/warm snapshots still reconcile against visible content. Confirmed continuation pages deliver only newly accepted turns, preserving first-occurrence duplicate handling and ascending server order.
- Existing TurnState objects are reused. Cold pages batch new rows into one append and insert lookup entries directly. Unchanged warm pages update their rows without publishing the collection. General reconciliation and reordered warm refreshes remain available; this is not a blindly append-only implementation.
- Unconfirmed warm rows remain until authoritative completion. Completion removes missing rows and their lookup entries. Empty filtered histories retain the existing protection until a non-empty complete server history confirms it.
- A load-local value accumulator keeps a persistent membership set. Cache checkpoints grow geometrically rather than copying every cumulative page. Cancellation/failure checkpoints confirmed progress, unless a mutation, refresh, account change or newer checkpoint makes it obsolete. Partial checkpoints retain ResourceCache's original freshness deadline.
- Estimated cache cost is updated on append, replacement and removal, rather than rescanning every accumulated candidate on each page.
- Session-owned history-read leases protect even oversized histories that bypass cache admission. Leases are removed when the read finishes; no permanent per-chat revision dictionary accumulates.
- Removed the unused cumulative-page service entry point. Full history still loads eagerly.
- Removed whole-list count animation and redundant count-driven scrolling. Bottom-follow remains; pagination scrolling is not animated.

### Sidebar previews

- Recent chats return immediately without eager preview enrichment. The base list and per-character previews retain their 30-second cache TTLs.
- Native List row tasks request enrichment using stable row identity and a successful-list-refresh generation. Body recomputation alone does not restart requests. Disappearing rows release their ResourceCache waiters; the last waiter cancels queued/active work.
- One session-owned gate limits actual preview requests across service instances/callers to three. It sits inside the cached loader, so cached and deduplicated callers do not occupy duplicate network slots. ResourceCache's existing 32-pending-load bound limits queued loaders.
- Both character and chat IDs must match before applying a preview. Ordering and base metadata are unchanged; failures leave usable fallback rows.
- List publication is guarded by session/load identity. Old-account row demand is rejected. MainView identity changes with the session so account-owned UI state is reset.
- Acknowledged create invalidates the affected character preview and recent list; copy retains its existing list/all-preview invalidation. Both navigation refresh paths force a new base list and restart currently demanded rows.
- No URL parameters, single-character wire contract, timers, polling or authentication logic were changed.

**Demand is lifecycle-based, not an exact viewport guarantee.** Native List may prefetch rows. The sidebar remains a native List; unsupported visibility workarounds and a visual/navigation rewrite were deliberately avoided.

### Images

- One ImageCacheService now owns independent avatar and media decoded NSCache pools, while retaining one HTTP session and the existing URLCache policy/capacities.
- Avatars: 16 MiB cost target, 150 entries. Media: 24 MiB cost target, 40 entries. Combined target stays 40 MiB. Roughly 150 square 160-pixel thumbnails fit in the avatar target; roughly three square 1408-pixel images fit in media. NSCache targets are not hard process-memory limits.
- URL-and-size thumbnail work is shared across both pools. URL downloads are also shared across simultaneous different-resolution consumers. Consumer/load identities protect cancellation and cleanup; cancelling one consumer does not cancel another.
- CachedRemoteImage explicitly uses media and keys its task/result by URL plus resolution. Feed stays at 1408 pixels and Discover scenes at 640; no per-call-site or visual changes were needed.
- ImageIO thumbnail decoding and pixel-cost accounting remain unchanged. No extra persistent encoded-data cache was introduced.

## Files changed

| File | Reason |
|---|---|
| [ChatViewModel.swift](Character%20AI%20swift%20project/ViewModels/ChatViewModel.swift) | Incremental page reconciliation/index updates; demand preview publication; load/session guards; create invalidation |
| [ConversationService+Cache.swift](Character%20AI%20swift%20project/Services/ConversationService%2BCache.swift) | Page-delta delivery, geometric checkpoints, mutation leases, incremental snapshot cost |
| [CachedConversation.swift](Character%20AI%20swift%20project/Models/CachedConversation.swift) | Encapsulated turn changes and maintained cost estimate |
| [ChatView.swift](Character%20AI%20swift%20project/Views/ChatView.swift) | Remove whole-history animation and redundant scrolling |
| [ConversationService.swift](Character%20AI%20swift%20project/Services/ConversationService.swift) | Base-list-only load, explicit refresh, shared preview request gate |
| [ConversationRequestState.swift](Character%20AI%20swift%20project/Services/ConversationRequestState.swift) | New narrow session-owned preview gate/history-read leases |
| [AuthStore.swift](Character%20AI%20swift%20project/Authentication/AuthStore.swift) | Own/reset request state alongside existing account caches; auth behavior unchanged |
| [AuthenticatedHTTPClient.swift](Character%20AI%20swift%20project/Authentication/AuthenticatedHTTPClient.swift) | Expose that session-owned request state to conversation services |
| [ContentView.swift](Character%20AI%20swift%20project/Views/ContentView.swift) | Row-lifetime preview demand, session UI identity, create/copy refresh |
| [ImageCacheService.swift](Character%20AI%20swift%20project/Services/ImageCacheService.swift) | Separate decoded pools and shared cancellable URL downloads |
| [CachedAvatarView.swift](Character%20AI%20swift%20project/Views/CachedAvatarView.swift) | Media routing and URL/resolution task identity; injectable service for native offline check |
| [EfficiencyChecks.swift](PerformanceChecks/EfficiencyChecks.swift) | New gated offline regression fixtures and native hosted view checks |
| [Main.swift](PerformanceChecks/Main.swift) | Run new checks after all existing checks |
| [PERFORMANCE_IMPLEMENTATION.md](PERFORMANCE_IMPLEMENTATION.md) | This completion/verification record |

## Verification actually performed

- `bash PerformanceChecks/run-checks.sh`: **exit 0**, terminal `PASS all performance regression checks`, after the final test edits. The script compiles all app sources except the app entry point with complete strict concurrency, then runs existing and new checks. Existing checks were not removed or weakened.
- Debug `xcodebuild`: **exit 0**, `BUILD SUCCEEDED`.
- Release `xcodebuild`: **exit 0**, `BUILD SUCCEEDED`.
- Both builds used the existing `Character AI swift project` project/scheme, `SWIFT_STRICT_CONCURRENCY=complete`, macOS destination and `CODE_SIGNING_ALLOWED=NO`. Derived data and logs are outside the checkout in `/tmp/veyrin-efficiency-derived` and `/tmp/veyrin-efficiency-*.log`. These are compile/build checks, not distribution signing checks.
- Both build logs have no Swift compiler/concurrency warnings. The only warning is skipped AppIntents metadata extraction because there is no AppIntents dependency.
- Build artifacts were checked at both Debug/Release app executable paths. No app was launched against stored credentials.
- `git diff --check`: passed. Final diff reviewed for scope, cancellation, cache revisions, account isolation, ordering and task lifetimes.
- Real command exit statuses were explicitly preserved when displaying filtered logs. Early fixture failures were caused by inconsistent URL-path trailing-slash accounting; normalization was repaired and the affected suite rerun successfully. No assertion was weakened to get a pass.

### New offline checks

- 100 pages of 10 turns, repeated intra-page IDs and overlapping previous-page IDs: correct 1,000-turn order, 100 structural publications, stable TurnState identity.
- Page interface delivered **1,000 turns**. The former cumulative interface would visit **50,500 turns** for the same fixture (sum of 10 through 1,000); that baseline is calculated from the previous algorithm, not a measured timing. The final run completed this offline 100-page fixture in **44.08 ms**, descriptive only with no timing threshold or baseline timing. No wall-clock speedup is claimed.
- Unchanged forced multi-page refresh and warm complete reuse produce no structural publications; authoritative edits/removals reuse row objects.
- Rewinds retain the selected boundary and update cached history. Empty filtered histories retain rows; non-empty confirmation resets that protection.
- Cancellation preserves confirmed incomplete progress/cursor. Mutations reject stale page/cache writes. Repeated cursors fail explicitly.
- Incomplete resume and two concurrent readers preserve completion and share page requests. Reordered warm pages and a duplicate-only final page reconcile correctly.
- A synthetic response with 9 MiB candidate text bypasses the 32 MiB history admission budget while still completing pagination. Snapshot cost append/update/removal matches recomputation.
- Base sidebar list appears with zero preview requests. Explicit demand enriches only the requested character, matching chat IDs and preserving order.
- Concurrent callers share cached work; cancelling one leaves the other intact. Peak active preview requests measured **3**; queued cancellation sends no HTTP request.
- Refresh generations reject obsolete demand; wrong-character results and 503 previews preserve fallback rows. Last-consumer cancellation and logout clear active work. Account B rejects old-account demand and loads its own previews.
- Logout during the first history request cannot publish/cache old-account turns. Copy invalidation and demanded-row refresh are exercised through the actual service path.
- Native NSHostingView List fixture exercises row-lifecycle enrichment. This is not proof of viewport-only fetching.
- Generated 1800-square image verifies 160/640/1408 thumbnail bounds. Identical-size cross-pool consumers and different-size consumers share one URL request.
- Cached avatar survives eight large media loads and explicit media-cache clearing. Different-size cancellation preserves a survivor; last-consumer cancellation clears download/decode bookkeeping.
- Native CachedRemoteImage fixture changes resolution at the same URL and renders the new media result.

## Limits and deliberately deferred work

- Full authenticated chat/create/send/edit/pin/copy flows were not automated. No live account/session token was used; create ACK invalidation is code-reviewed, not exercised through a live WebSocket.
- The hosted native fixtures cover row-task and image-resolution behavior, not full application navigation, exact scrolling geometry, List prefetch extent or every disappearing/filtering interaction.
- Cold continuation merging avoids repeated prefix visits/index reconstruction. Reordered warm refreshes still use a general tail reconciliation; Combine/SwiftUI array observation/diffing and copy-on-write can still incur whole-array work. This is not a claim that every history path is linear or that SwiftUI publication is constant-cost.
- Geometric checkpoints mean other readers can briefly see an earlier incomplete snapshot. They share cached page requests; cancellation/failure persists confirmed progress and guards prevent stale checkpoint rollback. TTL deadlines are deliberately not extended by local updates.
- NSCache can evict under system pressure; independent budgets prevent media-cache operations from competing for the avatar pool, not all possible avatar eviction.
- Scroll-triggered pagination, protocol batching, persistent history storage and ResourceCache/Markdown/WebSocket rewrites were not implemented. They add architectural or undocumented-contract risk beyond these targeted changes.
- Live Instruments profiling is still needed for long-chat scrolling/refresh, streamed generation, sidebar request behavior while scrolling/filtering, feed media pressure, allocations, CPU, energy and GPU effects. Neither battery savings nor authenticated UI speedups have been measured.
