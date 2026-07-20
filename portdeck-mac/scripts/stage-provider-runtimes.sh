#!/usr/bin/env bash
set -euo pipefail

package_root="$(cd "$(dirname "$0")/.." && pwd)"
repo_root="$(cd "$package_root/.." && pwd)"
script_root="$package_root/scripts"
# shellcheck source=release-config.sh
source "$script_root/release-config.sh"

app_bundle="${1:-}"
if [[ -z "$app_bundle" || ! -d "$app_bundle/Contents/Resources" ]]; then
  echo "usage: stage-provider-runtimes.sh <PortDeck.app>" >&2
  exit 64
fi

runtime_root="$app_bundle/Contents/Resources/PortDeckRuntime"
bundled_node="$runtime_root/bin/node"
provider_root="$app_bundle/Contents/Resources/ProviderRuntimes"
node_install_root="$provider_root/node"
licenses_root="$app_bundle/Contents/Resources/Licenses"
cache_root="$package_root/.build/release-cache"
download_root="$cache_root/provider-downloads"
extract_root="$cache_root/provider-extract"

if [[ ! -x "$bundled_node" || "$($bundled_node --version)" != "v${node_version}" ]]; then
  echo "The release app must contain bundled Node.js v${node_version} before staging providers." >&2
  exit 1
fi

verify_checksum() {
  local path="$1"
  local expected="$2"
  [[ "$(/usr/bin/shasum -a 256 "$path" | /usr/bin/awk '{print $1}')" == "$expected" ]]
}

download_verified() {
  local url="$1"
  local checksum="$2"
  local destination="$3"
  local temporary="${destination}.download"

  if [[ -f "$destination" ]] && verify_checksum "$destination" "$checksum"; then
    return
  fi
  /bin/rm -f "$destination" "$temporary"
  /usr/bin/curl --fail --location --retry 3 --output "$temporary" "$url"
  if ! verify_checksum "$temporary" "$checksum"; then
    /bin/rm -f "$temporary"
    echo "Checksum verification failed for $url" >&2
    exit 1
  fi
  /bin/mv "$temporary" "$destination"
}

extract_single_binary() {
  local archive="$1"
  local executable_name="$2"
  local destination="$3"
  local extraction_directory="$extract_root/$executable_name"

  /bin/rm -rf "$extraction_directory"
  /bin/mkdir -p "$extraction_directory"
  /usr/bin/tar -xzf "$archive" -C "$extraction_directory"

  if /usr/bin/find "$extraction_directory" -type l -print -quit | /usr/bin/grep -q .; then
    echo "$archive contains a symlink; refusing to package it." >&2
    exit 1
  fi

  local match_count
  local match
  match_count="$(/usr/bin/find "$extraction_directory" -type f -name "$executable_name" -print | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
  if [[ "$match_count" -ne 1 ]]; then
    echo "$archive does not contain exactly one $executable_name binary." >&2
    exit 1
  fi
  match="$(/usr/bin/find "$extraction_directory" -type f -name "$executable_name" -print)"
  /usr/bin/install -m 755 "$match" "$destination"
}

/bin/rm -rf "$provider_root"
/bin/mkdir -p \
  "$node_install_root" \
  "$provider_root/convex/bin" \
  "$provider_root/supabase/bin" \
  "$provider_root/cloudflare/bin" \
  "$provider_root/railway/bin" \
  "$provider_root/fly/bin" \
  "$provider_root/netlify/bin" \
  "$licenses_root" \
  "$download_root" \
  "$extract_root" \
  "$cache_root/npm-home" \
  "$cache_root/npm-cache"

# npm writes the locked dependency tree directly into the release staging app.
# No checkout node_modules tree, npm credentials, scripts, or user config are copied.
npm_bin="$(command -v npm)"
npm_bin_directory="$(cd "$(dirname "$npm_bin")" && pwd)"
npm_user_config="$cache_root/npm-user-config"
npm_global_config="$cache_root/npm-global-config"
/usr/bin/touch "$npm_user_config" "$npm_global_config"
/bin/cp "$repo_root/package.json" "$repo_root/package-lock.json" "$node_install_root/"
/usr/bin/env -i \
  HOME="$cache_root/npm-home" \
  PATH="$npm_bin_directory:/usr/bin:/bin:/usr/sbin:/sbin" \
  npm_config_cache="$cache_root/npm-cache" \
  npm_config_registry="https://registry.npmjs.org/" \
  NPM_CONFIG_USERCONFIG="$npm_user_config" \
  NPM_CONFIG_GLOBALCONFIG="$npm_global_config" \
  "$npm_bin" ci \
    --prefix "$node_install_root" \
    --omit=dev \
    --ignore-scripts \
    --workspaces=false

provider_audit="$cache_root/provider-npm-audit.json"
if ! /usr/bin/env -i \
  HOME="$cache_root/npm-home" \
  PATH="$npm_bin_directory:/usr/bin:/bin:/usr/sbin:/sbin" \
  npm_config_cache="$cache_root/npm-cache" \
  npm_config_registry="https://registry.npmjs.org/" \
  NPM_CONFIG_USERCONFIG="$npm_user_config" \
  NPM_CONFIG_GLOBALCONFIG="$npm_global_config" \
  "$npm_bin" audit \
    --prefix "$node_install_root" \
    --omit=dev \
    --workspaces=false \
    --json > "$provider_audit"; then
  : # npm audit exits nonzero for every reported severity; inspect JSON below.
