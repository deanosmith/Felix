#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
configuration="${1:-release}"
app_path="$project_root/dist/Felix.app"

case "$configuration" in
    debug|release) ;;
    *) print -u2 "Configuration must be debug or release."; exit 2 ;;
esac

for existing_app in "$project_root"/dist/*.app(N); do
    executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$existing_app/Contents/Info.plist")"
    if /usr/bin/pgrep -f -x "$existing_app/Contents/MacOS/$executable_name" >/dev/null; then
        print -u2 "Quit ${existing_app:t:r} from its menu bar before rebuilding."
        exit 1
    fi
done

swift build --package-path "$project_root" --configuration "$configuration"
binary_directory="$(swift build --package-path "$project_root" --configuration "$configuration" --show-bin-path)"

mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
install -m 755 "$binary_directory/Felix" "$app_path/Contents/MacOS/Felix"
install -m 644 "$project_root/Resources/Info.plist" "$app_path/Contents/Info.plist"
install -m 644 "$project_root/Resources/AppIcon.icns" "$app_path/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --force --sign "${FELIX_SIGNING_IDENTITY:--}" \
    --identifier local.deanmsmith.Felix "$app_path"

print -r -- "Built: $app_path"