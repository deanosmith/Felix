#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
executable="$(mktemp "${TMPDIR:-/tmp/}felix-text-replacements.XXXXXX")"
trap 'rm -f "$executable"' EXIT

swiftc -swift-version 6 -parse-as-library \
    "$project_root/Sources/Felix/AccessibilityTextClient.swift" \
    "$project_root/Sources/Felix/ApplicationFilter.swift" \
    "$project_root/Sources/Felix/CorrectionPolicy.swift" \
    "$project_root/Sources/Felix/TypingProfile.swift" \
    "$project_root/Tests/FelixTests/TextReplacementTests.swift" \
    -o "$executable"
"$executable"
