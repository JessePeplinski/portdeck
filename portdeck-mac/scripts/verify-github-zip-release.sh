#!/usr/bin/env bash
set -euo pipefail

package_root="$(cd "$(dirname "$0")/.." && pwd)"
repo_root="$(cd "$package_root/.." && pwd)"
script_root="$package_root/scripts"
# shellcheck source=release-config.sh
source "$script_root/release-config.sh"

release_zip="${1:-}"
checksum_file="${2:-${release_zip}.sha256}"

fail() {
  echo "Production ZIP verification failed: $*" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail "missing required file $1"
}

require_executable() {
  [[ -x "$1" ]] || fail "missing required executable $1"
}

require_file "$release_zip"
require_file "$checksum_file"
[[ "$(basename "$release_zip")" == "$release_asset" ]] \
  || fail "ZIP name is not $release_asset"
[[ "$(basename "$checksum_file")" == "$release_checksum_asset" ]] \
  || fail "checksum name is not $release_checksum_asset"

expected_checksum="$(/usr/bin/awk 'NR == 1 {print $1}' "$checksum_file")"
checksum_filename="$(/usr/bin/awk 'NR == 1 {print $2}' "$checksum_file")"
[[ "$checksum_filename" == "$release_asset" ]] \
  || fail "checksum file does not name $release_asset"
actual_checksum="$(/usr/bin/shasum -a 256 "$release_zip" | /usr/bin/awk '{print $1}')"
[[ "$actual_checksum" == "$expected_checksum" ]] || fail "ZIP SHA-256 does not match"
maximum_zip_size_bytes=45000000
zip_size_bytes="$(/usr/bin/stat -f '%z' "$release_zip")"
[[ "$zip_size_bytes" -le "$maximum_zip_size_bytes" ]] \
  || fail "ZIP is ${zip_size_bytes} bytes; maximum is ${maximum_zip_size_bytes} bytes"

verification_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/portdeck-production-verify.XXXXXX")"
# macOS normally provides TMPDIR with a trailing slash. Canonicalize the new
# directory once so later realpath-based symlink containment comparisons use
# the same path representation.
verification_root="$(/bin/realpath "$verification_root")"
download_root="$verification_root/download"
extract_root="$verification_root/extracted"
copied_zip="$download_root/$release_asset"
app_bundle="$extract_root/PortDeck.app"
isolated_home="$verification_root/home"
state_directory="$verification_root/state"
project_directory="$verification_root/project"
app_pid=""
open_pid=""
project_id="production-release-fixture"

run_helper() {
  /usr/bin/env -i \
    HOME="$isolated_home" \
    CFFIXED_USER_HOME="$isolated_home" \
    PORTDECK_STATE_DIR="$state_directory" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    SHELL="/bin/zsh" \
    TMPDIR="$verification_root" \
    "$bundled_node" \
    "$bundled_cli" \
    "$@"
}

cleanup() {
  if [[ -x "${bundled_node:-}" && -f "${bundled_cli:-}" ]]; then
    run_helper run stop --project-id "$project_id" --json >/dev/null 2>&1 || true
  fi
  if [[ -n "$app_pid" ]] && /bin/kill -0 "$app_pid" 2>/dev/null; then
    /bin/kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
  if [[ -n "$open_pid" ]] && /bin/kill -0 "$open_pid" 2>/dev/null; then
    /bin/kill "$open_pid" 2>/dev/null || true
    wait "$open_pid" 2>/dev/null || true
  fi
  /bin/rm -rf "$verification_root"
}
trap cleanup EXIT

/bin/mkdir -p "$download_root" "$extract_root" "$isolated_home" "$state_directory" "$project_directory"
/usr/bin/ditto "$release_zip" "$copied_zip"
quarantine_value="0081;$(/bin/date +%s);PortDeckReleaseVerifier;"
/usr/bin/xattr -w com.apple.quarantine "$quarantine_value" "$copied_zip"
/usr/bin/ditto -x -k "$copied_zip" "$extract_root"

top_level_count="$(/usr/bin/find "$extract_root" -mindepth 1 -maxdepth 1 -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
[[ "$top_level_count" -eq 1 && -d "$app_bundle" ]] \
  || fail "ZIP must contain only PortDeck.app at its top level"
