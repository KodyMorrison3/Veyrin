# Veyrin v0.1.0

**Experimental pre-release — first native macOS build.** Veyrin is an unofficial Swift/SwiftUI client for Character.AI. It is independent of Character.AI and is not endorsed or supported by it.

> Preparation only: these notes and assets have not been published. Resolve the history/privacy findings in RELEASE_READINESS.md and obtain explicit publishing approval first. When publishing, mark the GitHub Release as a **pre-release**, with title **Veyrin v0.1.0** and tag **v0.1.0** at the reviewed source commit.

## What's included

- Recent conversations, previews and paginated history.
- WebSocket message streaming, alternate candidates, message editing and pinning.
- New conversations and conversation controls.
- Discover, similar-character profiles and feed browsing.
- Native SwiftUI navigation, image thumbnail caching and appearance settings.
- Server-validated session-token sign-in with macOS Keychain storage and App Sandbox permissions.

These features are implemented, not a promise that every live Character.AI workflow works. Release checks used synthetic HTTP/WebSocket fixtures; no live account was used for this audit.

## Requirements

- **macOS 27 or later**.
- **Apple Silicon (arm64)**; Intel Macs are not supported by this package.
- App version **0.1.0**, build **1**; bundle identifier `com.kodymorrison.veyrin`.
- A Character.AI account and valid session token for authenticated use.

## Download and install

Prepared local assets (attach both after approval):

- [Veyrin-0.1.0.dmg](build/release-v0.1.0-clean/Veyrin-0.1.0.dmg)
- [Veyrin-0.1.0.dmg.sha256](build/release-v0.1.0-clean/Veyrin-0.1.0.dmg.sha256)

Once published, the files will appear under this release's **Assets** on [GitHub Releases](https://github.com/KodyMorrison3/Veyrin/releases). No public download URL exists yet; replace the local links above with the uploaded asset links before publishing.

SHA-256 of the prepared DMG:

```text
f53a4d096ef1e13b8236a8eb67dd1134498ea14a815552dfbc9a3f4825ace5f7
```

In the directory containing both downloads:

```bash
shasum -a 256 -c Veyrin-0.1.0.dmg.sha256
```

Open the image, drag **Veyrin.app** to **Applications**, eject the DMG, then open the app from Applications. The image also contains installation notes and the GPL licence.

**Signing:** the app is **ad-hoc signed**, with a verified signature and Sandbox entitlements. It is **not Developer ID signed or notarised**; the DMG itself is not signed. macOS may block the downloaded app. Only if you trust the verified download, use **System Settings → Privacy & Security → Open Anyway** after the blocked launch. Do not disable Gatekeeper globally, remove quarantine as a routine installation step, or ignore a malware/damaged-app warning. [Apple guidance](https://support.apple.com/en-us/102445).

## Known limitations and risks

- Character search results are unsupported. Use Discover and Similar Characters instead.
- No offline-first operation or durable local conversation database.
- No automatic update installer; Settings only checks GitHub release metadata.
- Persona definitions/selections are saved in account-labelled preferences, not encrypted. Image caches and wallpaper may remain on disk after sign-out.
- No clean-machine, quarantined-download installation test or live authentication/streaming acceptance test was performed during this release audit.
- Undocumented endpoints can change without notice and break sign-in, streaming or other features. There is no official public API available for this project.
- Use of an unofficial client may carry account risk under Character.AI's terms. Consider that before supplying a token, and do not use an account you cannot afford to lose access to.

Treat a session token like a password. Bug reports should contain reproducible steps and synthetic examples, never tokens, cookies, authentication headers, HAR files or private conversations.

## Licence

Veyrin is distributed under **GPL-3.0**; see [LICENSE](LICENSE). Publish the corresponding reviewed source and build scripts with the binary. Character.AI names and trademarks belong to their owners. The software is provided without warranty.
