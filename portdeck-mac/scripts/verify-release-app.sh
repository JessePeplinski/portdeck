#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "--production-zip" ]]; then
  shift
  exec "$(cd "$(dirname "$0")" && pwd)/verify-github-zip-release.sh" "$@"
fi

if [[ "${1:-}" == "--production-dmg" ]]; then
  shift
  exec "$(cd "$(dirname "$0")" && pwd)/verify-github-dmg-release.sh" "$@"
fi

script_root="$(cd "$(dirname "$0")" && pwd)"
package_root="$(cd "$script_root/.." && pwd)"
repo_root="$(cd "$package_root/.." && pwd)"
app_bundle="${1:-$package_root/.build/release-artifacts/PortDeck.app}"
node_version="24.18.0"
# shellcheck source=release-config.sh
source "$script_root/release-config.sh"

main_executable="$app_bundle/Contents/MacOS/PortDeckMac"
info_plist="$app_bundle/Contents/Info.plist"
runtime_root="$app_bundle/Contents/Resources/PortDeckRuntime"
bundled_node="$runtime_root/bin/node"
bundled_cli="$runtime_root/portdeck-cli.js"
licenses_root="$app_bundle/Contents/Resources/Licenses"
sparkle_framework="$app_bundle/Contents/Frameworks/Sparkle.framework"
sparkle_binary="$sparkle_framework/Versions/B/Sparkle"
sparkle_autoupdate="$sparkle_framework/Versions/B/Autoupdate"
sparkle_updater_app="$sparkle_framework/Versions/B/Updater.app"
sparkle_updater="$sparkle_updater_app/Contents/MacOS/Updater"
maximum_app_size_kib=112640
maximum_file_count=72

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
require_file "$licenses_root/Sparkle-LICENSE.txt"
require_executable "$sparkle_binary"
require_executable "$sparkle_autoupdate"
require_executable "$sparkle_updater"

/usr/bin/plutil -lint "$info_plist" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist")" == "PortDeckMac" ]] \
  || fail "CFBundleExecutable is not PortDeckMac"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")" == "app.portdeck.dev" ]] \
  || fail "CFBundleIdentifier is not app.portdeck.dev"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$info_plist")" == "APPL" ]] \
  || fail "CFBundlePackageType is not APPL"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$info_plist")" == "14.0" ]] \
  || fail "LSMinimumSystemVersion is not 14.0"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")" == "$marketing_version" ]] \
  || fail "CFBundleShortVersionString is not $marketing_version"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")" == "$bundle_version" ]] \
  || fail "CFBundleVersion is not $bundle_version"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :PortDeckReleaseVersion' "$info_plist")" == "$release_version" ]] \
  || fail "PortDeckReleaseVersion is not $release_version"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :PortDeckReleaseTag' "$info_plist")" == "$release_tag" ]] \
  || fail "PortDeckReleaseTag is not $release_tag"

[[ "$(/usr/bin/lipo -archs "$main_executable")" == "arm64" ]] \
  || fail "PortDeckMac is not arm64-only"
[[ "$(/usr/bin/lipo -archs "$bundled_node")" == "arm64" ]] \
  || fail "bundled Node.js is not arm64-only"
for sparkle_executable in "$sparkle_binary" "$sparkle_autoupdate" "$sparkle_updater"; do
  [[ "$(/usr/bin/lipo -archs "$sparkle_executable")" == "arm64" ]] \
    || fail "Sparkle runtime is not arm64-only: $sparkle_executable"
done
[[ "$("$bundled_node" --version)" == "v${node_version}" ]] \
  || fail "bundled Node.js is not v${node_version}"

if [[ -e "$app_bundle/Contents/Resources/ProviderRuntimes" ]]; then
  fail "provider CLIs must not be bundled in this release candidate"
fi
if [[ -e "$sparkle_framework/Versions/B/XPCServices" || -e "$sparkle_framework/XPCServices" ]]; then
  fail "non-sandbox release candidate contains Sparkle XPC services"
fi
if ! /usr/bin/otool -L "$main_executable" \
  | /usr/bin/grep -Fq '@rpath/Sparkle.framework/Versions/B/Sparkle'; then
  fail "PortDeckMac does not link Sparkle through its bundled framework rpath"
fi
if ! /usr/bin/otool -l "$main_executable" \
  | /usr/bin/grep -Fq '@executable_path/../Frameworks'; then
  fail "PortDeckMac is missing the app-bundle Frameworks rpath"
fi

app_size_kib="$(/usr/bin/du -sk "$app_bundle" | /usr/bin/awk '{print $1}')"
[[ "$app_size_kib" -le "$maximum_app_size_kib" ]] \
  || fail "bundle is ${app_size_kib} KiB; maximum is ${maximum_app_size_kib} KiB"
file_count="$(/usr/bin/find "$app_bundle" -type f | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
[[ "$file_count" -le "$maximum_file_count" ]] \
  || fail "bundle contains ${file_count} files; maximum is ${maximum_file_count}"

expected_core_files="$(/usr/bin/printf '%s\n' \
  'Contents/Info.plist' \
  'Contents/MacOS/PortDeckMac' \
  'Contents/Resources/Licenses/Node.js-LICENSE.txt' \
  'Contents/Resources/Licenses/PortDeck-Helper-THIRD-PARTY-NOTICES.txt' \
  'Contents/Resources/Licenses/PortDeck-LICENSE.txt' \
  'Contents/Resources/Licenses/Sparkle-LICENSE.txt' \
  'Contents/Resources/PortDeckRuntime/bin/node' \
  'Contents/Resources/PortDeckRuntime/portdeck-cli.js' \
  'Contents/_CodeSignature/CodeResources' | /usr/bin/sort)"
