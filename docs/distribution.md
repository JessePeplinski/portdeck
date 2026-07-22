# PortDeck Distribution

PortDeck's first public distribution target is a Developer ID signed and notarized direct download. The Mac App Store remains a longer-term target once the remaining product-readiness work and sandbox feasibility pass are complete.

## First Distribution Target

Use a Developer ID signed and notarized macOS app distributed as a versioned ZIP through GitHub Releases, with the PortDeck site linking to the latest release. This path fits the product because PortDeck needs to inspect local ports, processes, Git repositories, worktrees, and Docker state.

The current beta is `v0.1.0-beta.2`, arm64-only for Apple Silicon Macs running macOS 14 or newer:

- app asset: [`PortDeck-0.1.0-beta.2-macos-arm64.zip`](../../../releases/download/v0.1.0-beta.2/PortDeck-0.1.0-beta.2-macos-arm64.zip)
- checksum asset: [`PortDeck-0.1.0-beta.2-macos-arm64.zip.sha256`](../../../releases/download/v0.1.0-beta.2/PortDeck-0.1.0-beta.2-macos-arm64.zip.sha256)

A DMG, universal/x86_64 build, Sparkle or another in-app updater, and App Store package are explicitly outside this release. Universal packaging is a later compatibility slice after the complete runtime bundle is proven on Apple Silicon.

## Local arm64 release candidate

`npm run build:mac:release` assembles `portdeck-mac/.build/release-artifacts/PortDeck.app`; `npm run verify:mac:release` verifies the artifact and exercises it from a temporary location outside the repository. This workflow is separate from the source-development app and `build-sandbox-probe-app.sh`.

The candidate bundles a single esbuild-produced Node 24 ESM helper behind the unchanged `portdeck status --json` contract, official Node.js 24.18.0 arm64 `bin/node`, and PortDeck, Node.js, and helper third-party license material. Node is fetched only into the ignored release cache from `node-v24.18.0-darwin-arm64.tar.gz` and accepted only when its SHA-256 is `e1a97e14c99c803e96c7339403282ea05a499c32f8d83defe9ef5ec66f979ed1`. No `node_modules` tree is copied into the app.

The bundled Node executable is signed first with hardened runtime and the narrow JIT entitlement required by V8; the app is then ad-hoc signed with hardened runtime and without App Sandbox. This proves self-contained Local discovery and saved-project lifecycle controls. It does not prove public distribution: Gatekeeper rejection is expected, and the candidate has no production icon, managed provider runtimes, Developer ID identity, secure timestamp, notarization, stapled ticket, or downloaded-artifact proof.

The production ZIP contract includes:

- a native menu bar app bundle;
- a bundled helper or discovery binary behind the `portdeck status --json` contract;
- direct-download saved-project start, stop, and confirmed port switching through that bundled helper/runtime, with no separate PortDeck CLI or Node installation;
- the PortDeck-managed Convex CLI runtime and its Node runtime/dependency tree;
- the PortDeck-managed Supabase CLI 2.109.1 runtime and its locked runtime assets;
- the PortDeck-managed Wrangler runtime and its Node runtime/dependency tree;
- the PortDeck-managed Railway CLI runtime and its Node/native runtime dependency tree;
- the PortDeck-managed flyctl 0.4.71 native runtime;
- the PortDeck-managed Netlify CLI 26.2.0 runtime and its Node runtime/dependency tree;
- optional direct-download support for the user's existing authenticated Vercel and GitHub CLI sessions;
- Developer ID signing;
- Apple notarization;
- a manual update path through the latest GitHub Release, with no in-app updater in the first beta.

## Production GitHub ZIP workflow

`npm run preflight:mac:github-release` performs a release readiness check. It requires:

- the approved production `portdeck-mac/Resources/PortDeck.icns`, whose SHA-256 is pinned in `release-config.sh`;
- `PORTDECK_SIGNING_IDENTITY` naming an available Developer ID Application identity;
- `PORTDECK_NOTARYTOOL_PROFILE` naming an available notarytool Keychain profile.

