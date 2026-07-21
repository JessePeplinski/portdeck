#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--production-zip" ]]; then
  shift
  exec "$(cd "$(dirname "$0")" && pwd)/verify-github-zip-release.sh" "$@"
fi

package_root="$(cd "$(dirname "$0")/.." && pwd)"
repo_root="$(cd "$package_root/.." && pwd)"
app_bundle="${1:-$package_root/.build/release-artifacts/PortDeck.app}"
node_version="24.18.0"

main_executable="$app_bundle/Contents/MacOS/PortDeckMac"
info_plist="$app_bundle/Contents/Info.plist"
runtime_root="$app_bundle/Contents/Resources/PortDeckRuntime"
bundled_node="$runtime_root/bin/node"
bundled_cli="$runtime_root/portdeck-cli.js"
licenses_root="$app_bundle/Contents/Resources/Licenses"

fail() {
  echo "Release candidate verification failed: $*" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail "missing required file $1"
}

require_executable() {
  [[ -x "$1" ]] || fail "missing required executable $1"
}

require_file "$info_plist"
require_executable "$main_executable"
require_executable "$bundled_node"
require_executable "$bundled_cli"
require_file "$licenses_root/PortDeck-LICENSE.txt"
require_file "$licenses_root/Node.js-LICENSE.txt"
require_file "$licenses_root/PortDeck-Helper-THIRD-PARTY-NOTICES.txt"

/usr/bin/plutil -lint "$info_plist" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist")" == "PortDeckMac" ]] \
  || fail "CFBundleExecutable is not PortDeckMac"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")" == "app.portdeck.dev" ]] \
  || fail "CFBundleIdentifier is not app.portdeck.dev"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$info_plist")" == "APPL" ]] \
  || fail "CFBundlePackageType is not APPL"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$info_plist")" == "14.0" ]] \
  || fail "LSMinimumSystemVersion is not 14.0"
