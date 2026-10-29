#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
configuration="${1:-release}"
app_path="$project_root/dist/Orth.app"

case "$configuration" in
    debug|release) ;;
    *) print -u2 "Configuration must be debug or release."; exit 2 ;;
esac

if /usr/bin/pgrep -f -x "$app_path/Contents/MacOS/Orth" >/dev/null; then
    print -u2 "Quit Orth from its menu bar before rebuilding."
    exit 1
fi

swift build --package-path "$project_root" --configuration "$configuration"
binary_directory="$(swift build --package-path "$project_root" --configuration "$configuration" --show-bin-path)"

mkdir -p "$app_path/Contents/MacOS"
install -m 755 "$binary_directory/Orth" "$app_path/Contents/MacOS/Orth"
install -m 644 "$project_root/Resources/Info.plist" "$app_path/Contents/Info.plist"
/usr/bin/codesign --force --sign "${ORTH_SIGNING_IDENTITY:-${MAC_AUTOCORRECT_SIGNING_IDENTITY:--}}" \
    --identifier local.deanmsmith.MacAutocorrect "$app_path"

print -r -- "Built: $app_path"