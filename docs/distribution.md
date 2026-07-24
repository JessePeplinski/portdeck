# PortDeck Distribution

PortDeck's public beta is a Developer ID-signed and notarized arm64 app distributed through a drag-to-Applications DMG, a versioned ZIP, and the `portdeck@beta` Homebrew cask. The Mac App Store remains a separate feasibility track.

## Current target

The current public beta is `v0.1.0-beta.5` for Apple Silicon Macs running macOS 14 or newer:

- [`PortDeck-0.1.0-beta.5-macos-arm64.dmg`](../../../releases/download/v0.1.0-beta.5/PortDeck-0.1.0-beta.5-macos-arm64.dmg)
- [`PortDeck-0.1.0-beta.5-macos-arm64.dmg.sha256`](../../../releases/download/v0.1.0-beta.5/PortDeck-0.1.0-beta.5-macos-arm64.dmg.sha256)
- [`PortDeck-0.1.0-beta.5-macos-arm64.zip`](../../../releases/download/v0.1.0-beta.5/PortDeck-0.1.0-beta.5-macos-arm64.zip)
- [`PortDeck-0.1.0-beta.5-macos-arm64.zip.sha256`](../../../releases/download/v0.1.0-beta.5/PortDeck-0.1.0-beta.5-macos-arm64.zip.sha256)

A universal/x86_64 build, in-app updater, and App Store package are outside the current beta contract.

## Bundle boundary

The direct-download app contains only:

- the native `PortDeckMac` executable;
- the esbuild-produced local-discovery helper;
- Node.js 24.18.0 arm64 for that helper;
- the approved icon, `Info.plist`, code-signing resources, and required licenses/notices.

Provider CLIs are external dependencies. The app, ZIP, and DMG must not contain `ProviderRuntimes`, a provider `node_modules` tree, provider wrappers, provider credentials, or provider authentication state. This removes the largest part of the previous bundle while preserving self-contained local discovery.

The release limits are hard gates:

- installed `PortDeck.app`: at most 110 MiB (`112640` KiB);
- production ZIP: at most `45,000,000` bytes;
- production DMG: at most `55,000,000` bytes;
- local candidate: at most nine regular files;
- production app: exactly the ten expected regular files, including Apple's stapled notarization ticket.

`scripts/build-release-app.sh` strips the Swift app executable and bundled Node executable before signing. It emits matching `PortDeckMac.dSYM` debug symbols beside the local candidate, outside `PortDeck.app`, and rejects a UUID mismatch.

## Local arm64 release candidate

Build and verify the ad-hoc candidate:

```bash
npm run build:mac:release
npm run verify:mac:release
```

The app is written to `portdeck-mac/.build/release-artifacts/PortDeck.app`; debug symbols are written to `portdeck-mac/.build/release-artifacts/PortDeckMac.dSYM`.

The candidate is intentionally not a public artifact. It has no production icon, Developer ID signature, secure timestamp, notarization ticket, or Gatekeeper acceptance. Verification copies it outside the checkout, uses an isolated home directory and a scrubbed `PATH`, exercises the status contract, checks signatures and entitlements, asserts that provider CLIs are absent, and enforces the app/file-count budgets.

## Production GitHub release workflow

