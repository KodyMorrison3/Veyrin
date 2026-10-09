#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d /tmp/veyrin-checks.XXXXXX)
trap 'rm -rf "$output"' EXIT
sources=()
while IFS= read -r -d '' source; do sources+=("$source"); done < <(find 'Character AI swift project' -name '*.swift' ! -path '*/App/CharacterAIApp.swift' -print0)
checks=()
while IFS= read -r -d '' source; do checks+=("$source"); done < <(find PerformanceChecks -name '*.swift' -print0)
xcrun swiftc -O -DDEBUG -swift-version 5 -strict-concurrency=complete -default-isolation MainActor \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -enable-upcoming-feature InferIsolatedConformances \
    -enable-upcoming-feature GlobalActorIsolatedTypesUsability \
    -enable-upcoming-feature InferSendableFromCaptures \
    -parse-as-library "${sources[@]}" "${checks[@]}" -o "$output/checks"
"$output/checks"
