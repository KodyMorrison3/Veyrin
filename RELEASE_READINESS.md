# Veyrin v0.1.0 release preparation

Audit date: 12 October 2026. Local baseline: `67bfded9fa2171b7c4b792503af204d700bfc8de` on `main`. Fetched remote `main`: `09931fb3ed7c95e055725e25c0715031be0f0359` (README-only change). The working copy contains uncommitted release fixes; no commit, push, tag, release, upload or visibility change was made.

## A. Release verdict

**Not ready to publish: history/privacy findings need an explicit resolution.** The corrected local application, offline suites and final DMG pass the checks below. That does not make the existing private Git history safe to expose.

Keep the repository private until the historical account/profile/feed captures and old screenshot exposure are removed through an approved process, or knowingly accepted for public disclosure by their owner with any third-party rights/privacy concerns resolved. Do not treat a new commit deleting files as history removal.

## B. Changes made

- [README.md](README.md): retained centred hero, badges, screenshots, features, architecture, security, build, limitations, status, licence and disclaimer. Corrected repository/clone/CI URLs and both Swift badges; documented actual Swift language mode, macOS/arm64 version settings, public scripts, safe installation, local data retention, unsupported features and safe bug reports.
- [.gitignore](.gitignore): made only the reviewed packaging/audit scripts and synthetic verification files eligible for tracking. Local captures, credentials, build outputs, unrelated tests and development material remain ignored.
- [project.pbxproj](Character%20AI%20swift%20project.xcodeproj/project.pbxproj): explicit arm64 and complete concurrency checking, explicit Release entitlements/hardened runtime, debugger injection disabled for Release, local project-ID/.DS_Store resource exclusion. Version 0.1.0, build 1, deployment target 27.0 and bundle ID retained.
- [Veyrin.entitlements](Character%20AI%20swift%20project/Veyrin.entitlements): Sandbox, outgoing network and user-selected read-write files for library export; no `get-task-allow`, incoming network, camera, microphone or other resource permissions.
- [CharacterAISession.swift](Character%20AI%20swift%20project/Networking/CharacterAISession.swift): ephemeral authenticated transport, no HTTP cache/cookies/credential store, redirect refusal and exact HTTPS authentication destination policy.
- [AuthenticatedHTTPClient.swift](Character%20AI%20swift%20project/Authentication/AuthenticatedHTTPClient.swift), [SessionValidator.swift](Character%20AI%20swift%20project/Authentication/SessionValidator.swift), [DiscoverService.swift](Character%20AI%20swift%20project/Services/DiscoverService.swift), [FeedService.swift](Character%20AI%20swift%20project/Services/FeedService.swift), [PopularTrendingService.swift](Character%20AI%20swift%20project/Services/PopularTrendingService.swift), [UserProfileService.swift](Character%20AI%20swift%20project/Services/UserProfileService.swift), [CharmsService.swift](Character%20AI%20swift%20project/Services/CharmsService.swift), [CharacterSearchService.swift](Character%20AI%20swift%20project/Services/CharacterSearchService.swift): use private authenticated transport; generic search rejection instead of echoing arbitrary server text.
- [WebSocketClient.swift](Character%20AI%20swift%20project/Networking/WebSocketClient.swift), [WebSocketRouter.swift](Character%20AI%20swift%20project/Networking/WebSocketRouter.swift), [NetworkError.swift](Character%20AI%20swift%20project/Networking/NetworkError.swift), [WebSocketTurnResponse.swift](Character%20AI%20swift%20project/Models/WebSocketTurnResponse.swift): private WebSocket transport and redirect rejection; raw transport/decoder/server error text no longer copied into ordinary diagnostics or user-facing network errors. Numeric server codes and schema key paths remain useful.
- Temporary profile-navigation and conversation-copy tracing was removed after the underlying behavior and its synthetic regression checks were in place; navigation and copy-source code no longer emits diagnostic traces.
- [GitHubReleaseService.swift](Character%20AI%20swift%20project/Services/GitHubReleaseService.swift): corrected the runtime releases API repository, not just the README links. This is a metadata check, not automatic updating.
- [AuthStore.swift](Character%20AI%20swift%20project/Authentication/AuthStore.swift), [CharacterAIApp.swift](Character%20AI%20swift%20project/App/CharacterAIApp.swift): `--no-session-restore` allows a signed-out launch smoke test without reading/deleting saved credentials. Normal restoration remains the default.
- [package-dmg.sh](Scripts/package-dmg.sh): explicit ad-hoc or Developer ID choice; no Apple Development public-distribution fallback; exact version/architecture/entitlement checks; unexpected bundle-file rejection; licence/installation notes/Applications shortcut; mount/integrity/signature/checksum checks; no silent failures or overwriting existing assets. Optional notarisation uses a local Keychain profile.
- [audit-history.py](Scripts/audit-history.py): offline object-level redacted triage, including deleted files and locally dangling objects. It reports paths/objects/lines, not matched values; it is not a security certification.
- [SecurityChecks.swift](PerformanceChecks/SecurityChecks.swift), [Main.swift](PerformanceChecks/Main.swift): synthetic authentication destination/redirect-policy/error-privacy regressions. The performance suite no longer tests `--no-session-restore`; that launch argument is exercised by the separate packaged-app smoke test when available.
- [Verification/](Verification/): reviewed synthetic suites made distributable. Auth tests updated for the existing token-only sign-in interface; removed-mode wallpaper assertions updated to `.solidColor`; URLProtocol callbacks made nonisolated with lock-protected state; actor stream iterators use `next(isolation: self)`; scripts use the project's approachable-concurrency feature flags and complete checking. No assertions were dropped or suppressed to pass.
- [ci.yml](.github/workflows/ci.yml): kept the verified `xcode-27` arm64 preview runner; added toolchain checks, Debug and Release, six offline suites, script checks, read-only permissions, manual trigger and timeout. No release upload step.
- [Convo.png](screenshots/Convo.png), [Browsing.png](screenshots/Browsing.png): expanded flattened black masks over all lower-sidebar/account activity; removed ancillary source metadata. Older committed images remain exposed in history until resolved.
- [RELEASE_NOTES_v0.1.0.md](RELEASE_NOTES_v0.1.0.md): prepared pre-release title, description, features, risks, limitations, platform, signing status, installation, assets/checksum and GPL source obligations. This report records the release gate.

