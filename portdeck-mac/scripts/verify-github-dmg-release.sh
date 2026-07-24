#!/usr/bin/env bash
set -euo pipefail

package_root="$(cd "$(dirname "$0")/.." && pwd)"
script_root="$package_root/scripts"
# shellcheck source=release-config.sh
source "$script_root/release-config.sh"

release_dmg_path="${1:-}"
checksum_file="${2:-${release_dmg_path}.sha256}"

fail() {
  echo "Production DMG verification failed: $*" >&2
  exit 1
}

[[ -f "$release_dmg_path" ]] || fail "missing required file $release_dmg_path"
[[ -f "$checksum_file" ]] || fail "missing required file $checksum_file"
[[ "$(basename "$release_dmg_path")" == "$release_dmg" ]] \
  || fail "DMG name is not $release_dmg"
[[ "$(basename "$checksum_file")" == "$release_dmg_checksum_asset" ]] \
  || fail "checksum name is not $release_dmg_checksum_asset"

expected_checksum="$(/usr/bin/awk 'NR == 1 {print $1}' "$checksum_file")"
checksum_filename="$(/usr/bin/awk 'NR == 1 {print $2}' "$checksum_file")"
[[ "$checksum_filename" == "$release_dmg" ]] \
  || fail "checksum file does not name $release_dmg"
actual_checksum="$(/usr/bin/shasum -a 256 "$release_dmg_path" | /usr/bin/awk '{print $1}')"
[[ "$actual_checksum" == "$expected_checksum" ]] || fail "DMG SHA-256 does not match"

maximum_dmg_size_bytes=55000000
dmg_size_bytes="$(/usr/bin/stat -f '%z' "$release_dmg_path")"
[[ "$dmg_size_bytes" -le "$maximum_dmg_size_bytes" ]] \
  || fail "DMG is ${dmg_size_bytes} bytes; maximum is ${maximum_dmg_size_bytes} bytes"

/usr/bin/hdiutil verify "$release_dmg_path" >/dev/null || fail "hdiutil verification failed"
/usr/bin/codesign --verify --strict "$release_dmg_path" || fail "DMG signature is invalid"
dmg_signature="$(/usr/bin/codesign -dvvv "$release_dmg_path" 2>&1)"
[[ "$dmg_signature" == *"Authority=Developer ID Application:"* ]] \
  || fail "DMG is not signed with Developer ID Application"
[[ "$dmg_signature" == *"Timestamp="* && "$dmg_signature" != *"Timestamp=none"* ]] \
  || fail "DMG is missing a secure timestamp"
xcrun stapler validate "$release_dmg_path" >/dev/null || fail "DMG has no valid stapled notarization ticket"
/usr/sbin/spctl \
  --assess \
  --type open \
  --context context:primary-signature \
  --verbose=4 \
  "$release_dmg_path" >/dev/null \
  || fail "Gatekeeper rejected the DMG"

verification_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/portdeck-dmg-verify.XXXXXX")"
download_root="$verification_root/download"
mount_root="$verification_root/mount"
copied_dmg="$download_root/$release_dmg"
temporary_app="$verification_root/PortDeck.app"
temporary_zip="$verification_root/$release_asset"
temporary_zip_checksum="$verification_root/$release_checksum_asset"
mounted=0

cleanup() {
  if [[ "$mounted" -eq 1 ]]; then
    /usr/bin/hdiutil detach -quiet "$mount_root" >/dev/null 2>&1 || true
  fi
  /bin/rm -rf "$verification_root"
}
trap cleanup EXIT

/bin/mkdir -p "$download_root" "$mount_root"
/usr/bin/ditto "$release_dmg_path" "$copied_dmg"
quarantine_value="0081;$(/bin/date +%s);PortDeckDMGVerifier;"
/usr/bin/xattr -w com.apple.quarantine "$quarantine_value" "$copied_dmg"

/usr/bin/hdiutil attach \
  -readonly \
  -nobrowse \
  -noautoopen \
  -mountpoint "$mount_root" \
  "$copied_dmg" >/dev/null
mounted=1

[[ -d "$mount_root/PortDeck.app" ]] || fail "DMG does not contain PortDeck.app"
[[ -L "$mount_root/Applications" ]] || fail "DMG does not contain an Applications drop link"
[[ "$(/usr/bin/readlink "$mount_root/Applications")" == "/Applications" ]] \
  || fail "Applications drop link does not target /Applications"

visible_entries="$(/usr/bin/find "$mount_root" -mindepth 1 -maxdepth 1 ! -name '.*' -print \
  | /usr/bin/sed "s#^$mount_root/##" \
  | /usr/bin/sort)"
expected_entries="$(/usr/bin/printf '%s\n' Applications PortDeck.app | /usr/bin/sort)"
[[ "$visible_entries" == "$expected_entries" ]] || {
  echo "Unexpected visible DMG contents:" >&2
  /usr/bin/diff -u <(/usr/bin/printf '%s\n' "$expected_entries") <(/usr/bin/printf '%s\n' "$visible_entries") >&2 || true
  exit 1
}

# Repackage the app copied out of the quarantined DMG and run the complete
# production ZIP verifier. This proves the DMG contains the exact same
# self-contained, signed, stapled app lifecycle as the Homebrew/ZIP artifact.
/usr/bin/ditto "$mount_root/PortDeck.app" "$temporary_app"
/usr/bin/hdiutil detach -quiet "$mount_root"
mounted=0
/usr/bin/ditto -c -k --keepParent "$temporary_app" "$temporary_zip"
temporary_zip_sha256="$(/usr/bin/shasum -a 256 "$temporary_zip" | /usr/bin/awk '{print $1}')"
/usr/bin/printf '%s  %s\n' "$temporary_zip_sha256" "$release_asset" > "$temporary_zip_checksum"

"$script_root/verify-github-zip-release.sh" "$temporary_zip" "$temporary_zip_checksum"

echo "Verified signed and notarized PortDeck DMG: $release_dmg_path"
echo "DMG SHA-256: $actual_checksum"
echo "DMG size: ${dmg_size_bytes} bytes"
echo "Finder contents: PortDeck.app and /Applications drop link"
