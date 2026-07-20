#!/usr/bin/env bash
set -euo pipefail

package_root="$(cd "$(dirname "$0")/.." && pwd)"
script_root="$package_root/scripts"
build_root="$package_root/.build"
candidate_app="$build_root/release-artifacts/PortDeck.app"
artifact_root="$build_root/github-release-artifacts"
staging_root="$build_root/github-release-staging"
staging_app="$staging_root/PortDeck.app"
# shellcheck source=release-config.sh
source "$script_root/release-config.sh"

if [[ "${PORTDECK_APPROVE_SIGNING_AND_NOTARIZATION:-}" != "YES" ]]; then
  echo "Refusing to use signing/notarization credentials without explicit approval." >&2
  echo "After approval, set PORTDECK_APPROVE_SIGNING_AND_NOTARIZATION=YES for this command only." >&2
  exit 1
fi

"$script_root/preflight-github-zip-release.sh"

signing_identity="$PORTDECK_SIGNING_IDENTITY"
notary_profile="$PORTDECK_NOTARYTOOL_PROFILE"
release_icon="$PORTDECK_RELEASE_ICON"
approved_icon_sha256="$PORTDECK_RELEASE_ICON_SHA256"
node_entitlements="$package_root/Config/PortDeckNodeRelease.entitlements"

PORTDECK_RELEASE_VERSION="$release_version" \
  PORTDECK_RELEASE_TAG="$release_tag" \
  "$script_root/build-release-app.sh"

/bin/rm -rf "$artifact_root" "$staging_root"
/bin/mkdir -p "$artifact_root" "$staging_root"
/usr/bin/ditto "$candidate_app" "$staging_app"
/bin/rm -rf "$staging_app/Contents/_CodeSignature"

/bin/cp "$release_icon" "$staging_app/Contents/Resources/PortDeck.icns"
info_plist="$staging_app/Contents/Info.plist"

set_plist_string() {
  local key="$1"
  local value="$2"
  /usr/libexec/PlistBuddy -c "Delete :${key}" "$info_plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :${key} string ${value}" "$info_plist"
}

set_plist_string CFBundleShortVersionString "$marketing_version"
set_plist_string CFBundleVersion "$bundle_version"
set_plist_string CFBundleIconFile "PortDeck.icns"
set_plist_string PortDeckReleaseVersion "$release_version"
set_plist_string PortDeckReleaseTag "$release_tag"
set_plist_string PortDeckReleaseArchitecture "$release_architecture"
set_plist_string PortDeckNodeVersion "$node_version"
set_plist_string PortDeckApprovedIconSHA256 "$approved_icon_sha256"

"$script_root/stage-provider-runtimes.sh" "$staging_app"

main_executable="$staging_app/Contents/MacOS/PortDeckMac"
bundled_node="$staging_app/Contents/Resources/PortDeckRuntime/bin/node"

sign_macho() {
  local executable="$1"
  local architecture
  architecture="$(/usr/bin/lipo -archs "$executable")"
  if [[ "$architecture" != "$release_architecture" ]]; then
    echo "Refusing to sign non-arm64 Mach-O: $executable ($architecture)" >&2
    exit 1
  fi

  if [[ "$executable" == "$bundled_node" ]]; then
    /usr/bin/codesign \
      --force \
      --options runtime \
      --timestamp \
      --sign "$signing_identity" \
      --entitlements "$node_entitlements" \
      "$executable"
  else
    /usr/bin/codesign \
      --force \
      --options runtime \
      --timestamp \
      --sign "$signing_identity" \
      "$executable"
  fi
}

# Every nested Mach-O is signed on its own before the outer bundle. No --deep
# signing is used; --deep appears only in verification below.
macho_list="$staging_root/macho-files.txt"
: > "$macho_list"
while IFS= read -r -d '' candidate; do
  if /usr/bin/file -b "$candidate" | /usr/bin/grep -q 'Mach-O'; then
    slash_characters="${candidate//[^\/]/}"
    /usr/bin/printf '%08d\t%s\n' "${#slash_characters}" "$candidate" >> "$macho_list"
  fi
done < <(/usr/bin/find "$staging_app/Contents" -type f -print0)
while IFS=$'\t' read -r _depth candidate; do
  sign_macho "$candidate"
done < <(/usr/bin/sort -rn "$macho_list")

/usr/bin/codesign \
  --force \
  --options runtime \
  --timestamp \
  --sign "$signing_identity" \
  "$staging_app"

/usr/bin/codesign --verify --deep --strict "$staging_app"

notarization_zip="$artifact_root/.PortDeck-notarization-upload.zip"
submission_result="$artifact_root/notarization-submission.json"
submission_log="$artifact_root/notarization-log.json"
/usr/bin/ditto -c -k --keepParent "$staging_app" "$notarization_zip"

set +e
xcrun notarytool submit \
  "$notarization_zip" \
  --keychain-profile "$notary_profile" \
  --wait \
  --timeout 60m \
  --no-progress \
  --output-format json \
  > "$submission_result"
submit_exit=$?
set -e

if ! submission_id="$("$bundled_node" -e '
  const fs = require("node:fs");
  const result = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (typeof result.id !== "string" || !result.id) process.exit(1);
  process.stdout.write(result.id);
' "$submission_result")"; then
  echo "notarytool did not return a submission ID; inspect $submission_result" >&2
  exit 1
fi

xcrun notarytool log \
  "$submission_id" \
  "$submission_log" \
  --keychain-profile "$notary_profile"

"$bundled_node" -e '
  const fs = require("node:fs");
  const submission = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const log = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  if (submission.status !== "Accepted") {
    throw new Error(`Notarization was not accepted: ${submission.status ?? "unknown"}`);
  }
  if (log.status !== "Accepted") {
    throw new Error(`Notarization log was not accepted: ${log.status ?? "unknown"}`);
  }
  if (Array.isArray(log.issues) && log.issues.length !== 0) {
    throw new Error(`Notarization log contains ${log.issues.length} issue(s)`);
  }
' "$submission_result" "$submission_log"
if [[ "$submit_exit" -ne 0 ]]; then
  echo "notarytool exited with status $submit_exit despite returning a submission result." >&2
  exit 1
fi

xcrun stapler staple "$staging_app"
xcrun stapler validate "$staging_app"
/bin/rm -f "$notarization_zip"

final_app="$artifact_root/PortDeck.app"
/usr/bin/ditto "$staging_app" "$final_app"
final_zip="$artifact_root/$release_asset"
checksum_file="$artifact_root/$release_checksum_asset"
/usr/bin/ditto -c -k --keepParent "$final_app" "$final_zip"
final_sha256="$(/usr/bin/shasum -a 256 "$final_zip" | /usr/bin/awk '{print $1}')"
/usr/bin/printf '%s  %s\n' "$final_sha256" "$release_asset" > "$checksum_file"

"$script_root/verify-release-app.sh" --production-zip "$final_zip" "$checksum_file"

echo "Built signed and notarized PortDeck GitHub prerelease assets:"
echo "$final_zip"
echo "$checksum_file"
echo "SHA-256: $final_sha256"
echo "Node.js archive: $node_url"
echo "Node.js archive SHA-256: $node_sha256"
echo "Notarization submission ID: $submission_id"