`PORTDECK_RELEASE_ICON` and `PORTDECK_RELEASE_ICON_SHA256` remain optional path/checksum overrides for release validation, but an override must match the approved checksum. The editable vector source is `portdeck-mac/Resources/PortDeckIcon.svg`.

The preflight does not sign code, read private-key material, or submit an artifact. It first checks legacy local Keychain metadata for the selected notarytool profile. When current `notarytool` storage is not discoverable through that lookup, it runs a silent `notarytool history` request to authenticate the saved profile without printing submission history or uploading an artifact. Do not put any credential values in the repository or command line.

After explicit approval to use both credentials and upload to Apple, run the guarded build in the same shell where the two non-secret credential selectors above are set:

```bash
PORTDECK_APPROVE_SIGNING_AND_NOTARIZATION=YES npm run build:mac:github-release
```

The command builds the local arm64 candidate, adds the approved icon and locked provider runtimes, signs each nested Mach-O before the outer app, creates a temporary notarization ZIP, waits for Apple acceptance, retrieves and inspects the notarization log, staples and validates `PortDeck.app`, then creates the final ZIP with `/usr/bin/ditto -c -k --keepParent`. It writes the ZIP, SHA-256 file, notarization result, and notarization log only under the ignored `portdeck-mac/.build/github-release-artifacts` directory.

The Node runtime is exactly 24.18.0 from `https://nodejs.org/download/release/v24.18.0/node-v24.18.0-darwin-arm64.tar.gz`, SHA-256 `e1a97e14c99c803e96c7339403282ea05a499c32f8d83defe9ef5ec66f979ed1`. Provider npm dependencies are installed directly into the staged app from the root lockfile with lifecycle scripts and user/global npm configuration disabled. The pipeline does not copy the checkout's `node_modules`, npm credentials, provider auth stores, monitored-project files, or local PortDeck state. Railway and flyctl use their pinned official arm64 archives and checksums recorded in `release-config.sh`.

Apple bundle versions remain numeric: `CFBundleShortVersionString` is `0.1.0` and `CFBundleVersion` is `2`. The prerelease identity is carried separately by `PortDeckReleaseVersion=0.1.0-beta.2` and `PortDeckReleaseTag=v0.1.0-beta.2`, and the verifier requires all four values. This preserves Apple's bundle-version format while tying the artifact to the exact GitHub tag.

Two installed packages are deliberately omitted and recorded in the runtime manifest. `fsevents` is an optional watcher dependency whose upstream binary is universal and is not used by PortDeck's read-only command allowlists. `@netlify/ai@0.4.2` is not loaded by PortDeck's `sites:list` or `listSiteDeploys` commands and upstream publishes it without a license declaration or license file, so PortDeck does not redistribute it. The staging smoke runs both allowed Netlify command modules from a neutral directory after pruning to prove that the reduced runtime reaches the expected unauthenticated behavior rather than a missing-module failure.

The locked `bare-fs`, `bare-path`, and `bare-url` packages publish native prebuilds for multiple operating systems and architectures in each package. Production staging retains only each package's required `darwin-arm64` prebuild, rejects a missing or non-arm64 replacement, and removes every Android, iOS, Linux, Windows, and x64 prebuild before signing. Their package metadata and license evidence remain in the runtime manifest and notices.

Production staging also removes the test-only fixture tree published by `@fastify/static@9.3.0`. That tree contains intentionally malformed gzip samples used by the dependency's own tests; redistributing them causes Apple to report uninspectable-archive warnings even though PortDeck never loads them. The release verifier rejects the fixture tree if it reappears, and the notarization gate still requires an accepted log with zero issues.

Every redistributed npm package has explicit license evidence in the runtime manifest. Upstream license/notice files are reproduced verbatim when present. For packages that publish only an SPDX declaration, the notices append the corresponding canonical SPDX text from the exact build-time `spdx-license-list@6.11.0` dataset and record its SHA-256. The verifier rejects missing evidence, declaration/text mismatches, or absent notice sections.