## C. Build and test results

Environment: macOS 27.0.1 (26A434), Apple Silicon, Xcode 27.0 (27A266a), macOS SDK 27.0, Swift compiler 6.4 in Swift 5 language mode. The actual `Character AI swift project` project and scheme were used. Exit statuses were retained independently of log filtering.

| Check | Result | Scope |
|---|---|---|
| Debug arm64 `xcodebuild build` | **Passed, exit 0** | Final project settings, complete concurrency, signing disabled for compile check |
| Release arm64 `xcodebuild build` | **Passed, exit 0** | Final project settings, complete concurrency, signing disabled for compile check |
| Performance/security suite | **Passed, exit 0** | Existing history/cache/image/native row tests plus allowlisted authentication destinations, refused redirects and safe error descriptions (`PerformanceChecks/SecurityChecks.swift`) |
| Reliability suite | **Passed, exit 0** | HTTP executor/cancellation; WebSocket routing/timeout/failure; create/send/stream/pin/regenerate/edit; filtered response/history preservation; HTTP/search cancellation; images/wallpapers; native formatting rendering |
| Authentication suite | **Passed, exit 0; 19 scenarios** | Validated identity, missing IDs, rejection/unavailability, stale sign-in/401 races and saved-session restoration with in-memory storage |
| Decode diagnostics | **Passed, exit 0** | Required fields named; empty preview and valid responses preserved |
| Model-default checks | **Passed, exit 0** | Tier/model mapping and fallbacks; no entitlement bypass |
| Profile navigation | **Passed, exit 0** | Similar-character/back/dismiss chain; in-flight cancellation and stale-result rejection |
| Final packaging and mounted DMG | **Passed, exit 0** | Signed arm64 Release app, exact entitlement set, expected inventory, version/ID, checksum/integrity |
| Source-only fresh-copy commands | **Passed** | Documented unsigned Debug build, all six suites and ad-hoc packaging, without ignored local tooling/captures or existing build output; files must still be committed before a remote fresh clone contains them |
| Packaging failure paths | **Passed** | Missing signing choice, ad-hoc/notary mismatch and existing-output refusal; existing DMG hash unchanged |
| Final edited script and document checks | **Passed** | Final script rerun successfully in source-only copy; Bash/Python syntax, project/entitlement plist lint, workflow YAML parse, local documentation links and `git diff --check` |
| Packaged app launch | **Passed** | Copied from final mounted image, process alive with one visible window and correct bundle ID; `--no-session-restore`; no open network sockets observed |
| Clean macOS / downloaded quarantine installation | **Could not be run** | Current developer machine is not a clean installation; no clean-user Keychain/signature migration test |
| Live Character.AI authentication/streaming/features | **Not run** | No live token/account used; synthetic fixtures are not service compatibility proof |
| XCTest via `xcodebuild test` | **Not applicable** | Project contains no XCTest target/test action; standalone suites above were run instead |
| Developer ID signing / notarisation | **Could not be run** | No Developer ID Application identity available; Apple Development identity is not a distribution substitute |
| Expanded GitHub workflow | **Not run remotely** | Needs an explicitly approved commit/push; old workflow success is not success for these uncommitted changes |
| Ignored ContractTests/Docs/Tests | **Not run/read in working copy** | Protected local development material was not bypassed. Committed historical versions were included in the Git-object audit |

