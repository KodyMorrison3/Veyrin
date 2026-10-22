#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
output=$(mktemp -d /tmp/veyrin-verification.XXXXXX)
trap 'rm -rf "$output"' EXIT
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
swift_flags=(
    -parse-as-library -D DEBUG -swift-version 5 -strict-concurrency=complete
    -default-isolation MainActor
    -enable-upcoming-feature NonisolatedNonsendingByDefault
    -enable-upcoming-feature InferIsolatedConformances
    -enable-upcoming-feature GlobalActorIsolatedTypesUsability
    -enable-upcoming-feature InferSendableFromCaptures
    -I "$build_products"
    -Xcc "-fmodule-map-file=$package_build/SourcePackages/checkouts/swift-system/Sources/CSystem/include/module.modulemap"
    -Xcc "-fmodule-map-file=$package_build/Build/Intermediates.noindex/GeneratedModuleMaps/CZipArchiveZlib.modulemap"
    -Xlinker "$build_products/ZipArchive.o"
    -Xlinker "$build_products/SystemPackage.o"
    -Xlinker "$build_products/CZipArchiveZlib.o"
    -Xlinker "$package_build/Build/Intermediates.noindex/swift-system.build/Debug/CSystem-t.build/Objects-normal/arm64/Binary/CSystem.o"
    -Xlinker -rpath -Xlinker "$build_products"
)
xcrun swiftc "${swift_flags[@]}" -o "$output/reliability-checks" "${sources[@]}" "${checks[@]}"
"$output/reliability-checks"
