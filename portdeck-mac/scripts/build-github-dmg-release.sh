#!/usr/bin/env bash
set -euo pipefail

package_root="$(cd "$(dirname "$0")/.." && pwd)"
script_root="$package_root/scripts"
build_root="$package_root/.build"
artifact_root="$build_root/github-release-artifacts"
final_app="${1:-$artifact_root/PortDeck.app}"
# shellcheck source=release-config.sh
source "$script_root/release-config.sh"

if [[ "${PORTDECK_APPROVE_SIGNING_AND_NOTARIZATION:-}" != "YES" ]]; then
  echo "Refusing to use signing/notarization credentials without explicit approval." >&2
  echo "After approval, set PORTDECK_APPROVE_SIGNING_AND_NOTARIZATION=YES for this command only." >&2
  exit 1
fi

signing_identity="${PORTDECK_SIGNING_IDENTITY:-}"
notary_profile="${PORTDECK_NOTARYTOOL_PROFILE:-}"
release_icon="${PORTDECK_RELEASE_ICON:-$approved_release_icon}"
create_dmg_bin="${PORTDECK_CREATE_DMG_BIN:-$(command -v create-dmg || true)}"

[[ -d "$final_app" ]] || {
  echo "Missing signed and stapled release app: $final_app" >&2
  exit 1
}
[[ -x "$create_dmg_bin" ]] || {
  echo "create-dmg is required. Install it with: brew install create-dmg" >&2
  exit 1
}
[[ -n "$signing_identity" ]] || {
  echo "PORTDECK_SIGNING_IDENTITY is required." >&2
  exit 1
}
[[ -n "$notary_profile" ]] || {
  echo "PORTDECK_NOTARYTOOL_PROFILE is required." >&2
  exit 1
}

/usr/bin/codesign --verify --deep --strict "$final_app"
xcrun stapler validate "$final_app"

dmg_staging_root="$build_root/github-dmg-staging"
dmg_source_root="$dmg_staging_root/source"
final_dmg="$artifact_root/$release_dmg"
checksum_file="$artifact_root/$release_dmg_checksum_asset"
submission_result="$artifact_root/dmg-notarization-submission.json"
submission_log="$artifact_root/dmg-notarization-log.json"

/bin/rm -rf "$dmg_staging_root"
/bin/mkdir -p "$dmg_source_root" "$artifact_root"
/usr/bin/ditto "$final_app" "$dmg_source_root/PortDeck.app"
/bin/rm -f "$final_dmg" "$checksum_file" "$submission_result" "$submission_log"

"$create_dmg_bin" \
  --volname "PortDeck ${release_version}" \
  --volicon "$release_icon" \
  --window-pos 180 120 \
  --window-size 660 360 \
  --text-size 13 \
  --icon-size 128 \
  --icon "PortDeck.app" 165 170 \
  --hide-extension "PortDeck.app" \
  --app-drop-link 495 170 \
  "$final_dmg" \
  "$dmg_source_root"

/usr/bin/codesign \
  --force \
  --timestamp \
  --sign "$signing_identity" \
  "$final_dmg"
/usr/bin/codesign --verify --strict "$final_dmg"

set +e
xcrun notarytool submit \
  "$final_dmg" \
  --keychain-profile "$notary_profile" \
  --wait \
  --timeout 60m \
  --no-progress \
  --output-format json \
  > "$submission_result"
submit_exit=$?
set -e

node_for_release="$final_app/Contents/Resources/PortDeckRuntime/bin/node"
if ! submission_id="$("$node_for_release" -e '
  const fs = require("node:fs");
  const result = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (typeof result.id !== "string" || !result.id) process.exit(1);
  process.stdout.write(result.id);
' "$submission_result")"; then
  echo "notarytool did not return a DMG submission ID; inspect $submission_result" >&2
  exit 1
fi

xcrun notarytool log \
  "$submission_id" \
  "$submission_log" \
  --keychain-profile "$notary_profile"

"$node_for_release" -e '
  const fs = require("node:fs");
  const submission = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const log = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  if (submission.status !== "Accepted") {
    throw new Error(`DMG notarization was not accepted: ${submission.status ?? "unknown"}`);
  }
  if (log.status !== "Accepted") {
    throw new Error(`DMG notarization log was not accepted: ${log.status ?? "unknown"}`);
  }
  if (Array.isArray(log.issues) && log.issues.length !== 0) {
    throw new Error(`DMG notarization log contains ${log.issues.length} issue(s)`);
  }
' "$submission_result" "$submission_log"
if [[ "$submit_exit" -ne 0 ]]; then
  echo "notarytool exited with status $submit_exit despite returning a DMG submission result." >&2
  exit 1
fi

xcrun stapler staple "$final_dmg"
xcrun stapler validate "$final_dmg"

final_sha256="$(/usr/bin/shasum -a 256 "$final_dmg" | /usr/bin/awk '{print $1}')"
/usr/bin/printf '%s  %s\n' "$final_sha256" "$release_dmg" > "$checksum_file"

"$script_root/verify-release-app.sh" --production-dmg "$final_dmg" "$checksum_file"

/bin/rm -rf "$dmg_staging_root"

echo "Built signed and notarized PortDeck DMG assets:"
echo "$final_dmg"
echo "$checksum_file"
echo "SHA-256: $final_sha256"
echo "DMG notarization submission ID: $submission_id"