Final suites have no compiler/concurrency warnings. Debug and Release compile logs each have one non-Swift warning: AppIntents metadata extraction skipped because there is no AppIntents dependency. Xcode also emits an informational destination diagnostic. Packaging's `hdiutil` mount/eject commands work but report deprecation warnings on macOS 27.

Earlier failures were investigated, not hidden: stale `.default` wallpaper tests did not compile; explicit actor/URLProtocol isolation repaired test warnings; the first packaging attempt rejected Xcode-injected debugger permission; a mounted candidate exposed a local `project-id` resource. Release entitlements and resource exclusions were repaired, builds/suites rerun, and a new final DMG produced. The earlier contaminated candidate must not be published.

Local verification logs and exit-status files are retained in [build/release-audit/](build/release-audit/); the value-redacted history inventory is [history-triage.json](build/release-audit/history-triage.json). This directory is ignored and is not a release asset. Fresh-copy packaging creates a separate validation DMG, not the designated release asset; identical image hashes are not expected from independently created filesystem images.

No battery, GPU, Instruments or live-account speedup measurement was made. The offline performance suite prints its representative pagination timing; it has no before/after timing baseline and is not evidence of an authenticated UI speedup.

## D. Security and privacy audit

### History scope

The clone is **not shallow**. Remote heads/tags were enumerated and remote `main` fetched without merging. GitHub API confirmed a private repository, one branch (`main`), no tags and no releases. Local object inventory was **72 commits, 253 trees and 436 blobs**; **68 commits reachable from the available refs**, plus locally unreachable commits/blobs. Every locally available blob/commit/tag payload was scanned, and historical trees were traversed to map deleted paths. This includes historical ContractTests, CacheChecks, removed authentication/diagnostic sources and binary image bytes/metadata. `git fsck --full --no-reflogs` reported dangling objects, not missing/corrupt objects.

The full available history scan is complete, but this is **not a claim that the repository is clean**. Pattern scanning cannot rule out unknown/encoded secrets or steganography. Server-only unreachable objects, previously deleted remote branches not present locally, hidden PR refs, other clones, backups and private GitHub settings were not audited. Current ignored personal captures/logs were not copied into source or release assets. No scanner received source or secret values over the network.

### Findings requiring resolution

| Material | Affected path and commit | Why it matters |
|---|---|---|
| Captured signed-in profile/account handle and subscription metadata | `ContractTests/UserProfileContractTests.swift`, introduced `e8bf12adaf004f6f8b1a205b27ea485c792f9fb3`; historical blob `ddc62bdcdd5887a8af2981e1e17d51a6028cd169` | Real account-identifying capture rather than a wholly synthetic fixture; deleted/ignored now, still reachable |
| Raw feed capture with user/creator identifiers, cursor and embedded content references | `ContractTests/FeedContractTests.swift`, `75231cfe21348f45b9bbddaab18c831d6ae55636`; blob `c79e41836af088041eca64046c1f417a81d900ee` | Third-party content and account/activity identifiers remain in history; public-feed provenance does not make republishing automatically acceptable |
| Captured character-search result with creator/account identifiers | `ContractTests/CharacterSearchContractTests.swift`, introduced `e8bf12adaf004f6f8b1a205b27ea485c792f9fb3`, updated `75231cfe21348f45b9bbddaab18c831d6ae55636` | Real response fixture needs privacy/provenance review before public history exposure |
| Incomplete screenshot redaction: signed-in username and conversation rows visible outside masks | `screenshots/Convo.png` and `screenshots/Browsing.png`, introduced `8d8bc5d` | Current images repaired, but older blobs remain in history; no personal value reproduced here |
| Author email/identity in Git metadata and development team identifier in Xcode settings | Git commit metadata; project settings/history | Not credentials, but identity information that becomes public with the repository; owner must knowingly accept it |