if ! /usr/bin/xattr -p com.apple.quarantine "$app_bundle" >/dev/null 2>&1; then
  /usr/bin/xattr -w com.apple.quarantine "$quarantine_value" "$app_bundle"
fi

info_plist="$app_bundle/Contents/Info.plist"
main_executable="$app_bundle/Contents/MacOS/PortDeckMac"
runtime_root="$app_bundle/Contents/Resources/PortDeckRuntime"
bundled_node="$runtime_root/bin/node"
bundled_cli="$runtime_root/portdeck-cli.js"
licenses_root="$app_bundle/Contents/Resources/Licenses"
approved_icon="$app_bundle/Contents/Resources/PortDeck.icns"

require_file "$info_plist"
require_executable "$main_executable"
require_executable "$bundled_node"
require_executable "$bundled_cli"
require_file "$approved_icon"
require_file "$licenses_root/PortDeck-LICENSE.txt"
require_file "$licenses_root/Node.js-LICENSE.txt"
require_file "$licenses_root/PortDeck-Helper-THIRD-PARTY-NOTICES.txt"
[[ ! -e "$app_bundle/Contents/Resources/.portdeck-source-development" ]] \
  || fail "production app enables source-development runtime fallback"
[[ ! -e "$app_bundle/Contents/Resources/ProviderRuntimes" ]] \
  || fail "production app bundles provider CLIs"

/usr/bin/plutil -lint "$info_plist" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist")" == "PortDeckMac" ]] \
  || fail "CFBundleExecutable is not PortDeckMac"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")" == "app.portdeck.dev" ]] \
  || fail "CFBundleIdentifier is not app.portdeck.dev"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$info_plist")" == "APPL" ]] \
  || fail "CFBundlePackageType is not APPL"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$info_plist")" == "$minimum_macos_version" ]] \
  || fail "LSMinimumSystemVersion is not $minimum_macos_version"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")" == "$marketing_version" ]] \
  || fail "CFBundleShortVersionString is not $marketing_version"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")" == "$bundle_version" ]] \
  || fail "CFBundleVersion is not $bundle_version"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$info_plist")" == "PortDeck.icns" ]] \
  || fail "CFBundleIconFile is not PortDeck.icns"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :PortDeckReleaseVersion' "$info_plist")" == "$release_version" ]] \
  || fail "PortDeckReleaseVersion is not $release_version"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :PortDeckReleaseTag' "$info_plist")" == "$release_tag" ]] \
  || fail "PortDeckReleaseTag is not $release_tag"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :PortDeckReleaseArchitecture' "$info_plist")" == "$release_architecture" ]] \
  || fail "PortDeckReleaseArchitecture is not $release_architecture"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :PortDeckNodeVersion' "$info_plist")" == "$node_version" ]] \
  || fail "PortDeckNodeVersion is not $node_version"

approved_icon_sha256="$(/usr/libexec/PlistBuddy -c 'Print :PortDeckApprovedIconSHA256' "$info_plist")"
[[ "$approved_icon_sha256" =~ ^[0-9a-f]{64}$ ]] || fail "approved icon checksum metadata is invalid"
[[ "$(/usr/bin/shasum -a 256 "$approved_icon" | /usr/bin/awk '{print $1}')" == "$approved_icon_sha256" ]] \
  || fail "production icon does not match its approved checksum"
/usr/bin/iconutil --convert iconset --output "$verification_root/PortDeck.iconset" "$approved_icon" >/dev/null

maximum_app_size_kib=112640
maximum_file_count=9
app_size_kib="$(/usr/bin/du -sk "$app_bundle" | /usr/bin/awk '{print $1}')"
[[ "$app_size_kib" -le "$maximum_app_size_kib" ]] \
  || fail "bundle is ${app_size_kib} KiB; maximum is ${maximum_app_size_kib} KiB"
file_count="$(/usr/bin/find "$app_bundle" -type f | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
[[ "$file_count" -le "$maximum_file_count" ]] \
  || fail "bundle contains ${file_count} files; maximum is ${maximum_file_count}"

