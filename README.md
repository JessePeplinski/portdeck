# PortDeck

PortDeck is a native macOS menu-bar command center for local development services, saved projects, and read-only deployment-provider health.

> [!IMPORTANT]
> PortDeck is in pre-release development. `v0.1.0-beta.3` is the current signed and notarized GitHub prerelease target. Source-development, sandbox-probe, local release-candidate, and production ZIP artifacts remain separate workflows.

## What PortDeck does

- Discovers listening ports, processes, Git repositories and worktrees, and Docker services on the local Mac.
- Keeps saved projects available from a dedicated Projects view, with explicit start, stop, open, and confirmed port-switching controls.
- Shows read-only production and deployment health for Vercel, Convex, GitHub Actions, Supabase, Cloudflare, Railway, Fly.io, and Netlify.
- Keeps provider tabs configurable without changing the underlying discovery or provider contracts.

Provider views are observation surfaces. They use existing authenticated sessions owned by the providers' official CLIs and do not deploy, restart, configure, or delete remote resources. Saved-project controls are the deliberate control surface: they change only local process state after an explicit user action and PortDeck's ownership and identity checks.

## Install the Apple Silicon beta

The current beta supports arm64 Apple Silicon Macs running macOS 14 or newer. Install it with Homebrew:

```bash
brew install --cask JessePeplinski/tap/portdeck@beta
open -a PortDeck
```

Homebrew installs the same signed and notarized app published on GitHub. The versioned release paths remain available for manual installation:

- [`PortDeck-0.1.0-beta.3-macos-arm64.zip`](../../releases/download/v0.1.0-beta.3/PortDeck-0.1.0-beta.3-macos-arm64.zip)
- [`PortDeck-0.1.0-beta.3-macos-arm64.zip.sha256`](../../releases/download/v0.1.0-beta.3/PortDeck-0.1.0-beta.3-macos-arm64.zip.sha256)

Download both files into the same directory, then verify and extract them:

```bash
shasum -a 256 -c PortDeck-0.1.0-beta.3-macos-arm64.zip.sha256
ditto -x -k PortDeck-0.1.0-beta.3-macos-arm64.zip .
open PortDeck.app
```

The release is a Developer ID-signed, Apple-notarized ZIP. PortDeck does not use App Sandbox in the direct-download build because local process, port, Git, Docker, external provider CLI, and saved-project controls require the separately verified direct-download boundary.

Provider tabs stay available even when their CLI is missing. PortDeck shows the exact install command, official documentation, and a Refresh action; it never installs or upgrades provider CLIs automatically. The current supported ranges are:

| Provider | Supported CLI |
| --- | --- |
| Convex | `>=1.42.1 <2.0.0` |
| Supabase | `>=2.109.1 <3.0.0` |
| Cloudflare | Wrangler `>=4.111.0 <5.0.0` |
| Railway | `>=5.26.2 <6.0.0` |
| Fly.io | flyctl `>=0.4.71 <0.5.0` |
| Netlify | `>=26.2.0 <27.0.0`, Node.js `>=20.12.2` |

Vercel and GitHub continue to use their existing external CLI contracts.

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

The launcher builds and opens `PortDeck.app`; PortDeck then appears in the menu bar. The source workflow resolves the JavaScript discovery helper from this checkout and provider CLIs from the user's login shell or standard Homebrew locations.

## Build the local arm64 release candidate

After `npm ci`, build and verify the self-contained Local/Projects candidate from the repository root:

```bash
npm run build:mac:release
npm run verify:mac:release
```

The artifact is written to `portdeck-mac/.build/release-artifacts/PortDeck.app`. It bundles the PortDeck helper and the official arm64 Node.js 24.18.0 binary, so Local discovery and saved-project start, stop, restart, and port switching do not require this checkout, a PortDeck CLI installation, or a system Node.js installation. Provider CLIs are intentionally external. The verifier copies the app outside the checkout, scrubs `PATH`, isolates PortDeck state, exercises Local/Projects, enforces a 110 MiB app budget and nine-file ceiling, and launches the copied app.

This artifact is a local packaging candidate, not the public ZIP. It has no production icon, Developer ID signature, or notarization ticket. It is ad-hoc signed with hardened runtime, does not enable App Sandbox, and is expected to fail Gatekeeper assessment.

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

1. Uses the approved, checksum-pinned production `.icns` in `portdeck-mac/Resources`, and requires a valid Developer ID Application identity and notarytool Keychain profile.
2. Builds the arm64 release app with the bundled Local/Projects helper and Node.js runtime, strips both Mach-O executables, and keeps matching Swift debug symbols outside the app.
3. Excludes every provider CLI and provider dependency tree from the bundle.
4. Signs every nested Mach-O individually with hardened runtime and secure timestamps, then signs the outer app without App Sandbox.
5. Notarizes a temporary ZIP, inspects the accepted log, staples the ticket to `PortDeck.app`, and creates the final ZIP with `ditto -c -k --keepParent`.
6. Verifies the final ZIP outside the repository under simulated quarantine, isolated state and home directories, and a scrubbed `PATH`, with hard limits of 110 MiB installed and 45,000,000 ZIP bytes.

Run the release preflight with `npm run preflight:mac:github-release`. It checks local signing metadata and validates the selected notarytool profile with a silent, read-only Apple Notary history request when the profile is not visible through the legacy Keychain lookup; it never uploads an artifact. The signing-and-notarization build is additionally guarded by `PORTDECK_APPROVE_SIGNING_AND_NOTARIZATION=YES` and must not run until the release owner explicitly approves signing and the Apple upload. See [`docs/distribution.md`](docs/distribution.md) for the complete commands, fixed inputs, and verification contract.

Homebrew installations update through `brew upgrade --cask JessePeplinski/tap/portdeck@beta`; manual installations update from the latest GitHub Release. A DMG, universal/x86_64 package, in-app updater, and App Store package are not part of this beta.

## Contributing

Read [`AGENTS.md`](AGENTS.md) before making changes. Keep changes focused, preserve the discovery and read-only provider boundaries, and run `npm run verify` before opening a pull request.

PortDeck is available under the [MIT License](LICENSE).