No confirmed real session token, API credential, password, private key, committed HAR/environment secret, plaintext auth log or private full conversation transcript was found by the scans and candidate review. Token-literal matches were synthetic fixtures or runtime interpolation; long opaque production literals reviewed were character IDs, not established credentials. An old deleted search diagnostic sends no credentials and deliberately suppresses response/error text. Binary image regex hits were not treated as credentials without supporting evidence. Historical icon provenance metadata also warrants normal artwork/licensing review.

### Authentication and runtime review

- Tokens are entered through SecureField, validated before persistence, and stored in Keychain generic-password items with the existing service/account identity. Keychain errors log status or private error details, never the serialized session. Changing Keychain service/access groups was deliberately avoided to prevent migration surprises.
- Keychain round-trip/permissions with a clean user was not performed; authentication tests substitute in-memory storage. Logout attempts to delete credentials, but a Keychain deletion failure can leave a saved item; that is logged, not silently claimed as securely erased.
- Default authenticated REST/WebSocket sessions now avoid persistent caches, shared cookie stores and credential storage and reject redirects. The one exception is an opt-in character-search cookie: the user pastes it, it is stored as a separate Keychain item, sent only to `character.ai`, and cleared on sign-out. The injected test transports are synthetic. HTTPS destination rejection is enforced in the generic authenticated HTTP client; other service URLs are fixed HTTPS Character.AI endpoints. TLS verification is not overridden; no broad ATS exception was added.
- Account cache generations, stale-result protection, bounded WebSocket routing, final streaming updates, history reconciliation, editing/pinning and session-owned data invalidation were reviewed and exercised offline where covered.
- Navigation identifiers are not logged in Release. Network errors avoid arbitrary underlying/response text; server numeric codes remain. Do not assume all OS diagnostic/crash reports are safe to post unredacted.
- Persona definitions/preferences remain on disk in account-labelled UserDefaults; image caches and wallpaper can persist. The local character catalogue and local Ollama conversations are stored as unencrypted JSON under Application Support/Veyrin and are not cleared on sign-out. The security review has **not yet audited** this local-data storage. Character.AI still has no durable local conversation database or offline-first mode.
- Ollama local chat connects over loopback HTTP at `127.0.0.1:11434` and may optionally launch Ollama automatically. The security review has **not yet audited** this local service, its launch/termination handling or loopback HTTP exposure. No live Ollama service test was performed.
- Search shows an unavailable state unless the user supplies a browser web-session cookie. The app does not harvest, refresh, log or persist that cookie anywhere except the Keychain item the user controls; it sends it only to `character.ai` and clears it on sign-out. Without the cookie, search stays unavailable. No CAPTCHA solution, TLS bypass, entitlement fabrication, automatic rate-limit retry or paywall bypass was found. Model options come from server responses; server access errors remain errors. Origin/User-Agent compatibility headers do not prove Character.AI permits this client.
- The project declares Swift Package Manager dependencies on ZipArchive and SystemPackage for local archive import/export. GPL-3.0 text is present and recognised by GitHub. Artwork, screenshots and historical captured third-party content are not automatically covered by a licence declaration.

## E. Final DMG

**Use only this candidate:** [Veyrin-0.1.0.dmg](build/release-v0.1.0-clean/Veyrin-0.1.0.dmg).

Absolute path: `/Users/kody/Documents/Character AI swift project/build/release-v0.1.0-clean/Veyrin-0.1.0.dmg`.

