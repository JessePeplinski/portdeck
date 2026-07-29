#!/usr/bin/env bash
set -euo pipefail

script_root="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=release-config.sh
source "$script_root/release-config.sh"

info_plist="${1:?usage: apply-version-metadata.sh <Info.plist>}"

set_plist_string() {
  local key="$1"
  local value="$2"
  /usr/libexec/PlistBuddy -c "Delete :${key}" "$info_plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :${key} string ${value}" "$info_plist"
}

set_plist_string CFBundleShortVersionString "$marketing_version"
set_plist_string CFBundleVersion "$bundle_version"
set_plist_string PortDeckReleaseVersion "$release_version"
set_plist_string PortDeckReleaseTag "$release_tag"
