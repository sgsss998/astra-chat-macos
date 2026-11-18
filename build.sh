#!/bin/bash
set -euo pipefail
shopt -s nullglob

project_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
plist="$project_dir/Resources/Info.plist"
sources=("$project_dir"/Sources/*.swift)

if [[ ! -f "$plist" || ${#sources[@]} -eq 0 ]]; then
    printf '%s\n' 'Expected Resources/Info.plist and at least one file in Sources/.' >&2
    exit 1
fi

/usr/bin/plutil -lint "$plist"
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")"
minimum_macos="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist" 2>/dev/null || printf '13.0')"
if [[ ! "$executable" =~ ^[A-Za-z0-9_-]+$ || ! "$minimum_macos" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    printf '%s\n' 'Info.plist has an invalid executable name or minimum macOS version.' >&2
    exit 1
fi

architecture="$(/usr/bin/uname -m)"
sdk="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
output_dir="$project_dir/dist"
app="$output_dir/Astra Chat.app"
mkdir -p "$output_dir"
staging_dir="$(mktemp -d "$output_dir/.build.XXXXXX")"
trap 'rm -rf -- "$staging_dir"' EXIT

staged_app="$staging_dir/Astra Chat.app"
contents="$staged_app/Contents"
mkdir -p "$contents/MacOS"
cp -- "$plist" "$contents/Info.plist"

/usr/bin/xcrun --sdk macosx swiftc \
    -sdk "$sdk" -target "$architecture-apple-macosx$minimum_macos" \
    -module-cache-path "$staging_dir/module-cache" \
    -O -parse-as-library -o "$contents/MacOS/$executable" "${sources[@]}"
/usr/bin/codesign --force --sign - --timestamp=none "$staged_app"
/usr/bin/codesign --verify --strict "$staged_app"

rm -rf -- "$app"
mv -- "$staged_app" "$app"
printf 'Built %s\n' "$app"