while IFS= read -r expected_core_file; do
  require_file "$app_bundle/$expected_core_file"
done <<< "$expected_core_files"
while IFS= read -r actual_file; do
  relative_file="${actual_file#"$app_bundle/"}"
  case "$relative_file" in
    Contents/Frameworks/Sparkle.framework/*) ;;
    *)
      if ! /usr/bin/printf '%s\n' "$expected_core_files" | /usr/bin/grep -Fxq "$relative_file"; then
        fail "unexpected release-candidate file $relative_file"
      fi
      ;;
  esac
done < <(/usr/bin/find "$app_bundle" -type f -print)

while IFS= read -r -d '' symlink; do
  resolved_target="$(/bin/realpath "$symlink" 2>/dev/null)" \
    || fail "release candidate contains a broken symlink: $symlink"
  case "$resolved_target" in
    "$sparkle_framework"/*) ;;
    *) fail "release candidate symlink escapes Sparkle.framework: $symlink" ;;
  esac
done < <(/usr/bin/find "$app_bundle" -type l -print0)

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
/usr/bin/codesign --verify --strict "$sparkle_autoupdate"
/usr/bin/codesign --verify --strict "$sparkle_updater_app"
/usr/bin/codesign --verify --strict "$sparkle_framework"
/usr/bin/codesign --verify --deep --strict "$app_bundle"
node_signature="$(/usr/bin/codesign -dvvv "$bundled_node" 2>&1)"
app_signature="$(/usr/bin/codesign -dvvv "$app_bundle" 2>&1)"
[[ "$node_signature" == *"Signature=adhoc"* && "$node_signature" == *"runtime"* ]] \
  || fail "bundled Node.js is not ad-hoc signed with hardened runtime"
[[ "$app_signature" == *"Signature=adhoc"* && "$app_signature" == *"runtime"* ]] \
  || fail "PortDeck.app is not ad-hoc signed with hardened runtime"
for sparkle_code in "$sparkle_autoupdate" "$sparkle_updater_app" "$sparkle_framework"; do
  sparkle_signature="$(/usr/bin/codesign -dvvv "$sparkle_code" 2>&1)"
  [[ "$sparkle_signature" == *"Signature=adhoc"* && "$sparkle_signature" == *"runtime"* ]] \
    || fail "Sparkle code is not ad-hoc signed with hardened runtime: $sparkle_code"
done
node_entitlements="$(/usr/bin/codesign -d --entitlements :- "$bundled_node" 2>&1 || true)"
[[ "$node_entitlements" == *"com.apple.security.cs.allow-jit"* ]] \
  || fail "bundled Node.js is missing its required JIT entitlement"
entitlements="$(/usr/bin/codesign -d --entitlements :- "$app_bundle" 2>&1 || true)"
[[ "$entitlements" != *"com.apple.security.app-sandbox"* ]] \
  || fail "direct-download release candidate unexpectedly enables App Sandbox"
[[ "$entitlements" == *"com.apple.security.cs.disable-library-validation"* ]] \
  || fail "ad-hoc release candidate is missing its development-only library validation exception"

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
  --filter 'RuntimeResolver|ExternalProviderCLIResolver|Vercel|degradesExternalCLIFailuresWithoutLosingProductionMetadata|ModelMapsSetupFailures|reportsCloudflareSetupStates|reportsFreshSupabaseRuntimeAuthenticationRateLimitAndFailureStates'

verification_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/portdeck-release-verify.XXXXXX")"
copied_app="$verification_root/PortDeck.app"
isolated_home="$verification_root/home"
app_pid=""

run_helper() {
  /usr/bin/env -i \
    HOME="$isolated_home" \
    CFFIXED_USER_HOME="$isolated_home" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    SHELL="/bin/zsh" \
    TMPDIR="$verification_root" \
    "$copied_app/Contents/Resources/PortDeckRuntime/bin/node" \
    "$copied_app/Contents/Resources/PortDeckRuntime/portdeck-cli.js" \
    "$@"
}

cleanup() {
  if [[ -n "$app_pid" ]] && /bin/kill -0 "$app_pid" 2>/dev/null; then
    /bin/kill "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
  fi
  /bin/rm -rf "$verification_root"
}
trap cleanup EXIT

/bin/mkdir -p "$isolated_home"
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
  if (status.schemaVersion !== "0.2") throw new Error("Unexpected schemaVersion");
  for (const field of ["groups", "unknown", "warnings"]) {
    if (!Array.isArray(status[field])) throw new Error(`${field} must be an array`);
  }
' "$verification_root/status.json"

/usr/bin/env -i \
  HOME="$isolated_home" \
  CFFIXED_USER_HOME="$isolated_home" \
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
echo "Sparkle: 2.9.4, arm64-only, unused XPC services removed"
echo "Signing: ad-hoc hardened runtime, App Sandbox disabled"
echo "Gatekeeper rejection (expected until Developer ID signing and notarization): $gatekeeper_output"
echo "Provider CLIs: external-only; missing/unsupported setup tests passed"
echo "External Local discovery: status passed"
echo "Size: ${app_size_kib} KiB across ${file_count} files"
