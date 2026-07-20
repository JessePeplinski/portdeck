# PortDeck Mac App Store Readiness

PortDeck is not yet ready for App Store Connect. The current Swift package builds and tests the product, while this document records the separate distribution work needed for a Mac App Store archive.

## Product Readiness Before Submission

The Mac App Store remains the intended distribution target. PortDeck will take a few product and production-readiness slices before returning to the packaging work below. Those intervening changes should preserve the sandbox probe, keep the status JSON boundary stable, and avoid adding dependencies or privileges that make App Store distribution harder.

Do not treat this sequencing as a decision to abandon the Mac App Store. Resume the distribution work when the product changes are ready, starting with the real application target and embedded discovery helper.

## Confirmed Baseline

- `xcodebuild archive` can archive the Swift package as a universal executable.
- That archive installs `PortDeckMac` under `Products/usr/local/bin`; it does not produce a `.app` product.
- The Swift package archive has no bound `Info.plist`, App Sandbox entitlement, or distribution signing identity.
- `scripts/build-sandbox-probe-app.sh` builds a local `.app`, enables hardened runtime and App Sandbox, and verifies its signature. This is a feasibility probe, not a submission artifact.
- `scripts/build-release-app.sh` builds a separate arm64 local release candidate with an embedded discovery helper and Node.js 24.18.0. That candidate proves self-contained Local/Projects behavior without a source checkout or system Node installation, but it deliberately runs without App Sandbox and is not an App Store archive.
- `scripts/build-github-zip-release.sh` is a separate Developer ID/notarization pipeline for the arm64 GitHub prerelease. It adds the approved icon and locked managed runtimes, signs and notarizes without App Sandbox, and verifies the quarantined ZIP outside the checkout. Passing that direct-download pipeline does not prove App Store sandbox compatibility.
- The bundled Node runtime requires a narrow JIT entitlement under hardened runtime. Its necessity and acceptability must be reviewed separately for an App Store target; the direct-download candidate does not prove sandbox compatibility.
- The Vercel live-services view currently reuses an external Vercel CLI installation for device authentication and read-only API calls. Treat this as a direct-download feature until a sandbox-compatible provider authentication path is designed and verified; do not claim it as part of the App Store baseline.
- The Convex production-health view uses PortDeck's exact managed Convex CLI 1.42.1 runtime and reuses the existing Convex device login without copying its token. Source builds resolve the locked root dependency; production direct-download builds stage it at the defined app-resource path. Treat it as a direct-download feature until the Node/runtime dependency tree, credential access, signing, and package execution have a sandbox-compatible replacement.
- The GitHub Actions health view executes the user's external authenticated `gh` binary for read-only REST requests. PortDeck does not store the GitHub token, but external executable discovery and GitHub CLI credential access are not part of the sandbox baseline. Treat this provider as direct-download-only until a sandbox-compatible authentication and API path is designed and verified.
- The Cloudflare view uses PortDeck's exact Wrangler 4.111.0 runtime contract and Wrangler-owned authentication for read-only Pages and Worker deployment status. Source builds use the locked root dependency; production direct-download builds stage the locked arm64 tree at the defined app-resource path. Treat it as direct-download-only until the same runtime and credential path is proven under App Sandbox.
- The Railway view uses the official Railway CLI 5.26.2 arm64 runtime and CLI-owned authentication for strictly read-only account/project/service/deployment status. The production direct-download pipeline checksum-verifies and stages its native binary. Treat it as direct-download-only until the same runtime and credential path is proven under App Sandbox.
- The Fly.io view uses the official native flyctl 0.4.71 runtime contract and flyctl-owned authentication for read-only organization, app, Machine, check, and release status. The production direct-download pipeline checksum-verifies and stages its arm64 binary. Treat it as direct-download-only until the same runtime and credential path is proven under App Sandbox.
- The Netlify view uses PortDeck's exact Netlify CLI 26.2.0 runtime contract and CLI-owned authentication for account-wide sites and latest production deployment status. Source builds use the locked root dependency; production direct-download builds stage the locked arm64 tree at the defined app-resource path. Treat it as direct-download-only until the same runtime and credential path is proven under App Sandbox.

