#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
output=$(mktemp -d /tmp/veyrin-verification.XXXXXX)
trap 'rm -rf "$output"' EXIT
# Keep fixture provider transcripts out of the real Application Support folder.
export VEYRIN_SUPPORT_DIRECTORY="$output/support"
mkdir -p "$VEYRIN_SUPPORT_DIRECTORY"
package_build="${VEYRIN_DERIVED_DATA:-.build/VeyrinDerivedData}"
if [[ ! -d "$package_build/Build/Products/Debug/ZipArchive.swiftmodule" ]]; then
    mkdir -p "$(dirname "$package_build")"
    xcodebuild -project 'Character AI swift project.xcodeproj' -scheme 'Character AI swift project' \
        -configuration Debug -sdk macosx -destination 'generic/platform=macOS' \
        -derivedDataPath "$package_build" CODE_SIGNING_ALLOWED=NO build > "$output/package-build.log"
fi
sources=()
while IFS= read -r -d '' source; do
    sources+=("$source")
done < <(find 'Character AI swift project' -name '*.swift' ! -name CharacterAIApp.swift -print0)
checks=()
while IFS= read -r -d '' source; do
    checks+=("$source")
done < <(find Verification -maxdepth 1 -name '*.swift' -print0)
build_products="$package_build/Build/Products/Debug"
find_product() {
    local product="$1" root="$2" match
    match=$(find "$root" -type f -name "$product" -print -quit)
    if [[ -z "$match" ]]; then
        echo "error: could not find $product under $root after the Xcode build" >&2
        exit 1
    fi
    printf '%s\n' "$match"
}
zip_object=$(find_product ZipArchive.o "$package_build/Build")
system_object=$(find_product SystemPackage.o "$package_build/Build")
zlib_object=$(find_product CZipArchiveZlib.o "$package_build/Build")
system_c_object=$(find_product CSystem.o "$package_build/Build")
system_modulemap=$(find "$package_build/SourcePackages" -type f -path '*/Sources/CSystem/include/module.modulemap' -print -quit)
if [[ -z "$system_modulemap" ]]; then
    echo "error: could not find the swift-system CSystem module map under $package_build/SourcePackages" >&2
    exit 1
fi
zlib_modulemap=$(find "$package_build/Build" -type f -name 'CZipArchiveZlib.modulemap' -print -quit)
if [[ -z "$zlib_modulemap" ]]; then
    echo "error: could not find CZipArchiveZlib.modulemap under $package_build/Build" >&2
    exit 1
fi
swift_flags=(
    -parse-as-library -D DEBUG -swift-version 5 -strict-concurrency=complete
    -default-isolation MainActor
    -enable-upcoming-feature NonisolatedNonsendingByDefault
    -enable-upcoming-feature InferIsolatedConformances
    -enable-upcoming-feature GlobalActorIsolatedTypesUsability
    -enable-upcoming-feature InferSendableFromCaptures
    -I "$build_products"
    -Xcc "-fmodule-map-file=$system_modulemap"
    -Xcc "-fmodule-map-file=$zlib_modulemap"
    -Xlinker "$zip_object"
    -Xlinker "$system_object"
    -Xlinker "$zlib_object"
    -Xlinker "$system_c_object"
    -Xlinker -rpath -Xlinker "$build_products"
)
xcrun swiftc "${swift_flags[@]}" -o "$output/reliability-checks" "${sources[@]}" "${checks[@]}"
"$output/reliability-checks"
