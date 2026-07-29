#!/usr/bin/env bash
set -euo pipefail

package_root="$(cd "$(dirname "$0")/.." && pwd)"
script_root="$package_root/scripts"
artifact_root="$package_root/.build/github-release-artifacts"
swift_scratch="$package_root/.build/release-swift"
# shellcheck source=release-config.sh
source "$script_root/release-config.sh"

release_notes="${1:-}"
existing_appcast="${2:-}"
release_update="$artifact_root/$release_dmg"
staging_root="$package_root/.build/sparkle-appcast-staging"
output_appcast="$artifact_root/appcast-beta.xml"
sparkle_tools_root="$swift_scratch/artifacts/sparkle/Sparkle/bin"
generate_appcast="$sparkle_tools_root/generate_appcast"
generate_keys="$sparkle_tools_root/generate_keys"
sign_update="$sparkle_tools_root/sign_update"

fail() {
  echo "Sparkle appcast generation failed: $*" >&2
  exit 1
}

[[ -f "$release_update" ]] || fail "missing verified release DMG: $release_update"
[[ -f "$release_notes" ]] || fail "usage: generate-sparkle-appcast.sh <release-notes.md> [existing-appcast.xml]"
[[ "$sparkle_public_ed_key" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
  || fail "pinned Sparkle public key is invalid"
for tool in "$generate_appcast" "$generate_keys" "$sign_update"; do
  [[ -x "$tool" ]] || fail "missing Sparkle ${sparkle_version} tool: $tool"
done

keychain_public_key="$("$generate_keys" --account "$sparkle_keychain_account" -p)"
[[ "$keychain_public_key" == "$sparkle_public_ed_key" ]] \
  || fail "Keychain Sparkle key does not match the pinned public key"

/bin/rm -rf "$staging_root"
/bin/mkdir -p "$staging_root"
/usr/bin/ditto "$release_update" "$staging_root/$release_dmg"
/bin/cp "$release_notes" "$staging_root/${release_dmg%.dmg}.md"
if [[ -n "$existing_appcast" ]]; then
  [[ -f "$existing_appcast" ]] || fail "existing appcast does not exist: $existing_appcast"
  /bin/cp "$existing_appcast" "$staging_root/appcast-beta.xml"
fi

"$generate_appcast" \
  --account "$sparkle_keychain_account" \
  --download-url-prefix "https://github.com/JessePeplinski/portdeck/releases/download/${release_tag}/" \
  --embed-release-notes \
  --link "https://portdeck.vercel.app/" \
  --maximum-versions 3 \
  --maximum-deltas 0 \
  --versions "$bundle_version" \
  -o "$staging_root/appcast-beta.xml" \
  "$staging_root"

"$script_root/normalize-sparkle-appcast.mjs" \
  "$staging_root/appcast-beta.xml" \
  "$bundle_version" \
  "$release_version"
"$sign_update" \
  --account "$sparkle_keychain_account" \
  --disable-signing-warning \
  "$staging_root/appcast-beta.xml"
"$sign_update" \
  --account "$sparkle_keychain_account" \
  --verify \
  "$staging_root/appcast-beta.xml"
/usr/bin/xmllint --noout "$staging_root/appcast-beta.xml"

/bin/cp "$staging_root/appcast-beta.xml" "$output_appcast"
echo "Generated signed PortDeck beta appcast: $output_appcast"
echo "Enclosure: https://github.com/JessePeplinski/portdeck/releases/download/${release_tag}/${release_dmg}"
