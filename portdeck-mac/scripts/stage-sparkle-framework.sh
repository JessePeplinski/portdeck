#!/usr/bin/env bash
set -euo pipefail

source_framework="${1:-}"
destination_framework="${2:-}"
architecture="${3:-arm64}"

if [[ ! -d "$source_framework" || -z "$destination_framework" ]]; then
  echo "usage: stage-sparkle-framework.sh <source-framework> <destination-framework> [architecture]" >&2
  exit 1
fi

/bin/rm -rf "$destination_framework"
/bin/mkdir -p "$(dirname "$destination_framework")"
/usr/bin/ditto "$source_framework" "$destination_framework"

# PortDeck's Developer ID build is intentionally not sandboxed. Sparkle's XPC
# services are only enabled for sandboxed apps, so remove them and development
# headers/modules from the runtime framework before any signing occurs.
/bin/rm -rf \
  "$destination_framework/Versions/B/XPCServices" \
  "$destination_framework/XPCServices" \
  "$destination_framework/Versions/B/Headers" \
  "$destination_framework/Headers" \
  "$destination_framework/Versions/B/PrivateHeaders" \
  "$destination_framework/PrivateHeaders" \
  "$destination_framework/Versions/B/Modules" \
  "$destination_framework/Modules" \
  "$destination_framework/Versions/B/_CodeSignature" \
  "$destination_framework/Versions/B/Updater.app/Contents/_CodeSignature"

sparkle_binary="$destination_framework/Versions/B/Sparkle"
autoupdate_binary="$destination_framework/Versions/B/Autoupdate"
updater_binary="$destination_framework/Versions/B/Updater.app/Contents/MacOS/Updater"

for executable in "$sparkle_binary" "$autoupdate_binary" "$updater_binary"; do
  if [[ ! -x "$executable" ]]; then
    echo "Sparkle runtime is missing executable: $executable" >&2
    exit 1
  fi

  executable_architectures="$(/usr/bin/lipo -archs "$executable")"
  if [[ "$executable_architectures" != "$architecture" ]]; then
    if [[ " $executable_architectures " != *" $architecture "* ]]; then
      echo "Sparkle executable does not contain ${architecture}: $executable" >&2
      exit 1
    fi
    thinned_executable="${executable}.${architecture}"
    /usr/bin/lipo "$executable" -thin "$architecture" -output "$thinned_executable"
    /bin/mv "$thinned_executable" "$executable"
    /bin/chmod 755 "$executable"
  fi
done

if [[ -e "$destination_framework/Versions/B/XPCServices" || -e "$destination_framework/XPCServices" ]]; then
  echo "Sparkle XPC services remain in the non-sandbox runtime framework." >&2
  exit 1
fi

echo "Staged Sparkle.framework for ${architecture}: $destination_framework"