`verify-release-app.sh --production-zip <zip> <sha256>` extracts the ZIP outside the checkout as a user download, applies simulated quarantine, and requires matching bundle/tag metadata, the approved icon checksum, arm64-only Mach-O code, exact runtime versions, contained symlinks, complete licenses/notices, Developer ID signatures, secure timestamps, hardened runtime, no App Sandbox, a valid stapled ticket, and Gatekeeper acceptance. It uses temporary `HOME` and `PORTDECK_STATE_DIR` values with a scrubbed `PATH`, then exercises status discovery, save, start, restart, confirmed port switching, stop, managed runtime version execution, and app launch.

After the PR is merged and release publication is explicitly approved, create `v0.1.0-beta.2` as a GitHub prerelease and attach only the ZIP and SHA-256 file. Download both assets back into a new temporary directory and rerun the production verifier against those downloaded files. The release is incomplete until the downloaded checksum matches, Gatekeeper accepts the quarantined extracted app, the app launches, and the downloaded Local/Projects lifecycle passes.

## Homebrew Cask

PortDeck's prerelease Homebrew channel is the `portdeck@beta` cask in the separate [`JessePeplinski/homebrew-tap`](https://github.com/JessePeplinski/homebrew-tap) repository. It installs the exact signed and notarized ZIP already published by the PortDeck GitHub Release; Homebrew is an additional installation and update path, not a separate build artifact.

Users install the beta with:

```bash
brew install --cask JessePeplinski/tap/portdeck@beta
```

The cask must retain the release's platform boundary (`arm64`, macOS 14 or newer), exact versioned asset URL, and SHA-256. After each new GitHub Release passes the downloaded-artifact verification above, dispatch the tap's `Update PortDeck cask` workflow for the exact beta version:

```bash
gh workflow run update-portdeck-cask.yml \
  --repo JessePeplinski/homebrew-tap \
  -f version=0.1.0-beta.2
```

Replace the example with the release version being published. The workflow independently requires a non-draft prerelease with both expected assets, verifies that GitHub's asset digest matches the published SHA-256 sidecar, updates and audits the cask, then commits the verified change to the tap. A six-hour scheduled check is a backup; the explicit workflow run and clean public install smoke remain release gates. Do not point the cask at an unpublished asset, use `sha256 :no_check`, or publish the cask update before the GitHub Release is live and verified.

## Mac App Store Target

Pursue the Mac App Store after sandbox feasibility is proven for the core discovery needs:

- listening port discovery;
- process metadata and cwd lookup;
- Git repository and worktree detection;
- Docker container and published port detection;
- user consent and entitlement behavior that does not break the product.

If sandboxing blocks reliable local runtime discovery, the App Store version would need a reduced feature set or a helper architecture that still preserves the status JSON contract.

Saved-project launcher controls are excluded from the App Store build for the first slice. Re-enable them only after a sandbox-compatible login-shell/process-group ownership design is reviewed and verified; the read-only Local discovery view remains the baseline.

The current feasibility baseline and next packaging slice are tracked in `docs/app-store-readiness.md`.

## Release Boundary

Distribution work should not change product detection behavior by itself. The release pipeline packages the app and helper, while `portdeck-app` remains the owner of discovery semantics and JSON compatibility.

`PORTDECK_NODE` and `PORTDECK_CLI` are authoritative development/test overrides. Without overrides, a complete `Contents/Resources/PortDeckRuntime` is authoritative for a packaged app. Missing or partial packaged helper/provider runtimes are packaging failures and must not silently fall through to source-checkout or system paths. Source-development and sandbox-probe bundles carry the explicit `.portdeck-source-development` marker; the production verifier rejects that marker.

## Vercel Provider Boundary

