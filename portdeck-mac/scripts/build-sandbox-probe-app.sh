#!/usr/bin/env bash
set -euo pipefail

package_root="$(cd "$(dirname "$0")/.." && pwd)"
app_bundle="$package_root/.build/sandbox-probe/PortDeck.app"
executable="$package_root/.build/release/PortDeckMac"
info_plist="$package_root/Config/Info.plist"
entitlements="$package_root/Config/PortDeck.entitlements"
signing_identity="${CODE_SIGN_IDENTITY:--}"

cd "$package_root"
swift build -c release

rm -rf "$app_bundle"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
cp "$executable" "$app_bundle/Contents/MacOS/PortDeckMac"
cp "$info_plist" "$app_bundle/Contents/Info.plist"
touch "$app_bundle/Contents/Resources/.portdeck-source-development"

codesign \
  --force \
  --options runtime \
  --sign "$signing_identity" \
  --entitlements "$entitlements" \
  "$app_bundle"

codesign --verify --deep --strict "$app_bundle"

echo "$app_bundle"
