# PortDeck Mac App Store Readiness

PortDeck is not ready for App Store Connect. The signed and notarized direct-download app and the sandbox feasibility path remain separate products with different runtime boundaries.

## Confirmed baseline

- The Swift package builds and tests, but `xcodebuild archive` produces a command-line product rather than a complete `.app` target.
- `scripts/build-sandbox-probe-app.sh` assembles a local sandboxed feasibility probe. It is not a submission artifact.
- `scripts/build-release-app.sh` assembles an arm64 direct-download candidate with a bundled local-discovery helper and Node.js 24.18.0. That app is intentionally unsandboxed.
- The direct-download production workflow adds the approved icon, Developer ID signing, notarization, and quarantine verification.
- Provider CLIs are not embedded in either direct-download bundle. Convex, Supabase, Wrangler, Railway, flyctl, Netlify, Vercel, and GitHub integrations execute user-installed external CLIs and reuse their CLI-owned sessions.
- External executable lookup and external CLI credential access are not proven App Sandbox behaviors.
- The bundled Node runtime requires a narrow JIT entitlement under hardened runtime. Its App Store acceptability remains unproven.

Passing the direct-download verifier does not prove App Store compatibility.

## Next App Store slice

1. Create a real macOS application target that archives `PortDeck.app`.
2. Adapt the local-discovery helper boundary to App Sandbox without assuming the direct-download Node entitlement set is acceptable.
3. Give each embedded executable the smallest reviewed signing and sandbox entitlement set.
4. Test listening ports, process identity, cwd, Git/worktrees, Docker, and stop behavior while sandboxed.
5. Keep only the core behaviors that work reliably without temporary entitlement exceptions or privilege escalation.

## Provider boundary

The App Store target must not execute login-shell or Homebrew CLIs or reach into provider CLI credential stores. Each provider needs either:

- a separately reviewed sandbox-compatible authentication/API adapter that preserves the current read-only command and data boundary; or
- omission from the App Store build.

Do not reintroduce the previous bundled provider CLI and `node_modules` trees as an App Store workaround. That would restore the size, signing, licensing, and supply-chain burden while still leaving authentication and sandbox compatibility unresolved.

The future provider implementations must preserve:

- no token copying, logging, or PortDeck-owned provider credential storage;
- no project manifest, lockfile, CLI context, or monitored repository mutation;
- the current read-only resource scopes and bounded polling;
- last-good snapshot behavior across authentication, rate-limit, malformed-output, and transient failures;
- no deployment, restart, configuration, log, secret, shell, or resource-mutation controls.

## Support button policy

Development and direct-download builds may show the optional external Buy Me a Coffee button. It is compiled out when the `APP_STORE` Swift compilation condition is active.

Before submission:

1. Set `APP_STORE` in the App Store target's active compilation conditions.
2. Confirm the external support button is absent.
3. Use StoreKit if an App Store build should accept tips.
4. Re-check the current App Review Guidelines before submission.

## Sandbox probe

Build the local probe with:

```bash
portdeck-mac/scripts/build-sandbox-probe-app.sh
```

The script uses an ad-hoc signature by default. `CODE_SIGN_IDENTITY` may select a local Apple Development identity for development testing. The probe must not be renamed or repackaged as a public release.
