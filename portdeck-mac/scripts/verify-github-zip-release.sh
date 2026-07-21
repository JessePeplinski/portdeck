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

verification_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/portdeck-production-verify.XXXXXX")"
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
provider_root="$app_bundle/Contents/Resources/ProviderRuntimes"
licenses_root="$app_bundle/Contents/Resources/Licenses"
approved_icon="$app_bundle/Contents/Resources/PortDeck.icns"
manifest_path="$licenses_root/Provider-Runtime-MANIFEST.json"
notices_path="$licenses_root/Provider-Runtime-THIRD-PARTY-NOTICES.txt"

require_file "$info_plist"
require_executable "$main_executable"
require_executable "$bundled_node"
require_executable "$bundled_cli"
require_file "$approved_icon"
require_file "$licenses_root/PortDeck-LICENSE.txt"
require_file "$licenses_root/Node.js-LICENSE.txt"
require_file "$licenses_root/PortDeck-Helper-THIRD-PARTY-NOTICES.txt"
require_file "$licenses_root/Railway-LICENSE.txt"
require_file "$licenses_root/flyctl-LICENSE.txt"
require_file "$manifest_path"
require_file "$notices_path"
[[ ! -e "$app_bundle/Contents/Resources/.portdeck-source-development" ]] \
  || fail "production app enables source-development runtime fallback"

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

for native_package in bare-fs bare-path bare-url; do
  prebuild_root="$provider_root/node/node_modules/$native_package/prebuilds"
  required_prebuild="$prebuild_root/darwin-arm64/$native_package.bare"
  [[ -f "$required_prebuild" ]] \
    || fail "$native_package is missing its darwin-arm64 prebuild"
  [[ "$(/usr/bin/lipo -archs "$required_prebuild" 2>/dev/null)" == "$release_architecture" ]] \
    || fail "$native_package darwin-arm64 prebuild is not arm64-only"
  if /usr/bin/find "$prebuild_root" \
    -mindepth 1 -maxdepth 1 -type d ! -name darwin-arm64 -print -quit \
    | /usr/bin/grep -q .; then
    fail "$native_package contains a foreign-platform prebuild"
  fi
done

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
[[ "$(/usr/bin/shasum -a 256 "$licenses_root/Railway-LICENSE.txt" | /usr/bin/awk '{print $1}')" == "$railway_license_sha256" ]] \
  || fail "Railway license does not match its pinned source"
[[ "$(/usr/bin/shasum -a 256 "$licenses_root/flyctl-LICENSE.txt" | /usr/bin/awk '{print $1}')" == "$fly_license_sha256" ]] \
  || fail "flyctl license does not match its pinned source"
[[ "$(/usr/bin/shasum -a 256 "$provider_root/node/node_modules/precond/LICENSE" | /usr/bin/awk '{print $1}')" == "$precond_license_sha256" ]] \
  || fail "precond license does not match its pinned source"
require_executable "$provider_root/convex/bin/convex"
require_executable "$provider_root/supabase/bin/supabase"
require_executable "$provider_root/cloudflare/bin/wrangler"
require_executable "$provider_root/railway/bin/railway"
require_executable "$provider_root/fly/bin/flyctl"
require_executable "$provider_root/netlify/bin/netlify"

