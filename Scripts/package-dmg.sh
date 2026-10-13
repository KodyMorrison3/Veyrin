#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
    cat <<'EOF'
Usage: bash Scripts/package-dmg.sh --ad-hoc [--output-dir DIRECTORY]
       bash Scripts/package-dmg.sh --developer-id IDENTITY [--notary-profile PROFILE] [--output-dir DIRECTORY]

Ad-hoc signing is for experimental distribution only; it is not Developer ID signing.
Notarisation requires an explicit Developer ID identity and a local notarytool Keychain profile.
Existing DMGs/checksums are never overwritten. No credentials belong in this repository.
EOF
}
fail() { echo "error: $*" >&2; exit 1; }
mode=""
identity=""
profile=""
output="build"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help) usage; exit 0 ;;
        --ad-hoc) [ -z "$mode" ] || fail "choose one signing method"; mode="ad-hoc"; identity="-"; shift ;;
        --developer-id) [ "$#" -ge 2 ] || fail "missing signing identity"; [ -z "$mode" ] || fail "choose one signing method"; mode="developer-id"; identity="$2"; shift 2 ;;
        --notary-profile) [ "$#" -ge 2 ] || fail "missing Keychain profile name"; profile="$2"; shift 2 ;;
        --output-dir) [ "$#" -ge 2 ] || fail "missing output directory"; output="$2"; shift 2 ;;
        *) usage >&2; fail "unknown option: $1" ;;
    esac
done
[ -n "$mode" ] || { usage >&2; fail "explicit signing choice required"; }
[ -z "$profile" ] || [ "$mode" = developer-id ] || fail "notarisation requires Developer ID signing"
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || fail "requires an Apple Silicon Mac"
for tool in xcodebuild xcrun codesign hdiutil diskutil ditto shasum python3; do
    command -v "$tool" >/dev/null || fail "missing $tool"
done
sdk=$(xcrun --sdk macosx --show-sdk-version)
[ "${sdk%%.*}" -ge 27 ] || fail "macOS 27 SDK required"
mkdir -p "$output"
output=$(cd "$output" && pwd)
[ ! -e "$output/Veyrin-0.1.0.dmg" ] && [ ! -e "$output/Veyrin-0.1.0.dmg.sha256" ] || fail "output already exists; choose a new --output-dir"
work=$(mktemp -d "$output/.package.XXXXXX")
mount="$work/mounted"
mounted=""
cleanup() {
    if [ -n "$mounted" ]; then hdiutil detach "$mount" >/dev/null || echo "warning: detach $mount manually" >&2; fi
    rm -rf "$work"
}
trap cleanup EXIT

# Release uses explicit Sandbox entitlements, not Xcode's debugger entitlement injection.
echo "Building Release arm64 ($mode)"
xcodebuild -quiet build \
    -project "Character AI swift project.xcodeproj" \
    -scheme "Character AI swift project" \
    -configuration Release -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$work/DerivedData" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO SWIFT_STRICT_CONCURRENCY=complete \
    CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$identity" DEVELOPMENT_TEAM= \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ENABLE_HARDENED_RUNTIME=YES
app="$work/DerivedData/Build/Products/Release/Veyrin.app"
[ -s "$app/Contents/MacOS/Veyrin" ] || fail "missing app executable"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
[ "$version" = 0.1.0 ] || fail "expected version 0.1.0, got $version"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")" = 1 ] || fail "expected build 1"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" = com.kodymorrison.veyrin ] || fail "wrong bundle identifier"
[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist")" = 27.0 ] || fail "wrong deployment target"
[ "$(xcrun lipo -archs "$app/Contents/MacOS/Veyrin")" = arm64 ] || fail "wrong architecture"
codesign --verify --deep --strict "$app"
python3 - "$app" <<'PY'
from pathlib import Path
import sys
app = Path(sys.argv[1])
allowed = {'Contents/Info.plist', 'Contents/PkgInfo', 'Contents/MacOS/Veyrin',
           'Contents/_CodeSignature/CodeResources', 'Contents/Resources/AppIcon.icns',
           'Contents/Resources/Assets.car', 'Contents/embedded.provisionprofile'}