fi
"$bundled_node" -e '
  const fs = require("node:fs");
  const audit = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const counts = audit.metadata?.vulnerabilities;
  if (!counts) throw new Error("npm audit did not return vulnerability metadata");
  if (counts.high > 0 || counts.critical > 0) {
    throw new Error(`Provider runtime audit found ${counts.high} high and ${counts.critical} critical vulnerabilities`);
  }
  console.log(`Provider runtime audit: ${counts.low} low, ${counts.moderate} moderate, 0 high, 0 critical`);
' "$provider_audit"
/bin/rm -f "$node_install_root/package.json" "$node_install_root/package-lock.json"

# @netlify/ai is unrelated to the two Netlify read-only commands PortDeck uses,
# and upstream publishes 0.4.2 without a license declaration or license file.
# fsevents is an optional watcher dependency with a universal upstream binary.
# Neither package is needed by the production allowlist, so do not redistribute
# them in the arm64-only app.
/bin/rm -rf "$node_install_root/node_modules/@netlify/ai"
/bin/rm -rf "$node_install_root/node_modules/fsevents"

precond_license_path="$node_install_root/node_modules/precond/LICENSE"
download_verified "$precond_license_url" "$precond_license_sha256" "$precond_license_path"

/usr/bin/install -m 755 "$script_root/provider-wrappers/convex" "$provider_root/convex/bin/convex"
/usr/bin/install -m 755 "$script_root/provider-wrappers/supabase" "$provider_root/supabase/bin/supabase"
/usr/bin/install -m 755 "$script_root/provider-wrappers/wrangler" "$provider_root/cloudflare/bin/wrangler"
/usr/bin/install -m 755 "$script_root/provider-wrappers/netlify" "$provider_root/netlify/bin/netlify"

railway_archive_path="$download_root/$railway_archive"
download_verified "$railway_url" "$railway_sha256" "$railway_archive_path"
extract_single_binary "$railway_archive_path" railway "$provider_root/railway/bin/railway"

fly_archive_path="$download_root/$fly_archive"
download_verified "$fly_url" "$fly_sha256" "$fly_archive_path"
extract_single_binary "$fly_archive_path" flyctl "$provider_root/fly/bin/flyctl"

railway_license_source="$node_install_root/node_modules/@railway/cli/LICENSE"
if [[ ! -f "$railway_license_source" ]] || ! verify_checksum "$railway_license_source" "$railway_license_sha256"; then
  echo "The locked Railway npm package is missing the expected license." >&2
  exit 1
fi
/bin/cp "$railway_license_source" "$licenses_root/Railway-LICENSE.txt"

fly_license_path="$licenses_root/flyctl-LICENSE.txt"
download_verified "$fly_license_url" "$fly_license_sha256" "$fly_license_path"

"$bundled_node" "$script_root/generate-provider-runtime-notices.mjs" \
  "$node_install_root" \
  "$repo_root/package-lock.json" \
  "$licenses_root/Provider-Runtime-THIRD-PARTY-NOTICES.txt" \
  "$licenses_root/Provider-Runtime-MANIFEST.json"

isolated_home="$cache_root/provider-smoke-home"
/bin/rm -rf "$isolated_home"
/bin/mkdir -p "$isolated_home"
run_isolated() {
  /usr/bin/env -i \
    HOME="$isolated_home" \
    CFFIXED_USER_HOME="$isolated_home" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    CI=1 \
    NO_COLOR=1 \
    "$@"
}

[[ "$(run_isolated "$provider_root/convex/bin/convex" --version)" == "$convex_version" ]]
[[ "$(run_isolated "$provider_root/supabase/bin/supabase" --version)" == "$supabase_version" ]]
[[ "$(run_isolated "$provider_root/cloudflare/bin/wrangler" --version)" == "$wrangler_version" ]]
[[ "$(run_isolated "$provider_root/railway/bin/railway" --version)" == "railway $railway_version" ]]
run_isolated "$provider_root/fly/bin/flyctl" version | /usr/bin/grep -Fq "flyctl v${fly_version}"
run_isolated "$provider_root/netlify/bin/netlify" --version | /usr/bin/grep -Fq "netlify-cli/${netlify_version} darwin-arm64 node-v${node_version}"

netlify_smoke_root="$cache_root/netlify-allowlist-smoke"
/bin/rm -rf "$netlify_smoke_root"
/bin/mkdir -p "$netlify_smoke_root"
set +e
(
  cd "$netlify_smoke_root"
  run_isolated "$provider_root/netlify/bin/netlify" sites:list --json \
    > "$netlify_smoke_root/sites.stdout" \
    2> "$netlify_smoke_root/sites.stderr"
)
sites_exit=$?
(
  cd "$netlify_smoke_root"
  run_isolated "$provider_root/netlify/bin/netlify" api listSiteDeploys \
    --data '{"site_id":"00000000-0000-0000-0000-000000000000","production":true,"per_page":1}' \
    > "$netlify_smoke_root/api.stdout" \
    2> "$netlify_smoke_root/api.stderr"
)
api_exit=$?
set -e
[[ "$sites_exit" -ne 0 && "$api_exit" -ne 0 ]]
if /usr/bin/grep -Eqi 'ERR_MODULE_NOT_FOUND|Cannot find (module|package)' \
  "$netlify_smoke_root/sites.stderr" "$netlify_smoke_root/api.stderr"; then
  echo "Pruned Netlify runtime is missing a dependency required by PortDeck's allowlist." >&2
  exit 1
fi

echo "Staged locked managed provider runtimes in $provider_root"
echo "Railway archive: $railway_url"
echo "Railway archive SHA-256: $railway_sha256"
echo "flyctl archive: $fly_url"
echo "flyctl archive SHA-256: $fly_sha256"
