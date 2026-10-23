#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
build="${VEYRIN_DERIVED_DATA:-.build/VeyrinDerivedData}"
if [[ ! -d "$build/Build/Products/Debug/ZipArchive.swiftmodule" ]]; then
    mkdir -p "$(dirname "$build")"
    xcodebuild -project 'Character AI swift project.xcodeproj' -scheme 'Character AI swift project' \
        -configuration Debug -sdk macosx -destination 'generic/platform=macOS' \
        -derivedDataPath "$build" CODE_SIGNING_ALLOWED=NO build
fi
products="$build/Build/Products/Debug"
find_product() {
    local product="$1" root="$2" match
    match=$(find "$root" -type f -name "$product" -print -quit)
    if [[ -z "$match" ]]; then
        echo "error: could not find $product under $root after the Xcode build" >&2
        exit 1
    fi
    printf '%s\n' "$match"
}
zip_object=$(find_product ZipArchive.o "$build/Build")
system_object=$(find_product SystemPackage.o "$build/Build")
zlib_object=$(find_product CZipArchiveZlib.o "$build/Build")
system_c_object=$(find_product CSystem.o "$build/Build")
system_modulemap=$(find "$build/SourcePackages" -type f -path '*/Sources/CSystem/include/module.modulemap' -print -quit)
if [[ -z "$system_modulemap" ]]; then
    echo "error: could not find the swift-system CSystem module map under $build/SourcePackages" >&2
    exit 1
fi
zlib_modulemap=$(find "$build/Build" -type f -name 'CZipArchiveZlib.modulemap' -print -quit)
if [[ -z "$zlib_modulemap" ]]; then
    echo "error: could not find CZipArchiveZlib.modulemap under $build/Build" >&2
    exit 1
fi
sources=()
while IFS= read -r -d '' source; do
    sources+=("$source")
done < <(find 'Character AI swift project' -name '*.swift' ! -name CharacterAIApp.swift -print0)
swift_flags=(
    -parse-as-library -D DEBUG -swift-version 5 -strict-concurrency=complete
    -default-isolation MainActor
    -enable-upcoming-feature NonisolatedNonsendingByDefault
    -enable-upcoming-feature InferIsolatedConformances
    -enable-upcoming-feature GlobalActorIsolatedTypesUsability
    -enable-upcoming-feature InferSendableFromCaptures
    -I "$products"
    -Xcc "-fmodule-map-file=$system_modulemap"
    -Xcc "-fmodule-map-file=$zlib_modulemap"
    -Xlinker "$zip_object"
    -Xlinker "$system_object"
    -Xlinker "$zlib_object"
    -Xlinker "$system_c_object"
    -Xlinker -rpath -Xlinker "$products"
)
xcrun swiftc "${swift_flags[@]}" -o .build/profile-navigation-checks "${sources[@]}" Verification/profile-navigation/ProfileNavigationChecks.swift
.build/profile-navigation-checks
