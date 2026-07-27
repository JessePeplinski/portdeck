#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

swift build

app_bundle=".build/PortDeck.app"
executable=".build/debug/PortDeckMac"
info_plist="Config/Info.plist"

rm -rf "$app_bundle"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
cp "$executable" "$app_bundle/Contents/MacOS/PortDeckMac"
cp "$info_plist" "$app_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleIdentifier app.portdeck.dev.development" \
  "$app_bundle/Contents/Info.plist"
cp "Resources/PortDeck.icns" "$app_bundle/Contents/Resources/PortDeck.icns"
touch "$app_bundle/Contents/Resources/.portdeck-source-development"

/usr/bin/codesign \
  --force \
  --sign - \
  "$app_bundle"
/usr/bin/codesign --verify --deep --strict "$app_bundle"

pkill -x PortDeckMac 2>/dev/null || true
open -n "$app_bundle"
