#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
executable="$(mktemp "${TMPDIR:-/tmp/}orth-text-replacements.XXXXXX")"
trap 'rm -f "$executable"' EXIT

swiftc -swift-version 6 -parse-as-library \
    "$project_root/Sources/MacAutocorrect/CorrectionPolicy.swift" \
    "$project_root/Sources/MacAutocorrect/TypingProfile.swift" \
    "$project_root/Tests/MacAutocorrectTests/TextReplacementTests.swift" \
    -o "$executable"
"$executable"
