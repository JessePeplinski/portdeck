# TODO

- [x] Provider configuration: hide and reorder Local, Vercel, Convex, GitHub Actions, Supabase, Cloudflare, Railway, Fly.io, and Netlify tabs with persisted preferences.
- [x] Read-only Supabase provider: account-wide project status through PortDeck's pinned CLI runtime without reading or modifying application data.
- [x] Read-only Cloudflare provider: account-wide Pages deployments plus repo-linked Worker deployment state through pinned Wrangler without exporting credentials or reading application resources.
- [x] Read-only Railway provider: account-wide project/workspace and production service/deployment status through pinned Railway CLI with explicit scopes and no context mutation.
- [x] Read-only Fly.io provider: account-wide organization, app, Machine, check, and release status through pinned flyctl with explicit app scopes and no resource mutation.
- [x] Minimal saved projects: a first-class Projects tab, one confirmed project command, optional `{port}`, private profiles, graceful owned-process lifecycle, stopped-project visibility, visible Local-to-Projects saving, and Command-K actions.

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
- [ ] Extend saved project profiles to explicit provider mappings only after local usage proves the matching need.
- [ ] Bundle and sign the local helper/runtime, then verify the notarized GitHub ZIP from a clean macOS user account before calling saved-project launching download-ready.
