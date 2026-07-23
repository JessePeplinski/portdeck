#!/usr/bin/env bash

# Shared, non-secret inputs for the current PortDeck direct-download beta.
release_version="${PORTDECK_RELEASE_VERSION:-0.1.0-beta.3}"
release_tag="${PORTDECK_RELEASE_TAG:-v${release_version}}"
marketing_version="${PORTDECK_MARKETING_VERSION:-0.1.0}"
bundle_version="${PORTDECK_BUNDLE_VERSION:-3}"
release_architecture="arm64"
minimum_macos_version="14.0"

approved_release_icon="$script_root/../Resources/PortDeck.icns"
approved_release_icon_sha256="bdcb7d784f6bd363166a8d0d4a65c17fa8ecd1dfb2e65d47bba3a0f028fe4970"

release_asset="PortDeck-${release_version}-macos-${release_architecture}.zip"
release_checksum_asset="${release_asset}.sha256"

node_version="24.18.0"
node_archive="node-v${node_version}-darwin-arm64.tar.gz"
node_url="https://nodejs.org/download/release/v${node_version}/${node_archive}"
node_sha256="e1a97e14c99c803e96c7339403282ea05a499c32f8d83defe9ef5ec66f979ed1"
