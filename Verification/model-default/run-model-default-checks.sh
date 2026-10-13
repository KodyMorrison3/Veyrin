#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p .build
sources=()
while IFS= read -r -d '' source; do
    sources+=("$source")
done < <(find 'Character AI swift project' -name '*.swift' ! -name CharacterAIApp.swift -print0)
xcrun swiftc -parse-as-library -D DEBUG -swift-version 5 -strict-concurrency=complete \
    -default-isolation MainActor \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -enable-upcoming-feature InferIsolatedConformances \
    -enable-upcoming-feature GlobalActorIsolatedTypesUsability \
    -enable-upcoming-feature InferSendableFromCaptures \
    -o .build/model-default-checks "${sources[@]}" Verification/model-default/ModelDefaultChecks.swift
.build/model-default-checks
