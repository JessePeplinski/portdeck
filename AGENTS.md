# PortDeck Repository Instructions

These instructions apply to the entire repository. More specific instructions in a nested directory override them for that subtree.

## Sources of truth

Read the relevant source and documentation before changing behavior:

1. `docs/architecture.md` for ownership and provider boundaries.
2. `docs/status-json.md` for the discovery JSON contract.
3. `docs/distribution.md` for the direct-download packaging contract.
4. `docs/app-store-readiness.md` for the separate sandbox and Mac App Store path.
5. `README.md` for the public product and source-build contract.

If code and documentation disagree, stop and reconcile the conflict instead of silently choosing one.

## Repository ownership boundaries

- `portdeck-app` owns process, port, Git worktree, and Docker discovery; the versioned private saved-project store; command suggestions; process-group ownership; start, stop, restart, and port-switching behavior; and `portdeck status --json` compatibility.
- `portdeck-mac` renders those contracts and invokes the helper. It must not reimplement discovery, infer shell commands, send its own process signals, or create a second saved-project store.
- Provider adapters are read-only. They may decode only fields PortDeck renders and must not deploy, restart, cancel, retry, configure, scale, link, delete, read secrets or application data, mutate CLI context, or change credentials.
- Monitored projects are read-only inputs. Never modify their manifests, lockfiles, environment files, provider configuration, or installed dependencies.
- Environment-variable executable overrides are development and test hooks. Invalid authoritative overrides must fail rather than silently falling through to a different runtime.

## Normal workflow

- Preserve unrelated working-tree changes and inspect repo state before editing.
- Start non-trivial tracked work on a named feature branch; use the `codex/` prefix for Codex-created branches.
- Use the root scripts rather than recreating build commands:
  - `npm run build`
  - `npm run test`
  - `npm run typecheck`
  - `npm run verify`
- Launch the Mac app through `portdeck-mac/scripts/run-dev-app.sh`. The process name is `PortDeckMac`; use `pgrep -x PortDeckMac` for a simple launch check.
- Keep generated output in ignored build directories. Do not commit `.build`, `dist`, `node_modules`, coverage, logs, or runtime state.

## Verification

Match verification to the change:

- Markdown-only changes: verify links and commands, confirm intended text is present and stale text is gone, then run `git diff --check`.
- Local discovery, saved-project behavior, status JSON, provider parsing, runtime resolution, authentication handling, or shared logic: add or update focused tests and run the smallest relevant suite plus `npm run verify` before handoff.
- User-visible Mac changes: run relevant tests, launch the real app through the established script, and review the affected menu-bar state. Do not claim native visual coverage that was not actually performed.
- Distribution, signing, notarization, release, or external-state changes: follow the complete release gates below and verify the downloaded artifact, not merely a source build.

## Development and distribution artifacts

Keep these artifacts distinct:

- `portdeck-mac/scripts/run-dev-app.sh` creates a source-development bundle for local use.
- `portdeck-mac/scripts/build-sandbox-probe-app.sh` creates an ad-hoc or development-signed hardened-runtime sandbox feasibility probe. It is not a direct-download artifact, App Store archive, or notarized release.
- The public ZIP must contain a separately assembled, Developer ID-signed release app. Never rename or repackage either development artifact and call it release-ready.

The first direct-download build is an arm64, macOS 14+ beta. Universal packaging is a later compatibility slice. The direct-download build uses hardened runtime without App Sandbox unless local discovery, Docker inspection, saved-project launch/stop, credential access, and every bundled runtime are separately proven under sandboxing. `portdeck-mac/Config/PortDeck.entitlements` currently belongs to the sandbox probe and must not be assumed to be the release entitlement set.

## Direct-download release gates

Do not publish or describe a build as download-ready until every gate passes:

1. Build a clean arm64 release `PortDeck.app` with a real app icon. Keep `CFBundleShortVersionString` and the monotonically increasing `CFBundleVersion` numeric, and require the separate release-version and release-tag metadata to match the GitHub prerelease.
2. Bundle the PortDeck discovery helper, a compatible Node runtime, and the exact managed provider runtimes from the root lockfile: Convex, Supabase, Wrangler, Railway, flyctl, and Netlify. Do not download `latest`, copy runtimes from monitored projects, or depend on a source checkout at application runtime.
3. Treat Vercel and GitHub as optional external integrations backed by the user's installed, authenticated official `vercel` and `gh` CLIs. Missing or expired sessions must produce explicit unavailable or degraded states without breaking the app.
4. Audit every redistributed dependency and include the required third-party license and notice material in the app or DMG.
5. Use a Developer ID Application identity, hardened runtime, secure timestamps, and the minimal direct-download entitlements. Remove development-only entitlements such as `com.apple.security.get-task-allow`.
6. Sign every nested Mach-O executable and code bundle individually from the inside out, then sign `PortDeck.app`. Never use `codesign --deep` to perform signing; it is acceptable only for verification where appropriate.
7. Submit a temporary ZIP containing the signed app with `xcrun notarytool`, wait for acceptance, inspect the notary log, staple the ticket to `PortDeck.app`, and validate the stapled app.
8. Create the final ZIP with `/usr/bin/ditto -c -k --keepParent`, then verify with `codesign --verify --deep --strict`, `spctl`, and `xcrun stapler validate`. Extract the ZIP as a user download and launch the quarantined app from a clean macOS user account with no source checkout, PortDeck CLI, or separate Node installation.
9. Smoke-test local discovery, saved-project start/stop/port switching, every bundled provider runtime, and graceful missing/expired authentication states. Confirm no credentials, user paths, provider tokens, or monitored-project files entered the bundle.
10. Publish manually as a versioned GitHub Release only after explicit approval. The first update path is the latest GitHub Release; do not add or claim an in-app updater until it is separately implemented and verified.

Ask before certificate or notarization setup, notarization uploads, tags, pushes, GitHub Releases, repository visibility changes, or any other public or hard-to-undo external action.

## Secrets and public-repository hygiene

- Never commit signing certificates, private keys, provisioning profiles, notarization credentials, keychain exports, API tokens, `.env` files, auth stores, raw command logs, saved-project profiles, or user data.
- Keep signing and notarization credentials in the macOS Keychain or another approved secret store. Do not place secret values directly in scripts, command history, documentation, or GitHub Actions files.
- Public documentation must not contain personal filesystem paths, certificate fingerprints, Apple team identifiers, private repository details, or screenshots containing account or project data.
- Stage intentionally and review the complete diff for secrets and generated artifacts before any commit.
