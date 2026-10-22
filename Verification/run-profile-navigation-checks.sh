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
    -Xcc "-fmodule-map-file=$build/SourcePackages/checkouts/swift-system/Sources/CSystem/include/module.modulemap"
    -Xcc "-fmodule-map-file=$build/Build/Intermediates.noindex/GeneratedModuleMaps/CZipArchiveZlib.modulemap"
    -Xlinker "$products/ZipArchive.o"
    -Xlinker "$products/SystemPackage.o"
    -Xlinker "$products/CZipArchiveZlib.o"
    -Xlinker "$build/Build/Intermediates.noindex/swift-system.build/Debug/CSystem-t.build/Objects-normal/arm64/Binary/CSystem.o"
    -Xlinker -rpath -Xlinker "$products"
)
xcrun swiftc "${swift_flags[@]}" -o .build/profile-navigation-checks "${sources[@]}" Verification/profile-navigation/ProfileNavigationChecks.swift
.build/profile-navigation-checks