- Version 0.1.0; build 1; `com.kodymorrison.veyrin`; minimum macOS 27.0; arm64 only.
- App signature: **ad-hoc**, hardened runtime, exact Sandbox/outgoing network/user-selected read-write entitlements, no debugger permission. Signature verification passed on built, mounted and copied bundle.
- DMG: non-empty compressed UDZO/APFS image; integrity verified and mounted successfully. DMG itself is unsigned; no notarisation performed.
- Root inventory: `Veyrin.app`, `/Applications` shortcut, `Install.txt`, `LICENSE.txt`.
- App file inventory: Info.plist, PkgInfo, executable, AppIcon.icns, Assets.car and signature seal only. No source, test fixtures, local project-ID, logs, tokens, captures or user conversation database present in the reviewed inventory.
- [Checksum file](build/release-v0.1.0-clean/Veyrin-0.1.0.dmg.sha256), successfully verified:

```text
f53a4d096ef1e13b8236a8eb67dd1134498ea14a815552dfbc9a3f4825ace5f7
```

Earlier local DMGs were not overwritten. In particular, `build/release-v0.1.0/` contains the rejected pre-resource-exclusion candidate and must not be uploaded.

## F. Remaining blockers versus experimental limitations

**Publication blockers:**

1. Resolve the historical privacy/third-party capture and old screenshot findings before making this repository public. No history rewrite or disclosure consent has been assumed.
2. Reconcile the README-only remote commit with the reviewed working copy, include the newly trackable scripts/tests, choose a reviewed source commit, and get an approved push. The DMG currently represents uncommitted source, not a public release tag.
3. Confirm the expanded workflow passes on that exact remote source. The current old workflow success is not sufficient evidence for the expanded checks.
4. Decide whether live-account and clean-user/quarantined-install checks are required before this first experimental release, or disclose them as unverified. In particular, denying redirects may expose undocumented service changes; no live compatibility claim is made.
5. Confirm redistribution rights/provenance for project artwork and screenshots; GPL applies to the project's code, not automatically to unrelated images or captured third-party content.

**Acceptable only when clearly disclosed for an experimental pre-release:** ad-hoc signature/no notarisation; macOS 27/arm64 only; unsupported search; no offline/durable conversation storage; no automatic updates; undocumented-endpoint/account risk; persistent local persona/image settings; no measured real-world battery/GPU speedup; preview-runner availability risk.

## G. Publishing checklist

- [ ] Resolve history/privacy findings using an approved, backed-up plan; rerun the full history scan after any repair. Do not just delete the current files.
- [ ] Review/approve asset provenance and personal Git author metadata disclosure.
- [ ] Reconcile remote README without losing either set of intended edits; review and commit only release files after approval.
- [ ] Obtain push approval; push reviewed source while still private and verify expanded CI on the exact SHA.
- [ ] Perform clean-user download/quarantine/Keychain and live-account smoke checks, or explicitly accept/document their absence.
- [ ] Rebuild the DMG from the exact reviewed tag candidate if code changes, verify inventory/signature/mount/checksum again and update notes accordingly.
- [ ] Obtain explicit visibility, tag, asset-upload and release-publication approval.
- [ ] Make corresponding source/build scripts available under GPL-3.0; create/push `v0.1.0` at that SHA.
- [ ] Create **Veyrin v0.1.0**, mark **pre-release**, attach only the final DMG/checksum, replace local asset links in notes with actual GitHub asset links and publish after approval.
- [ ] Check actual public release assets/download checksum and clarify README status. No automatic updater is implied.

Existing workflow success: [run 38276556977](https://github.com/KodyMorrison3/Veyrin/actions/runs/38276556977), remote SHA `09931fb3ed7c95e055725e25c0715031be0f0359`. The `xcode-27` runner is a documented arm64 public-preview image; future image contents can change. Sources: [GitHub runner image policy](https://github.com/actions/runner-images), [GitHub hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), [Apple safe opening guidance](https://support.apple.com/en-us/102445).

## H. Approval required

Explicit approval is required before changing visibility, creating/pushing a release tag, publishing a GitHub Release, uploading the DMG, pushing commits, rewriting Git history, deleting refs or rotating/invalidation of credentials. None was performed. Local docs/code/tests/builds and DMG preparation are reversible working-copy changes only.