"$bundled_node" -e '
  const crypto = require("node:crypto");
  const fs = require("node:fs");
  const path = require("node:path");
  const manifest = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const installRoot = process.argv[2];
  const rootLockfile = fs.readFileSync(process.argv[3]);
  const notices = fs.readFileSync(process.argv[4], "utf8");
  const expected = {
    convex: "1.42.1",
    supabase: "2.109.1",
    wrangler: "4.111.0",
    railway: "5.26.2",
    flyctl: "0.4.71",
    netlify: "26.2.0",
  };
  if (manifest.schemaVersion !== "1") throw new Error("Unexpected runtime manifest schema");
  if (manifest.spdxLicenseListVersion !== "6.11.0") {
    throw new Error("Unexpected SPDX license-list version");
  }
  const lockfileSha256 = crypto.createHash("sha256").update(rootLockfile).digest("hex");
  if (manifest.rootLockfileSha256 !== lockfileSha256) {
    throw new Error("Runtime manifest does not match the repository lockfile");
  }
  if (!Array.isArray(manifest.packages) || manifest.packageCount !== manifest.packages.length) {
    throw new Error("Runtime package count is inconsistent");
  }
  for (const [provider, version] of Object.entries(expected)) {
    const actual = provider === "flyctl"
      ? manifest.nativeRuntimes?.flyctl?.version
      : manifest.providerVersions?.[provider];
    if (actual !== version) throw new Error(`${provider} version mismatch`);
  }
  if (manifest.nativeRuntimes?.railway?.archiveSha256 !== "816414da5f182d8ee7ed66f6cf607bf5d37f8e55d367395e8133ef321e9f8ee4") {
    throw new Error("Railway archive checksum metadata mismatch");
  }
  if (manifest.nativeRuntimes?.flyctl?.archiveSha256 !== "a89085595d7da7d4ee3a8647feb700a52702eb835591e78feae47fcd2d98bfbe") {
    throw new Error("flyctl archive checksum metadata mismatch");
  }
  const requiredPrunedPackages = new Map([
    ["@netlify/ai", "0.4.2"],
    ["fsevents", "2.3.3"],
  ]);
  for (const [name, version] of requiredPrunedPackages) {
    const entry = manifest.prunedPackages?.find((candidate) => candidate.name === name);
    if (entry?.version !== version || !entry.reason) throw new Error(`${name} prune metadata mismatch`);
  }
  if (fs.existsSync(path.join(installRoot, "node_modules", "@netlify", "ai"))) {
    throw new Error("Unlicensed @netlify/ai package was redistributed");
  }
  if (fs.existsSync(path.join(installRoot, "node_modules", "fsevents"))) {
    throw new Error("Universal fsevents package was redistributed");
  }
  for (const entry of manifest.packages) {
    const packageJson = JSON.parse(fs.readFileSync(path.join(installRoot, entry.path, "package.json"), "utf8"));
    if (packageJson.name !== entry.name || packageJson.version !== entry.version) {
      throw new Error(`Package manifest mismatch at ${entry.path}`);
    }
    if (!entry.license || entry.license === "NOASSERTION") {
      throw new Error(`Package has no audited license: ${entry.name}@${entry.version}`);
    }
    if (!Array.isArray(entry.licenseEvidence) || entry.licenseEvidence.length === 0) {
      throw new Error(`Package has no auditable license evidence: ${entry.name}@${entry.version}`);
    }
    if (!notices.includes(`${entry.name}@${entry.version}`)) {
      throw new Error(`Package is absent from third-party notices: ${entry.name}@${entry.version}`);
    }
    for (const licenseFile of entry.licenseFiles ?? []) {
      if (!fs.existsSync(path.join(installRoot, entry.path, licenseFile))) {
        throw new Error(`Missing package license evidence: ${entry.path}/${licenseFile}`);
      }
      if (!notices.includes(`--- ${licenseFile} ---`)) {
        throw new Error(`License evidence is absent from notices: ${entry.path}/${licenseFile}`);
      }
    }
    for (const evidence of entry.licenseEvidence) {
      if (evidence.kind === "package-file") {
        if (!entry.licenseFiles.includes(evidence.path)) {
          throw new Error(`Package-file evidence is inconsistent: ${entry.path}/${evidence.path}`);
        }
      } else if (evidence.kind === "spdx-text") {
        if (evidence.expression !== entry.license
          || evidence.sourcePackage !== "spdx-license-list@6.11.0"
          || !Array.isArray(evidence.licenses)
          || evidence.licenses.length === 0) {
          throw new Error(`SPDX evidence is inconsistent: ${entry.name}@${entry.version}`);
        }
        for (const license of evidence.licenses) {
          if (!license.identifier || !/^[0-9a-f]{64}$/.test(license.textSha256)) {
            throw new Error(`SPDX text metadata is invalid: ${entry.name}@${entry.version}`);
          }
          if (!notices.includes(`Canonical SPDX license text: ${license.identifier}`)
            || !notices.includes(`SHA-256: ${license.textSha256}`)) {
            throw new Error(`Canonical SPDX text is absent from notices: ${license.identifier}`);
          }
        }
      } else {
        throw new Error(`Unknown license evidence kind: ${entry.name}@${entry.version}`);
      }
    }
  }
' "$manifest_path" "$provider_root/node" "$repo_root/package-lock.json" "$notices_path"

run_provider() {
  /usr/bin/env -i \
    HOME="$isolated_home" \
    CFFIXED_USER_HOME="$isolated_home" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    CI=1 \
    NO_COLOR=1 \
    "$@"
}

[[ "$(run_provider "$provider_root/convex/bin/convex" --version)" == "$convex_version" ]]
[[ "$(run_provider "$provider_root/supabase/bin/supabase" --version)" == "$supabase_version" ]]
[[ "$(run_provider "$provider_root/cloudflare/bin/wrangler" --version)" == "$wrangler_version" ]]
[[ "$(run_provider "$provider_root/railway/bin/railway" --version)" == "railway $railway_version" ]]
run_provider "$provider_root/fly/bin/flyctl" version | /usr/bin/grep -Fq "flyctl v${fly_version}"
run_provider "$provider_root/netlify/bin/netlify" --version | /usr/bin/grep -Fq "netlify-cli/${netlify_version} darwin-arm64 node-v${node_version}"

swift test \
  --package-path "$package_root" \
  --filter 'RuntimeResolver|degradesManagedRuntimeFailuresWithoutLosingProductionMetadata|ModelMapsSetupFailures|reportsCloudflareSetupStates|reportsFreshSupabaseRuntimeAuthenticationRateLimitAndFailureStates'

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
run_helper run restart --project-id "$project_id" --json > "$verification_root/restart.json"
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
  app_pid="$(/usr/bin/pgrep -f "$main_executable" | /usr/bin/head -n 1 || true)"
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
echo "Managed provider runtimes: exact versions launched with scrubbed PATH and isolated HOME"
