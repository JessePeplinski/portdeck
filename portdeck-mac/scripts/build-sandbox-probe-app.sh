#!/usr/bin/env bash
set -euo pipefail

package_root="$(cd "$(dirname "$0")/.." && pwd)"
app_bundle="$package_root/.build/sandbox-probe/PortDeck.app"
info_plist="$package_root/Config/Info.plist"
entitlements="$package_root/Config/PortDeck.entitlements"
signing_identity="${CODE_SIGN_IDENTITY:--}"

cd "$package_root"
swift build -c release
bin_path="$(swift build -c release --show-bin-path)"
executable="$bin_path/PortDeckMac"
sparkle_source="$bin_path/Sparkle.framework"
sparkle_framework="$app_bundle/Contents/Frameworks/Sparkle.framework"

rm -rf "$app_bundle"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources" "$app_bundle/Contents/Frameworks"
cp "$executable" "$app_bundle/Contents/MacOS/PortDeckMac"
cp "$info_plist" "$app_bundle/Contents/Info.plist"
touch "$app_bundle/Contents/Resources/.portdeck-source-development"
"$package_root/scripts/stage-sparkle-framework.sh" "$sparkle_source" "$sparkle_framework" arm64

codesign \
  --force \
  --options runtime \
  --sign "$signing_identity" \
  "$sparkle_framework/Versions/B/Autoupdate"
codesign \
  --force \
  --options runtime \
  --sign "$signing_identity" \
  "$sparkle_framework/Versions/B/Updater.app"
codesign \
  --force \
  --options runtime \
  --sign "$signing_identity" \
  "$sparkle_framework"

codesign \
  --force \
  --options runtime \
  --sign "$signing_identity" \
  --entitlements "$entitlements" \
  "$app_bundle"

codesign --verify --deep --strict "$app_bundle"

echo "$app_bundle"
