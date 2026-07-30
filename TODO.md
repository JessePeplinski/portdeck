# TODO

- [x] Provider configuration: hide and reorder Local, Vercel, Convex, GitHub Actions, Supabase, Cloudflare, Railway, Fly.io, and Netlify tabs with persisted preferences.
- [x] Read-only Supabase provider: account-wide project status through PortDeck's pinned CLI runtime without reading or modifying application data.
- [x] Read-only Cloudflare provider: account-wide Pages deployments plus repo-linked Worker deployment state through pinned Wrangler without exporting credentials or reading application resources.
- [x] Read-only Railway provider: account-wide project/workspace and production service/deployment status through pinned Railway CLI with explicit scopes and no context mutation.
- [x] Read-only Fly.io provider: account-wide organization, app, Machine, check, and release status through pinned flyctl with explicit app scopes and no resource mutation.

## Release tooling

- [ ] Add a one-command previous-beta-to-current-beta Sparkle installation verifier, targeted for the beta.16 release workflow.
  - Proposed command: `npm run verify:mac:sparkle-update -- --from <previous-version>`.
  - Use Sparkle's real `SPUUpdater` engine with an automated test-only `SPUUserDriver`.
  - Download the previous public release into an isolated temporary app and preferences environment; never modify `/Applications`, Homebrew, or normal PortDeck preferences.
  - Verify update discovery, the signed DMG download, installation, resulting version/build, Developer ID signature, notarization, Gatekeeper acceptance, and post-update launch.
  - Clean up on success or failure, and run only after the new GitHub release assets and production appcast are live.

## MVP provider sequence

Implement these in order. The boundaries and reasoning live in [Provider MVP roadmap](docs/provider-roadmap.md).

- [x] Cloudflare Workers and Pages status through the CLI-safe JSON subset in [the implementation prompt](docs/prompts/cloudflare-provider.md).
- [x] Railway project, service, and deployment status through the CLI-safe JSON subset in [the implementation prompt](docs/prompts/railway-provider.md).
- [x] Fly.io app, Machine, health-check, and release status through the CLI-safe JSON subset in [the implementation contract](docs/prompts/fly-provider.md).
- [ ] Render service, datastore, and deployment status.
- [x] Netlify site and production deployment status through the strict CLI allowlist in [the implementation contract](docs/prompts/netlify-provider.md).
- [ ] GitLab CI pipeline status for active GitLab repositories.

Once these six providers are complete, stop expanding provider coverage for the MVP and move to:

- [ ] Unified Problems overview across local services and every provider.
- [ ] Local-versus-deployed project matching and health comparison.
- [ ] Notifications for meaningful state transitions, not repeated polling failures.
