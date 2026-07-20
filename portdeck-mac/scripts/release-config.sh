#!/usr/bin/env bash

# Shared, non-secret inputs for the first PortDeck direct-download beta.
release_version="${PORTDECK_RELEASE_VERSION:-0.1.0-beta.1}"
release_tag="${PORTDECK_RELEASE_TAG:-v${release_version}}"
marketing_version="${PORTDECK_MARKETING_VERSION:-0.1.0}"
bundle_version="${PORTDECK_BUNDLE_VERSION:-1}"
release_architecture="arm64"
minimum_macos_version="14.0"

release_asset="PortDeck-${release_version}-macos-${release_architecture}.zip"
release_checksum_asset="${release_asset}.sha256"

node_version="24.18.0"
node_archive="node-v${node_version}-darwin-arm64.tar.gz"
node_url="https://nodejs.org/download/release/v${node_version}/${node_archive}"
node_sha256="e1a97e14c99c803e96c7339403282ea05a499c32f8d83defe9ef5ec66f979ed1"

convex_version="1.42.1"
supabase_version="2.109.1"
wrangler_version="4.111.0"
railway_version="5.26.2"
fly_version="0.4.71"
netlify_version="26.2.0"

railway_archive="railway-v${railway_version}-aarch64-apple-darwin.tar.gz"
railway_url="https://github.com/railwayapp/cli/releases/download/v${railway_version}/${railway_archive}"
railway_sha256="816414da5f182d8ee7ed66f6cf607bf5d37f8e55d367395e8133ef321e9f8ee4"
railway_license_sha256="4a31388aeb41f97559f349ffca253e207181f2cf9d8a713e8891509333193da7"

fly_archive="flyctl_${fly_version}_macOS_arm64.tar.gz"
fly_url="https://github.com/superfly/flyctl/releases/download/v${fly_version}/${fly_archive}"
fly_sha256="a89085595d7da7d4ee3a8647feb700a52702eb835591e78feae47fcd2d98bfbe"
fly_license_url="https://raw.githubusercontent.com/superfly/flyctl/56c828f79ca41a154d5983e22b90725da37e44f5/LICENSE"
fly_license_sha256="cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"

precond_license_url="https://raw.githubusercontent.com/MathieuTurcotte/node-precond/12f684a7afae3dd5b7530c8c54f4f0e43096134c/LICENSE"
precond_license_sha256="0e25cd31fa3090ea5b4c762537ded418128616ade20e0712bdc085e67f36e32e"