The direct-download Vercel view is an optional integration that uses the user's installed Vercel CLI 50.5.1 or newer and its existing authenticated session. Resolution checks the authoritative `PORTDECK_VERCEL_BIN` development/test override, the user's login shell, then standard Homebrew paths. When invoking the resolved CLI, PortDeck prepends the CLI's directory and then its packaged Node runtime directory to the inherited command `PATH`; this lets Node-based Vercel launchers use their co-installed Node first while remaining functional in Finder's restricted environment. PortDeck invokes only the documented read-only API requests, never bundles credentials, and remains usable when the CLI is missing or authentication has expired.

This external executable and credential-access path is not part of the App Store sandbox baseline. A future App Store build must provide a separately reviewed sandbox-compatible authentication/API implementation or omit the provider; it must not add Vercel mutation controls as a packaging workaround.

## Convex Provider Runtime Contract

Source builds install exact Convex CLI 1.42.1 from PortDeck's root lockfile. Direct-download packaging must place an executable entrypoint at `PortDeck.app/Contents/Resources/ProviderRuntimes/convex/bin/convex` and include a compatible Node runtime plus the locked npm dependency tree it needs. The app validates the CLI's exact version before use; release packaging must not download `latest` at build or runtime.

`PORTDECK_CONVEX_BIN` remains an explicit development/test override. It is not a user-project fallback, and packaging must never copy a CLI or dependency tree from a linked project. Credentials remain in Convex's own `~/.convex/config.json` location and are read transiently by the provider flow rather than embedded in the app bundle.

## GitHub Actions Provider Boundary

The direct-download GitHub Actions view uses the user's existing authenticated `gh` installation. Resolution checks the authoritative `PORTDECK_GH_BIN` development/test override, the user's login shell, then standard Homebrew paths. PortDeck never bundles, copies, logs, or stores the GitHub token and performs only read-only `gh api` requests for repositories represented by the current local status snapshot.

This external executable and credential-access path is not part of the App Store sandbox baseline. A future App Store build must provide a separately reviewed sandbox-compatible GitHub authentication/API implementation or omit the provider; it must not weaken the read-only boundary or add workflow mutation controls as a packaging workaround.

## Supabase Provider Runtime Contract

Source builds install exact Supabase CLI 2.109.1 from PortDeck's root lockfile. Direct-download packaging must place an executable entrypoint at `PortDeck.app/Contents/Resources/ProviderRuntimes/supabase/bin/supabase` and include the locked runtime assets it needs. The app validates the exact version before use and never downloads `latest` at build or application runtime.

`PORTDECK_SUPABASE_BIN` is an authoritative development/test override, not a monitored-project fallback. Supabase CLI owns authentication. PortDeck runs only `projects list --output-format json` from a neutral temporary directory with telemetry disabled; it never copies or persists the token, searches monitored projects for a runtime, reads application data, or mutates Supabase resources. The production ZIP pipeline installs and validates the locked arm64 runtime assets before signing.

Supabase execution and credential access remain direct-download features until the packaged runtime, credential access, signing, and sandbox execution are verified. App Store packaging must preserve the account-wide read-only boundary and must not add project linking, database access, migrations, deployments, configuration changes, or other mutations as a workaround.

## Cloudflare Provider Runtime Contract

Source builds install exact Wrangler 4.111.0 from PortDeck's root lockfile. Direct-download packaging must place its executable entrypoint at `PortDeck.app/Contents/Resources/ProviderRuntimes/cloudflare/bin/wrangler` and include a compatible Node runtime plus the locked dependency tree. PortDeck validates the exact version before use and never downloads `latest` at build or runtime.

`PORTDECK_WRANGLER_BIN` is an authoritative development/test override, not a linked-project fallback. Wrangler keeps authentication in its own credential storage; PortDeck calls `whoami --json` and account-scoped read-only commands without exporting, copying, logging, or persisting the token. The production ZIP pipeline installs and validates the locked arm64 runtime assets before signing.

Wrangler execution and credential access are direct-download features until a sandbox-compatible package and authentication path is proven. App Store packaging must not reach into monitored projects, weaken the read-only command set, or add Cloudflare mutation controls as a workaround.

## Railway Provider Runtime Contract