Install [`create-dmg`](https://github.com/create-dmg/create-dmg) with `brew install create-dmg`. PortDeck uses it only to create the Finder window and `/Applications` drop link; the repository's release scripts own signing, notarization, checksums, and verification.

`npm run preflight:mac:github-release` checks the approved icon, packaging tools, Developer ID Application identity, and notarytool profile. It does not sign or upload an artifact.

After explicit approval to use signing credentials and upload to Apple:

```bash
PORTDECK_APPROVE_SIGNING_AND_NOTARIZATION=YES npm run build:mac:github-release
```

The guarded workflow:

1. Builds and verifies the local arm64 candidate.
2. Adds the approved icon and release metadata.
3. Signs each nested Mach-O before signing the outer app; it never uses `codesign --deep` for signing.
4. Submits a temporary ZIP to Apple, requires an accepted zero-issue notarization log, and staples the app ticket.
5. Creates the final ZIP and SHA-256 sidecar under the ignored `portdeck-mac/.build/github-release-artifacts` directory.
6. Creates the DMG with `PortDeck.app` and an `/Applications` drop link, signs the disk image, submits the DMG separately to Apple, requires an accepted zero-issue log, and staples the DMG ticket.
7. Extracts the ZIP and mounts the DMG outside the checkout under simulated quarantine. The DMG verifier copies out its app and reruns the complete production app lifecycle verifier.

The Node runtime is exactly 24.18.0 from the pinned official arm64 archive and SHA-256 in `release-config.sh`. No provider downloads occur during build or application runtime.

Apple bundle versions remain numeric. The prerelease identity is stored separately in `PortDeckReleaseVersion` and `PortDeckReleaseTag`; the verifier ties those values to the expected asset name and checksum.

Do not run the guarded signing/notarization workflow, create a tag, publish a GitHub Release, update Homebrew, or deploy the site without explicit release approval.

## Production verification

`verify-release-app.sh --production-zip <zip> <sha256>` requires:

- the expected ZIP/checksum names and digest;
- a ZIP at or below `45,000,000` bytes;
- only `PortDeck.app` at the archive root;
- the exact ten-file app contents, including Apple's stapled notarization ticket, and no `ProviderRuntimes`;
- an installed app at or below 110 MiB;
- matching release metadata and approved icon checksum;
- arm64-only Mach-O code;
- Developer ID signatures, hardened runtime, secure timestamps, and Node's narrow JIT entitlement;
- no App Sandbox or `get-task-allow`;
- a valid stapled ticket and Gatekeeper acceptance under quarantine;
- no builder paths, credentials, auth stores, `.env` files, or escaping symlinks;
- self-contained local discovery with no system Node dependency;
- successful LaunchServices startup of the quarantined app.

`verify-release-app.sh --production-dmg <dmg> <sha256>` additionally requires:

- the expected DMG/checksum names and digest;
- a DMG at or below `55,000,000` bytes;
- a valid Developer ID signature, secure timestamp, disk-image structure, and stapled notarization ticket;
- exactly `PortDeck.app` and an `/Applications` symlink as visible Finder contents;
- the Applications link to resolve exactly to `/Applications`;
- the app copied out of the quarantined DMG to pass the complete production ZIP verifier above.

Provider behavior is verified in Swift tests with injected executable paths and fake command runners. The release verifier asserts provider executables and dependency trees are absent rather than contacting or mutating real provider accounts.

## External provider CLI contract

Convex, Supabase, Wrangler, Railway, flyctl, and Netlify all use the same resolution order:

1. The provider's authoritative `PORTDECK_*_BIN` override. An invalid override fails and never falls through.
2. `command -v <cli>` through the user's login shell.
3. `/opt/homebrew/bin/<cli>`, then `/usr/local/bin/<cli>`.

PortDeck never searches a monitored project's `node_modules`, the repository's dependencies, or a packaged provider path. When invoking a Node-based CLI, it prepends the resolved executable's directory to `PATH` so a co-installed Node remains reachable from Finder's restricted environment.

PortDeck validates these inclusive/exclusive ranges before caching an executable:

| Provider | Supported range | Install command |
| --- | --- | --- |
| Convex | `>=1.42.1 <2.0.0` | `npm install --global convex@1` |
| Supabase | `>=2.109.1 <3.0.0` | `brew install supabase/tap/supabase` |
| Wrangler | `>=4.111.0 <5.0.0` | `npm install --global wrangler@4` |
| Railway | `>=5.26.2 <6.0.0` | `brew install railway` |
| flyctl | `>=0.4.71 <0.5.0` | `brew install flyctl` |
| Netlify | `>=26.2.0 <27.0.0`, Node `>=20.12.2` | `brew install netlify-cli` |

Missing and unsupported CLIs leave provider tabs visible. The app shows a copyable install command, official documentation, and Refresh. It never installs or upgrades a provider CLI automatically.

Authentication remains owned by each provider CLI. PortDeck preserves the existing device-login flows for Vercel and Convex and provides copyable Terminal login commands for the other providers. It never copies or stores provider tokens.

Vercel and GitHub retain their existing external CLI resolution and read-only authentication contracts.

## Homebrew Cask

Users install the public beta with:

```bash
brew install --cask JessePeplinski/tap/portdeck@beta
```

The cask in [`JessePeplinski/homebrew-tap`](https://github.com/JessePeplinski/homebrew-tap) installs the exact signed and notarized GitHub ZIP; it is not a separate build. Manual installation uses the DMG and its drag-to-Applications layout. After an approved GitHub Release passes downloaded-artifact verification, the tap workflow may be dispatched for that exact version. Never point the cask at an unpublished asset or use `sha256 :no_check`.

## App Store boundary

External executable discovery and CLI credential access are not part of the current App Sandbox baseline. A future App Store target must use separately reviewed sandbox-compatible authentication/API adapters or omit provider integrations; it must not re-embed the previous provider dependency trees as an accidental consequence of App Store work.

Local discovery remains the only bundled runtime boundary. See [app-store-readiness.md](app-store-readiness.md) for the separate sandbox plan.
