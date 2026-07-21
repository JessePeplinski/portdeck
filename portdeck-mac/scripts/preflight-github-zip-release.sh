#!/usr/bin/env bash
set -euo pipefail

script_root="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=release-config.sh
source "$script_root/release-config.sh"

signing_identity="${PORTDECK_SIGNING_IDENTITY:-}"
notary_profile="${PORTDECK_NOTARYTOOL_PROFILE:-}"
release_icon="${PORTDECK_RELEASE_ICON:-$approved_release_icon}"
approved_icon_sha256="${PORTDECK_RELEASE_ICON_SHA256:-$approved_release_icon_sha256}"
icon_preflight_root="${TMPDIR:-/tmp}/portdeck-icon-preflight.$$.iconset"
blockers=0

block() {
  printf 'BLOCKED: %s\n' "$1" >&2
  blockers=$((blockers + 1))
}

for tool in codesign curl file iconutil lipo npm plutil security shasum spctl swift xattr; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    block "required tool is unavailable: $tool"
  fi
done
for xcode_tool in notarytool stapler; do
  if ! xcrun --find "$xcode_tool" >/dev/null 2>&1; then
    block "required Xcode tool is unavailable: $xcode_tool"
  fi
done

if [[ "$approved_icon_sha256" != "$approved_release_icon_sha256" ]]; then
  block "PORTDECK_RELEASE_ICON_SHA256 does not match the pinned approved production icon"
elif [[ ! -f "$release_icon" ]]; then
  block "the approved production .icns is unavailable"
elif [[ "${release_icon##*.}" != "icns" ]]; then
  block "PORTDECK_RELEASE_ICON must point to an .icns file"
else
  actual_icon_sha256="$(/usr/bin/shasum -a 256 "$release_icon" | /usr/bin/awk '{print $1}')"
  if [[ "$actual_icon_sha256" != "$approved_icon_sha256" ]]; then
    block "the production icon does not match PORTDECK_RELEASE_ICON_SHA256"
  elif ! /usr/bin/iconutil --convert iconset --output "$icon_preflight_root" "$release_icon" >/dev/null 2>&1; then
    block "the approved production icon is not a valid .icns"
  else
    /bin/rm -rf "$icon_preflight_root"
    echo "OK: approved production icon checksum and format"
  fi
fi

developer_id_count="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/awk '/\"Developer ID Application:/{count++} END{print count+0}')"
if [[ "$developer_id_count" -eq 0 ]]; then
  block "no valid Developer ID Application identity is available in the Keychain"
elif [[ -z "$signing_identity" ]]; then
  block "set PORTDECK_SIGNING_IDENTITY to the exact Developer ID Application identity"
elif [[ "$signing_identity" != Developer\ ID\ Application:* ]]; then
  block "PORTDECK_SIGNING_IDENTITY is not a Developer ID Application identity"
elif ! /usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/grep -Fq -- "\"${signing_identity}\""; then
  block "PORTDECK_SIGNING_IDENTITY does not match a valid Keychain identity"
else
  echo "OK: requested Developer ID Application identity is available"
fi

if [[ -z "$notary_profile" ]]; then
  block "set PORTDECK_NOTARYTOOL_PROFILE to a notarytool Keychain profile"
elif /usr/bin/security find-generic-password \
  -s com.apple.gke.notary.tool \
  -a "$notary_profile" >/dev/null 2>&1; then
  echo "OK: requested notarytool Keychain profile metadata is available"
elif xcrun notarytool history \
  --keychain-profile "$notary_profile" \
  --output-format json >/dev/null 2>&1; then
  echo "OK: requested notarytool Keychain profile authenticated with Apple"
else
  block "the requested notarytool Keychain profile is unavailable or failed read-only authentication"
fi

if [[ "$release_tag" != "v${release_version}" ]]; then
  block "release tag ${release_tag} does not match release version ${release_version}"
fi

if [[ "$blockers" -ne 0 ]]; then
  printf 'PortDeck GitHub ZIP release preflight found %d blocker(s).\n' "$blockers" >&2
  exit 1
fi

echo "PortDeck GitHub ZIP release preflight passed for ${release_tag}."