Source builds install exact `@railway/cli` 5.26.2 from PortDeck's root lockfile. Direct-download packaging must place an executable entrypoint at `PortDeck.app/Contents/Resources/ProviderRuntimes/railway/bin/railway` and include the locked runtime assets it needs. PortDeck validates the exact `railway 5.26.2` output and never downloads `latest` at runtime.

`PORTDECK_RAILWAY_BIN` is an authoritative development/test override, not a monitored-project fallback. Railway CLI keeps authentication in its own storage; PortDeck removes inherited Railway token environment variables and invokes only the documented read-only account/project/service/deployment commands. The production ZIP pipeline downloads the official 5.26.2 arm64 binary, requires SHA-256 `816414da5f182d8ee7ed66f6cf607bf5d37f8e55d367395e8133ef321e9f8ee4`, and validates its exact version before signing.

Railway execution and credential access remain direct-download features until a sandbox-compatible package and authentication path is proven. App Store packaging must preserve explicit project/environment/service scoping and must not add login, linking, logs, variables, shells, or resource mutations as a workaround.

## Fly.io Provider Runtime Contract

Fly.io uses the official native Go `flyctl` binary pinned exactly to 0.4.71. Direct-download packaging must place the architecture-appropriate executable at `PortDeck.app/Contents/Resources/ProviderRuntimes/fly/bin/flyctl`. The verified macOS SHA-256 checksums are `a89085595d7da7d4ee3a8647feb700a52702eb835591e78feae47fcd2d98bfbe` for arm64 and `00f46edbd9d2a537aeccd770c28b987a2dbd3bf593aef8fa35b57dc04d38d9a2` for x86_64. PortDeck validates name, exact version, Darwin OS, and architecture before caching the executable and never downloads a binary at application runtime.

`PORTDECK_FLY_BIN` is an authoritative development/test override. Source builds may stage the binary only at `.build/provider-runtimes/fly/bin/flyctl` under a PortDeck-owned root; PortDeck does not search PATH, Homebrew, Fly configuration directories, `fly.toml` locations, or monitored repositories. The production ZIP pipeline downloads the official 0.4.71 arm64 binary, verifies the documented arm64 checksum, and validates its exact version before signing.

flyctl owns authentication. PortDeck removes inherited Fly token and context variables, disables telemetry, runs outside monitored repositories, and invokes only version, authentication-evidence, organization-list, app-list, explicitly app-scoped status, and explicitly app-scoped release-list commands. Fly execution and credential access remain direct-download features until a sandbox-compatible packaging/authentication path is proven; App Store packaging must not weaken the allowlist or add login, logs, secrets, SSH, configuration, or resource mutations as a workaround.

## Netlify Provider Runtime Contract

Source builds install exact `netlify-cli` 26.2.0 from PortDeck's root lockfile. Direct-download packaging must place an executable entrypoint at `PortDeck.app/Contents/Resources/ProviderRuntimes/netlify/bin/netlify` and include a compatible Node.js runtime plus the locked npm dependency tree. PortDeck validates the exact CLI version, Darwin OS, supported architecture, and Node.js 20.12.2 minimum before use. It never downloads `latest` at build or application runtime.

`PORTDECK_NETLIFY_BIN` is an authoritative development/test override, not a monitored-project fallback. Netlify CLI owns authentication. PortDeck runs in a neutral private directory, removes inherited Netlify token/site/API/proxy/debug/test variables, disables telemetry and update prompts, and invokes only site listing plus explicitly site-scoped latest-production-deployment requests. It never reads credential files directly or invokes login. The production ZIP pipeline installs and validates the locked Node/runtime tree before signing.

Netlify execution and credential access remain direct-download features until the Node/runtime tree, credential access, signing, and sandbox execution are verified. App Store packaging must preserve the strict allowlist, account-wide membership boundary, explicit site scope, pagination completeness check, and no-token-inheritance rule; it must not add login, linking, deploy/build/log/environment/configuration access, or resource mutations as a workaround.
