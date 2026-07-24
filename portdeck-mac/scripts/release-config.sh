#!/usr/bin/env bash

# Shared, non-secret inputs for the current PortDeck direct-download beta.
release_version="${PORTDECK_RELEASE_VERSION:-0.1.0-beta.6}"
release_tag="${PORTDECK_RELEASE_TAG:-v${release_version}}"
marketing_version="${PORTDECK_MARKETING_VERSION:-0.1.0}"
bundle_version="${PORTDECK_BUNDLE_VERSION:-6}"
release_architecture="arm64"
minimum_macos_version="14.0"

approved_release_icon="$script_root/../Resources/PortDeck.icns"
approved_release_icon_sha256="86e6644078fffa4ae178c8acda6533fa622c82f8d375b5c2304bf8b4dc72fde5"

release_asset="PortDeck-${release_version}-macos-${release_architecture}.zip"
release_checksum_asset="${release_asset}.sha256"
release_dmg="PortDeck-${release_version}-macos-${release_architecture}.dmg"
release_dmg_checksum_asset="${release_dmg}.sha256"
create_dmg_version="1.3.0"

node_version="24.18.0"
node_archive="node-v${node_version}-darwin-arm64.tar.gz"
node_url="https://nodejs.org/download/release/v${node_version}/${node_archive}"
node_sha256="e1a97e14c99c803e96c7339403282ea05a499c32f8d83defe9ef5ec66f979ed1"