expected_files="$(/usr/bin/printf '%s\n' \
  'Contents/Info.plist' \
  'Contents/MacOS/PortDeckMac' \
  'Contents/Resources/Licenses/Node.js-LICENSE.txt' \
  'Contents/Resources/Licenses/PortDeck-Helper-THIRD-PARTY-NOTICES.txt' \
  'Contents/Resources/Licenses/PortDeck-LICENSE.txt' \
  'Contents/Resources/PortDeck.icns' \
  'Contents/Resources/PortDeckRuntime/bin/node' \
  'Contents/Resources/PortDeckRuntime/portdeck-cli.js' \
  'Contents/_CodeSignature/CodeResources' | /usr/bin/sort)"
actual_files="$(/usr/bin/find "$app_bundle" -type f -print | /usr/bin/sed "s#^$app_bundle/##" | /usr/bin/sort)"
[[ "$actual_files" == "$expected_files" ]] || {
  echo "Unexpected production app file set:" >&2
  /usr/bin/diff -u <(/usr/bin/printf '%s\n' "$expected_files") <(/usr/bin/printf '%s\n' "$actual_files") >&2 || true
  exit 1
}

if /usr/bin/find "$app_bundle" -type f \( -name '.env' -o -name '.env.*' \) -print -quit | /usr/bin/grep -q .; then
  fail "bundle contains an .env file"
fi
if /usr/bin/find "$app_bundle" -type d \( \
  -name '.convex' -o -name '.supabase' -o -name '.wrangler' -o \
  -name '.railway' -o -name '.fly' -o -name '.netlify' \
\) -print -quit | /usr/bin/grep -q .; then
  fail "bundle contains a provider auth/state directory"
fi
if /usr/bin/find "$app_bundle" -type f \( \
  -iname 'credentials' -o -iname 'credentials.json' -o -iname '*auth-store*' -o \
  -iname '.netrc' -o -iname '.git-credentials' -o -iname '.npmrc' -o -iname 'auth.json' \
\) -print -quit | /usr/bin/grep -q .; then
  fail "bundle contains a credential or auth-store file"