## Next Distribution Slice

1. Create a real macOS application target that archives `PortDeck.app` rather than assembling the local candidate with a shell script.
2. Adapt the proven embedded helper/runtime layout to App Sandbox without assuming the direct-download Node entitlement set is acceptable.
3. Give every embedded executable the minimal reviewed sandbox and code-signing entitlements.
4. Test listening-port, process identity, cwd, Git/worktree, Docker, saved-project, and stop behavior while sandboxed.
5. Keep only the core features that work reliably without temporary entitlement exceptions or privilege escalation.

For the Convex provider, the App Store target must not depend on source-checkout lookup. It must either embed the signed runtime at `Contents/Resources/ProviderRuntimes/convex/bin/convex` with a compatible Node runtime or replace the CLI adapter with a sandbox-compatible native API path. Do not reach into linked projects for executables or modify their manifests and lockfiles.

For the GitHub provider, the App Store target must not execute an external Homebrew/login-shell `gh` binary or reach into GitHub CLI credential storage. It needs a separately reviewed sandbox-compatible authentication/API design while preserving the current read-only repository scope.

For the Cloudflare provider, the App Store target must embed and sign Wrangler at `Contents/Resources/ProviderRuntimes/cloudflare/bin/wrangler` with its compatible Node dependency tree or replace the CLI adapter with a separately reviewed sandbox-compatible authentication/API path. It must preserve account scoping, the no-token-export rule, and the read-only command boundary.

For the Railway provider, the App Store target must embed and sign Railway CLI 5.26.2 at `Contents/Resources/ProviderRuntimes/railway/bin/railway` with its required runtime assets or replace the CLI adapter with a separately reviewed sandbox-compatible authentication/API path. It must preserve the no-token-inheritance rule, explicit production scopes, bounded polling, and the strictly read-only command boundary.

For the Fly.io provider, the App Store target must embed and sign the correct flyctl 0.4.71 architecture at `Contents/Resources/ProviderRuntimes/fly/bin/flyctl` or replace the CLI adapter with a separately reviewed sandbox-compatible authentication/API path. It must preserve the checksum/version gate, no-token-inheritance rule, neutral working directory, explicit `--app` scopes, four-command limit, and strict read-only allowlist.

For the Netlify provider, the App Store target must embed and sign Netlify CLI 26.2.0 at `Contents/Resources/ProviderRuntimes/netlify/bin/netlify` with a compatible Node.js runtime and locked dependency tree, or replace the CLI adapter with a separately reviewed sandbox-compatible authentication/API path. It must preserve the exact runtime gate, no-token-inheritance rule, neutral working directory, account-wide site membership, explicit per-site production deployment scope, pagination completeness check, four-command limit, and strict read-only allowlist.

## Support Button Policy

Development and direct-download builds may show the external Buy Me a Coffee button. The button is optional, does not unlock functionality, and is compiled out when the `APP_STORE` Swift compilation condition is active.

Before submitting through App Store Connect:

1. Set `APP_STORE` in the App Store target's active compilation conditions.
2. Confirm the external Buy Me a Coffee button is absent from that archive.
3. If PortDeck should accept tips inside the App Store build, implement a StoreKit tip product instead of linking to an external payment page.

This is a conservative global-storefront policy. Re-check Apple's current App Review Guidelines before submission because external payment-link rules can vary by storefront and change over time.

## Sandbox Probe

Build the locally signed probe:

```bash
portdeck-mac/scripts/build-sandbox-probe-app.sh
```

The script uses an ad-hoc signature by default. Set `CODE_SIGN_IDENTITY` to a local Apple Development identity when testing a development-signed bundle. Do not treat this probe as an App Store archive or notarized direct-download artifact.

The sandbox probe and local arm64 release candidate answer different questions. The probe tests sandbox feasibility and is not self-contained; the release candidate tests self-contained Local/Projects packaging without App Sandbox. Neither may be renamed or repackaged as a public release.