[[ -n "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")" ]] \
  || fail "CFBundleShortVersionString is empty"
[[ -n "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")" ]] \
  || fail "CFBundleVersion is empty"

[[ "$(/usr/bin/lipo -archs "$main_executable")" == "arm64" ]] \
  || fail "PortDeckMac is not arm64-only"
[[ "$(/usr/bin/lipo -archs "$bundled_node")" == "arm64" ]] \
  || fail "bundled Node.js is not arm64-only"
[[ "$("$bundled_node" --version)" == "v${node_version}" ]] \
  || fail "bundled Node.js is not v${node_version}"

if /usr/bin/find "$app_bundle" -type l -print -quit | /usr/bin/grep -q .; then
  fail "the release candidate contains a symlink"
fi
if [[ -e "$app_bundle/Contents/Resources/ProviderRuntimes" ]]; then
  fail "managed provider runtimes must not be bundled in this release candidate"
fi

expected_files="$(/usr/bin/printf '%s\n' \
  'Contents/Info.plist' \
  'Contents/MacOS/PortDeckMac' \
  'Contents/Resources/Licenses/Node.js-LICENSE.txt' \
  'Contents/Resources/Licenses/PortDeck-Helper-THIRD-PARTY-NOTICES.txt' \
  'Contents/Resources/Licenses/PortDeck-LICENSE.txt' \
  'Contents/Resources/PortDeckRuntime/bin/node' \
  'Contents/Resources/PortDeckRuntime/portdeck-cli.js' \
  'Contents/_CodeSignature/CodeResources' | /usr/bin/sort)"
actual_files="$(/usr/bin/find "$app_bundle" -type f -print | /usr/bin/sed "s#^$app_bundle/##" | /usr/bin/sort)"
[[ "$actual_files" == "$expected_files" ]] || {
  echo "Unexpected release-candidate file set:" >&2
  /usr/bin/diff -u <(/usr/bin/printf '%s\n' "$expected_files") <(/usr/bin/printf '%s\n' "$actual_files") >&2 || true
  exit 1
}

for forbidden_path in "$repo_root" "$HOME"; do
  if LC_ALL=C /usr/bin/grep -aRF -- "$forbidden_path" "$app_bundle" >/dev/null 2>&1; then
    fail "bundle contains builder-specific path $forbidden_path"
  fi
done
if LC_ALL=C /usr/bin/grep -aER -- \
  '-----BEGIN ([A-Z ]+ )?PRIVATE KEY-----|github_pat_[A-Za-z0-9_]{20,}|ghp_[A-Za-z0-9]{20,}|sk_live_[A-Za-z0-9]{16,}|xox[baprs]-[A-Za-z0-9-]{10,}' \
  "$app_bundle" >/dev/null 2>&1; then
  fail "bundle contains a credential-shaped value"
fi

/usr/bin/codesign --verify --strict "$bundled_node"
/usr/bin/codesign --verify --deep --strict "$app_bundle"
node_signature="$(/usr/bin/codesign -dvvv "$bundled_node" 2>&1)"
app_signature="$(/usr/bin/codesign -dvvv "$app_bundle" 2>&1)"
[[ "$node_signature" == *"Signature=adhoc"* && "$node_signature" == *"runtime"* ]] \
  || fail "bundled Node.js is not ad-hoc signed with hardened runtime"
[[ "$app_signature" == *"Signature=adhoc"* && "$app_signature" == *"runtime"* ]] \
  || fail "PortDeck.app is not ad-hoc signed with hardened runtime"
node_entitlements="$(/usr/bin/codesign -d --entitlements :- "$bundled_node" 2>&1 || true)"
[[ "$node_entitlements" == *"com.apple.security.cs.allow-jit"* ]] \
  || fail "bundled Node.js is missing its required JIT entitlement"
entitlements="$(/usr/bin/codesign -d --entitlements :- "$app_bundle" 2>&1 || true)"
[[ "$entitlements" != *"com.apple.security.app-sandbox"* ]] \
  || fail "direct-download release candidate unexpectedly enables App Sandbox"

gatekeeper_output_file="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/portdeck-spctl.XXXXXX")"
if /usr/sbin/spctl --assess --type execute --verbose=4 "$app_bundle" >"$gatekeeper_output_file" 2>&1; then
  /bin/cat "$gatekeeper_output_file" >&2
  /bin/rm -f "$gatekeeper_output_file"
  fail "Gatekeeper unexpectedly accepted the ad-hoc release candidate"
fi
gatekeeper_output="$(/bin/cat "$gatekeeper_output_file")"
/bin/rm -f "$gatekeeper_output_file"

swift test \
  --package-path "$package_root" \
  --filter 'RuntimeResolver|Vercel|degradesManagedRuntimeFailuresWithoutLosingProductionMetadata|ModelMapsSetupFailures|reportsCloudflareSetupStates|reportsFreshSupabaseRuntimeAuthenticationRateLimitAndFailureStates'

verification_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/portdeck-release-verify.XXXXXX")"
copied_app="$verification_root/PortDeck.app"
isolated_home="$verification_root/home"
state_directory="$verification_root/state"
project_directory="$verification_root/project"
app_pid=""
project_id="release-candidate-fixture"

run_helper() {
  /usr/bin/env -i \
    HOME="$isolated_home" \
    CFFIXED_USER_HOME="$isolated_home" \
    PORTDECK_STATE_DIR="$state_directory" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    SHELL="/bin/zsh" \
    TMPDIR="$verification_root" \
    "$copied_app/Contents/Resources/PortDeckRuntime/bin/node" \
    "$copied_app/Contents/Resources/PortDeckRuntime/portdeck-cli.js" \
    "$@"
}

cleanup() {
  if [[ -x "$copied_app/Contents/Resources/PortDeckRuntime/bin/node" ]]; then
    run_helper run stop --project-id "$project_id" --json >/dev/null 2>&1 || true
  fi
  if [[ -n "$app_pid" ]] && /bin/kill -0 "$app_pid" 2>/dev/null; then
    /bin/kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
  /bin/rm -rf "$verification_root"
}
trap cleanup EXIT

/bin/mkdir -p "$isolated_home" "$state_directory" "$project_directory"
/bin/cp -R "$app_bundle" "$copied_app"
copied_node="$copied_app/Contents/Resources/PortDeckRuntime/bin/node"

if /usr/bin/env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" /bin/sh -c 'command -v node' >/dev/null 2>&1; then
  fail "scrubbed verification PATH still contains a system Node.js"
fi

(
  cd "$verification_root"
  run_helper status --json > "$verification_root/status.json"
)
"$copied_node" -e '
  const fs = require("node:fs");
  const status = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (status.schemaVersion !== "0.1") throw new Error("Unexpected schemaVersion");
  for (const field of ["groups", "unknown", "warnings"]) {
    if (!Array.isArray(status[field])) throw new Error(`${field} must be an array`);
  }
' "$verification_root/status.json"

free_port() {
  "$copied_node" -e '
    const net = require("node:net");
    const server = net.createServer();
    server.listen(0, "127.0.0.1", () => {
      console.log(server.address().port);
      server.close();
    });
  '
}

port_is_open() {
  "$copied_node" -e '
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

project_json="$("$copied_node" -e '
  const quote = (value) => `\x27${value.replaceAll("\x27", "\x27\\\x27\x27")}\x27`;
  const project = {
    id: process.argv[1],
    name: "Release Candidate Fixture",
    path: process.argv[2],
    command: `${quote(process.argv[3])} ${quote(process.argv[4])} {port}`,
    port: Number(process.argv[5])
  };
  process.stdout.write(JSON.stringify(project));
' "$project_id" "$project_directory" "$copied_node" "$server_path" "$first_port")"

run_helper projects save --input "$project_json" --json > "$verification_root/save.json"
run_helper run start --project-id "$project_id" --json > "$verification_root/start.json"
wait_for_port "$first_port" open
run_helper run restart --project-id "$project_id" --port "$second_port" --json > "$verification_root/restart.json"
wait_for_port "$first_port" closed
wait_for_port "$second_port" open
run_helper run stop --project-id "$project_id" --json > "$verification_root/stop.json"
wait_for_port "$second_port" closed

for result_file in save start restart stop; do
  "$copied_node" -e '
    const fs = require("node:fs");
    const result = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    if (!result.ok) throw new Error(result.message ?? "PortDeck action failed");
  ' "$verification_root/${result_file}.json"
done

/usr/bin/env -i \
  HOME="$isolated_home" \
  CFFIXED_USER_HOME="$isolated_home" \
  PORTDECK_STATE_DIR="$state_directory" \
  PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  SHELL="/bin/zsh" \
  TMPDIR="$verification_root" \
  "$copied_app/Contents/MacOS/PortDeckMac" \
  > "$verification_root/app.stdout" \
  2> "$verification_root/app.stderr" &
app_pid=$!
/bin/sleep 3
/bin/kill -0 "$app_pid" 2>/dev/null || fail "copied PortDeck.app did not remain running"
/bin/kill "$app_pid"
wait "$app_pid" 2>/dev/null || true
app_pid=""

echo "Verified local arm64 release candidate: $app_bundle"
echo "Node.js: v${node_version}"
echo "Main executable architecture: $(/usr/bin/lipo -archs "$main_executable")"
echo "Node architecture: $(/usr/bin/lipo -archs "$bundled_node")"
echo "Signing: ad-hoc hardened runtime, App Sandbox disabled"
echo "Gatekeeper rejection (expected until Developer ID signing and notarization): $gatekeeper_output"
echo "Managed provider runtimes: intentionally absent; unavailable/degraded source tests passed"
