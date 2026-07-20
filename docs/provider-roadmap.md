# Provider MVP Roadmap

## MVP definition

PortDeck's current verified provider set is Local, Vercel, Convex, GitHub Actions, Supabase, Cloudflare Workers/Pages, Railway, Fly.io, and Netlify. The remaining two integrations complete the planned provider breadth for the MVP:

1. Render
2. GitLab CI

After these are implemented, provider expansion pauses. The next product work is a unified Problems overview, local-versus-deployed health, state-change notifications, and persistent project profiles. Those features turn the individual integrations into a coherent product instead of an indefinitely growing collection of provider tabs.

## Priority and boundaries

### 1. Cloudflare Workers and Pages

Completed as a read-only Wrangler 4.111.0 adapter. The first slice includes account-wide Pages projects and production deployments plus repo-linked Workers and their active or gradual deployment state. Wrangler's presentation JSON intentionally limits Pages metadata; missing raw fields remain omitted or Unknown. The provider excludes DNS, zones, R2, D1, KV, Queues, Durable Objects, Containers, logs, analytics, secrets, configuration changes, and deployment controls.

### 2. Railway

Completed as an account-wide, read-only Railway CLI 5.26.2 adapter. It lists accessible projects/workspaces, explicitly scopes every production service/deployment request, limits scoped concurrency, strips inherited Railway token variables, and preserves project/service snapshots across partial failures. It does not use or change linked context and cannot deploy, restart, scale, configure, read logs/variables, or mutate Railway resources.

### 3. Fly.io

Completed as an account-wide, read-only flyctl 0.4.71 adapter. It lists organizations and apps, explicitly scopes status and release enrichment by app name, limits all scoped commands to four concurrent requests, strips inherited Fly tokens/context, preserves last-good Machine/check/release data across scoped and global failures, and renders only safe public links. It cannot log in, deploy, restart, scale, start, stop, suspend, destroy, SSH, proxy, read logs/secrets/config, or mutate Fly resources or local context.

### 4. Render

Show workspaces, services, datastores, and latest deployment state. Render's active-workspace model must not be mutated silently; polling must use an explicit workspace scope or fail clearly when the current CLI cannot provide one safely.

### 5. Netlify

Completed as an account-wide, read-only Netlify CLI 26.2.0 adapter. It lists accessible sites, explicitly scopes latest production deployment requests by site, limits all scoped commands to four concurrent requests, strips inherited Netlify tokens/context/endpoints, rejects the CLI's 1,000-site pagination ceiling as incomplete, preserves last-good deployment data across scoped failures, and renders only safe public links. It cannot log in, link sites, deploy, build, retry, cancel, roll back, read logs/environment variables/configuration, or mutate Netlify resources or local context.

### 6. GitLab CI

Match active local repositories with normalized GitLab remotes and show default-branch pipeline health through authenticated `glab` JSON commands. Do not retry, cancel, create, or modify pipelines.

## Shared provider contract

Every provider slice follows the existing PortDeck rules:

- Verify the provider's current official changelog, CLI documentation, stable version, exact command help, and structured output before implementation.
- Prefer the vendor CLI when it owns authentication and provides a stable read-only JSON boundary.
- Pin PortDeck-owned runtimes exactly; never execute `latest` dynamically and never search monitored projects for an executable.
- Keep credentials in the vendor CLI. Never log, render, persist, or copy credentials into PortDeck storage.
- Decode only fields PortDeck renders and treat unknown future statuses defensively.
- Poll only while the provider is selected and visible, cancel on hide/leave, allow manual refresh, and preserve the last successful snapshot during transient failures.
- Keep provider models app-owned so tab reordering cannot discard state.
- Never mutate provider resources, monitored repositories, dependencies, configuration, deployments, data, secrets, or authentication state.
- Add focused runtime/client/model/configuration tests, run `git diff --check` and `npm run verify`, launch with `portdeck-mac/scripts/run-dev-app.sh`, and complete a real visual pass before shipping.

## Post-provider MVP work

Once all six integrations are present, the default experience should stop requiring users to inspect each provider separately:

1. Add a unified Problems overview showing failures, degraded services, paused resources, and active deployment transitions.
2. Match local projects to provider resources using explicit project profiles first, with normalized Git remote/name inference as a fallback.
3. Compare local and deployed state without treating a stopped local service as a production failure.
4. Notify only on meaningful transitions such as healthy to failed, deployment started, deployment failed, and recovery.
5. Keep Neon as the first post-MVP data-provider candidate. Evaluate Firebase only after identifying a useful read-only health contract.

Generic AWS, Azure, and Google Cloud providers are intentionally deferred. Each is multiple products and credential contexts rather than one coherent status surface; add specific services only when user demand identifies the correct boundary.
