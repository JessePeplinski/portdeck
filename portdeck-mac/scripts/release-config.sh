#!/usr/bin/env bash

# Shared, non-secret inputs for the current PortDeck direct-download beta.
release_version="${PORTDECK_RELEASE_VERSION:-0.1.0-beta.13}"
release_tag="${PORTDECK_RELEASE_TAG:-v${release_version}}"
marketing_version="${PORTDECK_MARKETING_VERSION:-0.1.0}"
bundle_version="${PORTDECK_BUNDLE_VERSION:-13}"
release_architecture="arm64"
minimum_macos_version="14.0"

approved_release_icon="$script_root/../Resources/PortDeck.icns"
approved_release_icon_sha256="72b0c4231531d774b8f1ad28cdd18f2bd6745da2838d4985c34df55622c4af14"

release_asset="PortDeck-${release_version}-macos-${release_architecture}.zip"
release_checksum_asset="${release_asset}.sha256"
release_dmg="PortDeck-${release_version}-macos-${release_architecture}.dmg"
release_dmg_checksum_asset="${release_dmg}.sha256"
create_dmg_version="1.3.0"

sparkle_version="2.9.4"
sparkle_feed_url="https://portdeck.vercel.app/appcast-beta.xml"
sparkle_keychain_account="app.portdeck.dev"
sparkle_public_ed_key="${PORTDECK_SPARKLE_PUBLIC_ED_KEY:-}"
sparkle_signed_feed_failure_expiration_interval="1728000"

node_version="24.18.0"
node_archive="node-v${node_version}-darwin-arm64.tar.gz"
node_url="https://nodejs.org/download/release/v${node_version}/${node_archive}"
node_sha256="e1a97e14c99c803e96c7339403282ea05a499c32f8d83defe9ef5ec66f979ed1"
