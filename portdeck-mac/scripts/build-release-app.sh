#!/usr/bin/env bash
set -euo pipefail

package_root="$(cd "$(dirname "$0")/.." && pwd)"
repo_root="$(cd "$package_root/.." && pwd)"
build_root="$package_root/.build"
artifact_root="$build_root/release-artifacts"
app_bundle="$artifact_root/PortDeck.app"
debug_symbols="$artifact_root/PortDeckMac.dSYM"
staging_root="$build_root/release-staging"
staging_app="$staging_root/PortDeck.app"
swift_scratch="$build_root/release-swift"
cache_root="$build_root/release-cache"

node_version="24.18.0"
node_archive="node-v${node_version}-darwin-arm64.tar.gz"
node_url="https://nodejs.org/download/release/v${node_version}/${node_archive}"
node_sha256="e1a97e14c99c803e96c7339403282ea05a499c32f8d83defe9ef5ec66f979ed1"
node_archive_path="$cache_root/$node_archive"
node_extract_root="$cache_root/node-v${node_version}-darwin-arm64"

main_executable="$staging_app/Contents/MacOS/PortDeckMac"
runtime_root="$staging_app/Contents/Resources/PortDeckRuntime"
bundled_node="$runtime_root/bin/node"
bundled_cli="$runtime_root/portdeck-cli.js"
licenses_root="$staging_app/Contents/Resources/Licenses"
node_entitlements="$package_root/Config/PortDeckNodeRelease.entitlements"

verify_node_archive() {
  local archive_path="$1"
  local actual
  actual="$(/usr/bin/shasum -a 256 "$archive_path" | /usr/bin/awk '{print $1}')"
  [[ "$actual" == "$node_sha256" ]]
}

download_node_archive() {
  local temporary_archive="$node_archive_path.download"
  /bin/rm -f "$temporary_archive"
  /usr/bin/curl --fail --location --retry 3 --output "$temporary_archive" "$node_url"
  if ! verify_node_archive "$temporary_archive"; then
    /bin/rm -f "$temporary_archive"
    echo "Downloaded Node.js archive failed SHA-256 verification." >&2
    exit 1
  fi
  /bin/mv "$temporary_archive" "$node_archive_path"
}

/bin/mkdir -p "$artifact_root" "$cache_root"
/bin/rm -rf "$staging_root"
/bin/mkdir -p "$staging_app/Contents/MacOS" "$runtime_root/bin" "$licenses_root"

if [[ -f "$node_archive_path" ]] && ! verify_node_archive "$node_archive_path"; then
  echo "Discarding cached Node.js archive with an invalid checksum." >&2
  /bin/rm -f "$node_archive_path"
fi
if [[ ! -f "$node_archive_path" ]]; then
  download_node_archive
fi
if ! verify_node_archive "$node_archive_path"; then
  echo "Cached Node.js archive failed SHA-256 verification." >&2
  exit 1
fi

/bin/rm -rf "$node_extract_root"
/bin/mkdir -p "$node_extract_root"
/usr/bin/tar -xzf "$node_archive_path" -C "$node_extract_root" --strip-components 1
if [[ ! -x "$node_extract_root/bin/node" || ! -f "$node_extract_root/LICENSE" ]]; then
  echo "The verified Node.js archive is missing bin/node or LICENSE." >&2
  exit 1
fi

swift build \
  --package-path "$package_root" \
  --scratch-path "$swift_scratch" \
  --configuration release \
  --triple arm64-apple-macosx14.0
swift_bin_path="$(swift build \
  --package-path "$package_root" \
  --scratch-path "$swift_scratch" \
  --configuration release \
  --triple arm64-apple-macosx14.0 \
  --show-bin-path)"

/bin/cp "$swift_bin_path/PortDeckMac" "$main_executable"
/bin/rm -rf "$debug_symbols"
/usr/bin/dsymutil "$main_executable" -o "$debug_symbols"
/usr/bin/strip -Sx "$main_executable"
/bin/chmod 755 "$main_executable"
/bin/cp "$package_root/Config/Info.plist" "$staging_app/Contents/Info.plist"

npm run bundle:helper --workspace portdeck-app -- \
  --outfile "$bundled_cli" \
  --notices-file "$licenses_root/PortDeck-Helper-THIRD-PARTY-NOTICES.txt"
/bin/cp "$node_extract_root/bin/node" "$bundled_node"
/usr/bin/strip -Sx "$bundled_node"
/bin/chmod 755 "$bundled_node" "$bundled_cli"
/bin/cp "$node_extract_root/LICENSE" "$licenses_root/Node.js-LICENSE.txt"
/bin/cp "$repo_root/LICENSE" "$licenses_root/PortDeck-LICENSE.txt"

if [[ "$(/usr/bin/lipo -archs "$main_executable")" != "arm64" ]]; then
  echo "PortDeckMac is not an arm64-only executable." >&2
  exit 1
fi
if [[ "$(/usr/bin/lipo -archs "$bundled_node")" != "arm64" ]]; then
  echo "Bundled Node.js is not an arm64-only executable." >&2
  exit 1
fi
main_uuid="$(/usr/bin/dwarfdump --uuid "$main_executable" | /usr/bin/awk '{print $2}')"
symbols_uuid="$(/usr/bin/dwarfdump --uuid "$debug_symbols" | /usr/bin/awk '{print $2}')"
if [[ -z "$main_uuid" || "$main_uuid" != "$symbols_uuid" ]]; then
  echo "PortDeckMac.dSYM UUID does not match the stripped executable." >&2
  exit 1
fi

/usr/bin/codesign \
  --force \
  --options runtime \
  --timestamp=none \
  --sign - \
  --entitlements "$node_entitlements" \
  "$bundled_node"
if [[ "$("$bundled_node" --version)" != "v${node_version}" ]]; then
  echo "Bundled Node.js version does not match v${node_version} after stripping and signing." >&2
  exit 1
fi
/usr/bin/codesign \
  --force \
  --options runtime \
  --timestamp=none \
  --sign - \
  "$staging_app"

/usr/bin/codesign --verify --strict "$bundled_node"
/usr/bin/codesign --verify --deep --strict "$staging_app"

/bin/rm -rf "$app_bundle"
/bin/mv "$staging_app" "$app_bundle"
/bin/rm -rf "$staging_root"

echo "Built local arm64 release candidate: $app_bundle"
echo "Debug symbols: $debug_symbols"
echo "Node.js: v${node_version}"
echo "Node.js archive: $node_url"
echo "Node.js archive SHA-256: $node_sha256"
echo "Signing: ad-hoc hardened runtime (not Gatekeeper-ready)"