actual = {str(path.relative_to(app)) for path in app.rglob('*') if path.is_file()}
if actual - allowed:
    raise SystemExit('error: unexpected bundle files: ' + ', '.join(sorted(actual - allowed)))
PY
codesign -d --entitlements - --xml "$app" > "$work/entitlements.plist"
python3 - "$work/entitlements.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as stream:
    actual = plistlib.load(stream)
required = {'com.apple.security.app-sandbox': True,
            'com.apple.security.network.client': True,
            'com.apple.security.files.user-selected.read-only': True}
if actual != required:
    raise SystemExit('error: unexpected Release entitlements (including any debug/access permissions)')
PY
codesign -dv --verbose=4 "$app" 2> "$work/signature.txt"
if [ "$mode" = ad-hoc ]; then
    grep -q '^Signature=adhoc$' "$work/signature.txt" || fail "not ad-hoc signed"
else
    grep -q '^Authority=Developer ID Application:' "$work/signature.txt" || fail "not Developer ID Application signed"
    grep -q 'runtime' "$work/signature.txt" || fail "missing hardened runtime"
fi
stage="$work/stage"
mkdir "$stage"
ditto --norsrc --noextattr "$app" "$stage/Veyrin.app"
ln -s /Applications "$stage/Applications"
cp LICENSE "$stage/LICENSE.txt"
cat > "$stage/Install.txt" <<'EOF'
Veyrin v0.1.0 — experimental, unofficial Character.AI client
Requires macOS 27 or later and Apple Silicon.
Drag Veyrin.app to Applications, eject this image, then open Veyrin from Applications.
Verify the published SHA-256 checksum before installation.
This client uses undocumented endpoints; consider account and privacy risks before signing in.
See the release notes for signing/notarisation status and known limitations.
If macOS blocks an unnotarised build, only use Privacy & Security > Open Anyway if you trust it.
Never disable Gatekeeper globally or ignore a malware/damaged-app warning.
GPL-3.0; LICENSE.txt accompanies this app. Corresponding source: https://github.com/KodyMorrison3/Veyrin
Never share session tokens or private conversations in bug reports.
EOF
candidate="$work/Veyrin-$version.dmg"
# hdiutil is deprecated on newer macOS; diskutil is its supported replacement.
if ! diskutil image create from --format UDZO --volumeName "Veyrin $version" "$stage" "$candidate" > "$work/image.log" 2>&1; then
    cat "$work/image.log" >&2; fail "DMG creation failed"
fi
[ -s "$candidate" ] || fail "empty DMG"
if [ -n "$profile" ]; then
    codesign --timestamp --sign "$identity" "$candidate"
    xcrun notarytool submit "$candidate" --keychain-profile "$profile" --wait
    xcrun stapler staple "$candidate"
    xcrun stapler validate "$candidate"
else
    echo "Not notarised."
fi
hdiutil verify "$candidate"
mkdir "$mount"
hdiutil attach -readonly -nobrowse -mountpoint "$mount" "$candidate" > "$work/mount.log"
mounted=yes
codesign --verify --deep --strict "$mount/Veyrin.app"
[ "$(readlink "$mount/Applications")" = /Applications ] || fail "missing Applications shortcut"
[ "$(xcrun lipo -archs "$mount/Veyrin.app/Contents/MacOS/Veyrin")" = arm64 ] || fail "mounted app architecture mismatch"
hdiutil detach "$mount" >/dev/null
mounted=""
dmg="$output/Veyrin-$version.dmg"
[ ! -e "$dmg" ] && [ ! -e "$dmg.sha256" ] || fail "output already exists; choose a new --output-dir"
# Hard links fail rather than clobber an artifact created by another process.
ln "$candidate" "$dmg"
(cd "$output" && shasum -a 256 "Veyrin-$version.dmg") > "$work/checksum"
ln "$work/checksum" "$dmg.sha256"
echo "DMG: $dmg"
echo "Signature: $mode"
cat "$dmg.sha256"