fi
while IFS= read -r -d '' symlink; do
  resolved_target="$(/bin/realpath "$symlink" 2>/dev/null)" \
    || fail "bundle contains a broken symlink: $symlink"
  case "$resolved_target" in
    "$app_bundle"/*) ;;
    *) fail "bundle symlink escapes PortDeck.app: $symlink" ;;
  esac
done < <(/usr/bin/find "$app_bundle" -type l -print0)

for forbidden_path in "$repo_root" "$HOME"; do
  if LC_ALL=C /usr/bin/grep -aRF -- "$forbidden_path" "$app_bundle" >/dev/null 2>&1; then
    fail "bundle contains builder-specific path $forbidden_path"
  fi
done

"$bundled_node" "$script_root/scan-release-bundle.mjs" "$app_bundle" \
  || fail "bundle secret scan failed"

macho_count=0
outer_signature_details="$(/usr/bin/codesign -dvvv "$app_bundle" 2>&1)"
[[ "$outer_signature_details" == *"Authority=Developer ID Application:"* ]] \
  || fail "PortDeck.app is not signed with Developer ID Application"
[[ "$outer_signature_details" == *"runtime"* ]] || fail "PortDeck.app is missing hardened runtime"
[[ "$outer_signature_details" == *"Timestamp="* && "$outer_signature_details" != *"Timestamp=none"* ]] \
  || fail "PortDeck.app is missing a secure timestamp"
outer_team="$(/usr/bin/printf '%s\n' "$outer_signature_details" | /usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}')"
[[ -n "$outer_team" && "$outer_team" != "not set" ]] || fail "PortDeck.app has no signing team"

while IFS= read -r -d '' candidate; do
  if ! /usr/bin/file -b "$candidate" | /usr/bin/grep -q 'Mach-O'; then
    continue
  fi
  macho_count=$((macho_count + 1))
  [[ "$(/usr/bin/lipo -archs "$candidate")" == "$release_architecture" ]] \
    || fail "bundled Mach-O is not arm64-only: $candidate"
  /usr/bin/codesign --verify --strict "$candidate" \
    || fail "invalid nested signature: $candidate"
  signature_details="$(/usr/bin/codesign -dvvv "$candidate" 2>&1)"
  [[ "$signature_details" == *"Authority=Developer ID Application:"* ]] \
    || fail "nested Mach-O is not Developer ID signed: $candidate"
  [[ "$signature_details" == *"runtime"* ]] \
    || fail "nested Mach-O is missing hardened runtime: $candidate"
  [[ "$signature_details" == *"Timestamp="* && "$signature_details" != *"Timestamp=none"* ]] \
    || fail "nested Mach-O is missing a secure timestamp: $candidate"
  nested_team="$(/usr/bin/printf '%s\n' "$signature_details" | /usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}')"
  [[ "$nested_team" == "$outer_team" ]] || fail "nested Mach-O signing team does not match the app"

  nested_entitlements="$(/usr/bin/codesign -d --entitlements :- "$candidate" 2>&1 || true)"
  [[ "$nested_entitlements" != *"com.apple.security.app-sandbox"* ]] \
    || fail "nested Mach-O unexpectedly enables App Sandbox: $candidate"
  [[ "$nested_entitlements" != *"com.apple.security.get-task-allow"* ]] \
    || fail "nested Mach-O contains get-task-allow: $candidate"
  if [[ "$candidate" == "$bundled_node" ]]; then
    [[ "$nested_entitlements" == *"com.apple.security.cs.allow-jit"* ]] \
      || fail "bundled Node.js is missing allow-jit"
  else
    [[ "$nested_entitlements" != *"com.apple.security.cs.allow-jit"* ]] \
      || fail "allow-jit is present on a non-Node executable: $candidate"
  fi
done < <(/usr/bin/find "$app_bundle/Contents" -type f -print0)
[[ "$macho_count" -gt 0 ]] || fail "bundle contains no Mach-O executables"

/usr/bin/codesign --verify --deep --strict "$app_bundle"
outer_entitlements="$(/usr/bin/codesign -d --entitlements :- "$app_bundle" 2>&1 || true)"
[[ "$outer_entitlements" != *"com.apple.security.app-sandbox"* ]] \
  || fail "direct-download app unexpectedly enables App Sandbox"
[[ "$outer_entitlements" != *"com.apple.security.get-task-allow"* ]] \
  || fail "direct-download app contains get-task-allow"

xcrun stapler validate "$app_bundle" >/dev/null \
  || fail "stapled notarization ticket is invalid"
gatekeeper_output="$verification_root/gatekeeper.txt"
if ! /usr/sbin/spctl --assess --type execute --verbose=4 "$app_bundle" >"$gatekeeper_output" 2>&1; then
  /bin/cat "$gatekeeper_output" >&2
  fail "Gatekeeper rejected the quarantined app"
fi
/usr/bin/grep -Fq 'source=Notarized Developer ID' "$gatekeeper_output" \
  || fail "Gatekeeper did not report a notarized Developer ID source"

[[ "$($bundled_node --version)" == "v${node_version}" ]] \
  || fail "bundled Node.js is not v${node_version}"

swift test \
  --package-path "$package_root" \
  --filter 'RuntimeResolver|ExternalProviderCLIResolver|Vercel|degradesExternalCLIFailuresWithoutLosingProductionMetadata|ModelMapsSetupFailures|reportsCloudflareSetupStates|reportsFreshSupabaseRuntimeAuthenticationRateLimitAndFailureStates'

if /usr/bin/env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" /bin/sh -c 'command -v node' >/dev/null 2>&1; then
  fail "scrubbed verification PATH still contains a system Node.js"
fi

(
  cd "$verification_root"
  run_helper status --json > "$verification_root/status.json"
)
"$bundled_node" -e '
  const fs = require("node:fs");
  const status = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (status.schemaVersion !== "0.1") throw new Error("Unexpected schemaVersion");
  for (const field of ["groups", "unknown", "warnings"]) {
    if (!Array.isArray(status[field])) throw new Error(`${field} must be an array`);
  }
' "$verification_root/status.json"

free_port() {
  "$bundled_node" -e '
    const net = require("node:net");
    const server = net.createServer();
    server.listen(0, "127.0.0.1", () => {
      console.log(server.address().port);
      server.close();
    });
  '
}

port_is_open() {
  "$bundled_node" -e '
    const net = require("node:net");
    const socket = net.createConnection({ host: "127.0.0.1", port: Number(process.argv[1]) });
    socket.setTimeout(150);
    socket.once("connect", () => { socket.destroy(); process.exit(0); });
    const fail = () => { socket.destroy(); process.exit(1); };
    socket.once("error", fail);
    socket.once("timeout", fail);
  ' "$1"
}

wait_for_port() {
  local port="$1"
  local expected="$2"
  for _ in {1..60}; do
    if port_is_open "$port"; then
      [[ "$expected" == "open" ]] && return 0
    else
      [[ "$expected" == "closed" ]] && return 0
    fi
    /bin/sleep 0.1
  done
  fail "port $port did not become $expected"
}

server_path="$project_directory/server.mjs"
/usr/bin/printf '%s\n' \
  'import http from "node:http";' \
  'const port = Number(process.argv[2]);' \
  'http.createServer((_request, response) => response.end("ok")).listen(port, "127.0.0.1");' \
  > "$server_path"
first_port="$(free_port)"
second_port="$(free_port)"
while [[ "$second_port" == "$first_port" ]]; do second_port="$(free_port)"; done

project_json="$("$bundled_node" -e '
  const quote = (value) => `\x27${value.replaceAll("\x27", "\x27\\\x27\x27")}\x27`;
  const project = {
    id: process.argv[1],
    name: "Production Release Fixture",
    path: process.argv[2],
    command: `${quote(process.argv[3])} ${quote(process.argv[4])} {port}`,
    port: Number(process.argv[5])
  };
  process.stdout.write(JSON.stringify(project));
' "$project_id" "$project_directory" "$bundled_node" "$server_path" "$first_port")"

run_helper projects save --input "$project_json" --json > "$verification_root/save.json"
run_helper run start --project-id "$project_id" --json > "$verification_root/start.json"
wait_for_port "$first_port" open
run_helper run restart --project-id "$project_id" --port "$first_port" --json > "$verification_root/restart.json"
wait_for_port "$first_port" open
run_helper run restart --project-id "$project_id" --port "$second_port" --json > "$verification_root/port-switch.json"
wait_for_port "$first_port" closed
wait_for_port "$second_port" open
run_helper run stop --project-id "$project_id" --json > "$verification_root/stop.json"
wait_for_port "$second_port" closed

for result_file in save start restart port-switch stop; do
  "$bundled_node" -e '
    const fs = require("node:fs");
    const result = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    if (!result.ok) throw new Error(result.message ?? "PortDeck action failed");
  ' "$verification_root/${result_file}.json"
done

existing_app_pids="$(/usr/bin/pgrep -x PortDeckMac || true)"
/usr/bin/env -i \
  HOME="$isolated_home" \
  CFFIXED_USER_HOME="$isolated_home" \
  PORTDECK_STATE_DIR="$state_directory" \
  PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  SHELL="/bin/zsh" \
  TMPDIR="$verification_root" \
  /usr/bin/open -n -W "$app_bundle" \
  > "$verification_root/app.stdout" \
  2> "$verification_root/app.stderr" &
open_pid=$!
for _ in {1..60}; do
  app_pid=""
  while IFS= read -r candidate_pid; do
    [[ -n "$candidate_pid" ]] || continue
    if ! /usr/bin/printf '%s\n' "$existing_app_pids" | /usr/bin/grep -Fxq "$candidate_pid"; then
      app_pid="$candidate_pid"
      break
    fi
  done < <(/usr/bin/pgrep -x PortDeckMac || true)
  if [[ -n "$app_pid" ]] && /bin/kill -0 "$app_pid" 2>/dev/null; then
    break
  fi
  /bin/sleep 0.1
done
[[ -n "$app_pid" ]] && /bin/kill -0 "$app_pid" 2>/dev/null \
  || fail "LaunchServices did not keep the quarantined extracted PortDeck.app running"
/bin/kill "$app_pid"
app_pid=""
wait "$open_pid" 2>/dev/null || true
open_pid=""

echo "Verified production GitHub ZIP: $release_zip"
echo "SHA-256: $actual_checksum"
echo "Architecture: arm64 only"
echo "Node.js: v${node_version}"
echo "Signing: Developer ID Application, hardened runtime, secure timestamps"
echo "Notarization: stapled ticket valid"
echo "Gatekeeper: accepted quarantined extracted app"
echo "External Local/Projects: status, save, start, restart, port switch, stop passed"
echo "LaunchServices: quarantined extracted PortDeck.app launch passed"
echo "Provider CLIs: external-only; no provider executables or dependencies bundled"
echo "Size: ${app_size_kib} KiB app, ${zip_size_bytes} byte ZIP"
