#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

swift build

app_bundle=".build/PortDeck.app"
bin_path="$(swift build --show-bin-path)"
executable="$bin_path/PortDeckMac"
sparkle_source="$bin_path/Sparkle.framework"
sparkle_framework="$app_bundle/Contents/Frameworks/Sparkle.framework"
info_plist="Config/Info.plist"
local_entitlements="Config/PortDeckLocalRelease.entitlements"

rm -rf "$app_bundle"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources" "$app_bundle/Contents/Frameworks"
cp "$executable" "$app_bundle/Contents/MacOS/PortDeckMac"
cp "$info_plist" "$app_bundle/Contents/Info.plist"
"scripts/apply-version-metadata.sh" "$app_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleIdentifier app.portdeck.dev.development" \
  "$app_bundle/Contents/Info.plist"
cp "Resources/PortDeck.icns" "$app_bundle/Contents/Resources/PortDeck.icns"
touch "$app_bundle/Contents/Resources/.portdeck-source-development"
"scripts/stage-sparkle-framework.sh" "$sparkle_source" "$sparkle_framework" arm64

/usr/bin/codesign \
  --force \
  --options runtime \
  --timestamp=none \
  --sign - \
  "$sparkle_framework/Versions/B/Autoupdate"
/usr/bin/codesign \
  --force \
  --options runtime \
  --timestamp=none \
  --sign - \
  "$sparkle_framework/Versions/B/Updater.app"
/usr/bin/codesign \
  --force \
  --options runtime \
  --timestamp=none \
  --sign - \
  "$sparkle_framework"
/usr/bin/codesign \
  --force \
  --options runtime \
  --timestamp=none \
  --sign - \
  --entitlements "$local_entitlements" \
  "$app_bundle"
/usr/bin/codesign --verify --deep --strict "$app_bundle"

pkill -x PortDeckMac 2>/dev/null || true
if (($# > 0)); then
  open -n "$app_bundle" --args "$@"
else
  open -n "$app_bundle"
fi
