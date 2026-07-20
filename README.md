# PortDeck

PortDeck is a native macOS menu-bar command center for local development services, saved projects, and read-only deployment-provider health.

> [!IMPORTANT]
> PortDeck is in pre-release development. `v0.1.0-beta.1` is the first signed and notarized GitHub prerelease target. Source-development, sandbox-probe, local release-candidate, and production ZIP artifacts remain separate workflows.

## What PortDeck does

- Discovers listening ports, processes, Git repositories and worktrees, and Docker services on the local Mac.
- Keeps saved projects available from a dedicated Projects view, with explicit start, stop, open, and confirmed port-switching controls.
- Shows read-only production and deployment health for Vercel, Convex, GitHub Actions, Supabase, Cloudflare, Railway, Fly.io, and Netlify.
- Keeps provider tabs configurable without changing the underlying discovery or provider contracts.

Provider views are observation surfaces. They use existing authenticated sessions owned by the providers' official CLIs and do not deploy, restart, configure, or delete remote resources. Saved-project controls are the deliberate control surface: they change only local process state after an explicit user action and PortDeck's ownership and identity checks.

## Download the Apple Silicon beta

The first beta supports arm64 Apple Silicon Macs running macOS 14 or newer. The versioned GitHub Release paths are:

- [`PortDeck-0.1.0-beta.1-macos-arm64.zip`](../../releases/download/v0.1.0-beta.1/PortDeck-0.1.0-beta.1-macos-arm64.zip)
- [`PortDeck-0.1.0-beta.1-macos-arm64.zip.sha256`](../../releases/download/v0.1.0-beta.1/PortDeck-0.1.0-beta.1-macos-arm64.zip.sha256)

Download both files into the same directory, then verify and extract them:

```bash
shasum -a 256 -c PortDeck-0.1.0-beta.1-macos-arm64.zip.sha256
ditto -x -k PortDeck-0.1.0-beta.1-macos-arm64.zip .
open PortDeck.app
```

The release is a Developer ID-signed, Apple-notarized ZIP. PortDeck does not use App Sandbox in the direct-download build because local process, port, Git, Docker, provider-runtime, and saved-project controls require the separately verified direct-download boundary.

## Run from source

### Requirements

- macOS 14 or newer
- Xcode with a Swift 6 toolchain
- Node.js and npm

From the repository root:

```bash
npm ci
npm run verify
portdeck-mac/scripts/run-dev-app.sh
```

The launcher builds and opens `PortDeck.app`; PortDeck then appears in the menu bar. The source workflow resolves the JavaScript discovery helper and managed provider runtimes from this checkout.

## Build the local arm64 release candidate

After `npm ci`, build and verify the self-contained Local/Projects candidate from the repository root:

```bash
npm run build:mac:release
npm run verify:mac:release
```

The artifact is written to `portdeck-mac/.build/release-artifacts/PortDeck.app`. It bundles the PortDeck helper and the official arm64 Node.js 24.18.0 binary, so Local discovery and saved-project start, stop, restart, and port switching do not require this checkout, a PortDeck CLI installation, or a system Node.js installation. The verifier copies the app outside the checkout, scrubs `PATH`, isolates PortDeck state, exercises those flows, and launches the copied app.

This artifact is a local packaging candidate, not the public ZIP. It has no production icon, managed Convex, Supabase, Wrangler, Railway, flyctl, or Netlify runtimes, Developer ID signature, or notarization ticket. It is ad-hoc signed with hardened runtime, does not enable App Sandbox, and is expected to fail Gatekeeper assessment.

## Repository layout

- [`portdeck-app`](portdeck-app/) owns local discovery, saved-project process control, and the [`portdeck status --json`](docs/status-json.md) contract.
- [`portdeck-mac`](portdeck-mac/) is the Swift menu-bar app that renders and invokes those contracts.
- [`docs/architecture.md`](docs/architecture.md) records the application and provider boundaries.
- [`docs/distribution.md`](docs/distribution.md) defines the direct-download packaging contract.
- [`docs/app-store-readiness.md`](docs/app-store-readiness.md) tracks the separate Mac App Store feasibility path.

The static marketing site is maintained independently in [`portdeck-site`](https://github.com/JessePeplinski/portdeck-site). This repository owns the CLI/helper, Mac app, product documentation, release scripts, tags, and downloadable assets.

## Privacy and trust

- PortDeck never bundles provider credentials or copies them into PortDeck-owned storage.
- Provider commands are read-only and scoped to the data PortDeck renders.
- PortDeck does not modify monitored projects, their manifests, lockfiles, CLI context, or remote resources.
- Command failures are bounded and credential-redacted before they reach the UI.
- Saved-project commands and logs stay in PortDeck's private local application data.

See [`docs/architecture.md`](docs/architecture.md) for the detailed provider allowlists and failure behavior.

## Production ZIP release pipeline

The production pipeline is deliberately separate from `build:mac`, `run-dev-app.sh`, the sandbox probe, and the local ad-hoc candidate. It:

1. Requires an approved `.icns` and its approved SHA-256, a valid Developer ID Application identity, and a notarytool Keychain profile.
2. Builds the existing arm64 release app and installs the exact managed provider dependency tree directly from the root lockfile without running package scripts or copying the checkout's `node_modules`.
3. Downloads only the pinned arm64 Railway and flyctl archives after verifying their published SHA-256 digests.
4. Signs every nested Mach-O individually with hardened runtime and secure timestamps, then signs the outer app without App Sandbox.
5. Notarizes a temporary ZIP, inspects the accepted log, staples the ticket to `PortDeck.app`, and creates the final ZIP with `ditto -c -k --keepParent`.
6. Verifies the final ZIP outside the repository under simulated quarantine, isolated state and home directories, and a scrubbed `PATH` before generating the release handoff.

Run the metadata-only preflight with `npm run preflight:mac:github-release`. The credential-using build is additionally guarded by `PORTDECK_APPROVE_SIGNING_AND_NOTARIZATION=YES` and must not run until the release owner explicitly approves signing and the Apple upload. See [`docs/distribution.md`](docs/distribution.md) for the complete commands, fixed inputs, and verification contract.

The first update path is a manual download from the latest GitHub Release. A DMG, universal/x86_64 package, Homebrew formula, in-app updater, and App Store package are not part of this beta.

## Contributing

Read [`AGENTS.md`](AGENTS.md) before making changes. Keep changes focused, preserve the discovery and read-only provider boundaries, and run `npm run verify` before opening a pull request.

PortDeck is available under the [MIT License](LICENSE).
