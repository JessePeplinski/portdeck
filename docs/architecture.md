# PortDeck Architecture

This PortDeck repository contains two runtime surfaces that share one local application model. The static marketing site lives independently in [`portdeck-site`](https://github.com/JessePeplinski/portdeck-site).

## Repo Boundaries

- `portdeck-app` is the CLI and discovery engine. It owns process, port, Git worktree, and Docker discovery, and exposes that model through `portdeck status --json`.
- `portdeck-mac` is the native macOS menu bar app. It consumes stable status JSON and renders it. It must not reimplement `lsof`, Git, Docker, or process discovery.
- `docs` records product architecture, distribution decisions, and the status JSON contract.

The CLI/helper and Mac app remain one product repository because the app packages the helper, consumes its versioned status contract, and verifies both in one release. The site has no runtime ownership and consumes only public release URLs, so it can deploy independently.

## Data Flow

```text
local machine state
  -> portdeck-app discovery
  -> portdeck status --json
  -> portdeck-mac rendering
```

The CLI is the boundary between machine inspection and UI. The Mac app can poll, cache, filter, and render the JSON, but discovery changes belong in `portdeck-app`.

Public URLs and tunnels are exposure metadata on top of local runtime state. A public ngrok URL can point at a local listener, but it does not replace the listener as service identity. Raw local ports, processes, containers, and worktrees remain the diagnostic truth.

## External Provider Data

Cloud provider status is a separate adapter boundary from local runtime discovery. The Mac app may call an installed vendor CLI when that CLI owns authentication and exposes a stable structured API. Provider adapters must decode only the fields PortDeck renders and must not copy provider credentials into PortDeck storage.

The first adapter reuses Vercel CLI 50.5.1 or newer. Vercel CLI owns device-flow login and the active team context. PortDeck uses `vercel api /v10/projects` as a paginated project baseline, enriches the active scope once through `vercel api /v2/teams/{teamId}`, then overlays the account-wide `vercel api /v7/deployments?limit=100&target=production` activity feed by project ID. This path is read-only and does not change the `portdeck status --json` contract.

```text
Vercel account
  -> Vercel CLI authenticated session
  -> 60-second project baseline + 2-second production deployment activity
  -> portdeck-mac provider adapter
  -> Vercel live-services view
```

The project and team baseline refreshes when the Vercel view opens and about every 60 seconds. A failed team-name lookup falls back to the generic active-team label without hiding valid projects. Recent production deployment activity polls with one account-wide request about every two seconds while that view remains active, without showing the header spinner or making per-project enrichment calls. The adapter decodes only stable project framework/production-branch data plus deployed branch, commit SHA/message, source, build timing, inspector URL, and bounded credential-redacted failure detail. It ignores author identity and unrelated deployment metadata. The view shows the live cadence and counts up from the last successful activity check. Leaving the Vercel view cancels both provider polling loops. A transient activity-feed failure preserves the last successful project and deployment snapshot, and a failed newest attempt retains the prior public production alias.

The Convex adapter is intentionally repo-linked rather than account-wide. PortDeck derives candidate package directories only from projects and worktrees in the current local status snapshot and keeps packages that declare a Convex dependency. It resolves those package names to explicit default production deployments through Convex's read-only Management API, using the existing Convex CLI access token from `~/.convex/config.json` transiently without copying or persisting it. Health insights run through PortDeck's own exact Convex CLI 1.42.1 runtime, targeted with the fully qualified `team:project:prod` reference rather than trusting the package's `.env.local` deployment or executable.

```text
active local project/worktree snapshot
  -> Convex package candidate resolution
  -> Convex Management API default-production resolution
  -> PortDeck-managed Convex CLI 1.42.1 authenticated session
  -> `convex insights --json --deployment team:project:prod`
  -> 60-second production health snapshot
  -> portdeck-mac Convex view
```

Runtime lookup is deterministic: `PORTDECK_CONVEX_BIN` is an explicit test/development override, a packaged direct-download build uses `Contents/Resources/ProviderRuntimes/convex/bin/convex`, and a source checkout walks upward from the process and app bundle roots to PortDeck's root `node_modules/.bin/convex`. Every resolved executable must report exactly 1.42.1 before PortDeck caches or uses it. PortDeck never searches linked projects for a Convex executable and never installs or updates their dependencies.

The Convex view reports the production deployment name and 72-hour OCC/resource-limit insights exposed by the structured CLI response. Management API metadata and CLI health collection are separate stages, so a missing or failed managed runtime degrades the row to **Health unavailable** while preserving the production deployment name and dashboard link. It shows PortDeck's last successful health check, cancels polling when the view closes, and preserves the last successful health snapshot on transient command failures. This path is read-only: it does not deploy functions, inspect application data, mutate deployment settings, or write credentials.

The GitHub Actions adapter is also repo-linked and read-only. It accepts only normalized `https://github.com/<owner>/<repo>` values already present on projects and worktrees in the current `portdeck status --json` snapshot, deduplicates worktrees that point to the same repository, and never rescans Git remotes from Swift. GitHub CLI owns authentication; PortDeck checks that session with `gh api user` but never copies, logs, or stores its token.

```text
active local project/worktree snapshot
  -> normalized GitHub repository URL candidates
  -> GitHub CLI authenticated session
  -> repository default branch metadata (five-minute cache)
  -> latest default-branch workflow run per workflow
  -> 30-second GitHub Actions health snapshot
  -> portdeck-mac GitHub view
```

Runtime lookup is deterministic: `PORTDECK_GH_BIN` is an authoritative development/test override, then PortDeck checks the user's login shell and standard Homebrew paths. Repository metadata comes from `GET /repos/{owner}/{repo}`. Workflow health comes from `GET /repos/{owner}/{repo}/actions/runs?branch={default_branch}&per_page=50`; requests are serialized and limited to active local repositories rather than scanning the GitHub account.

Default-branch metadata is cached for about five minutes, while workflow runs poll every 30 seconds only while the GitHub tab is active. Leaving the tab cancels the polling task. Transient CLI/API errors, expired authentication, and rate limits preserve the last successful repository metadata and workflow health and surface an inline degraded warning; they never become failed workflow states. PortDeck honors GitHub rate-limit reset/retry headers before making another request. This path cannot rerun, cancel, dispatch, or modify workflows, repositories, settings, or credentials.

The Supabase adapter is account-wide and read-only. It reuses the Supabase CLI's existing authenticated session and invokes only `supabase projects list --output-format json`, which lists projects accessible to that account without reading application tables or other project data. PortDeck decodes only the project reference, name, organization identifiers, region, platform status, and optional creation timestamp. It never copies, logs, renders, or persists the CLI access token.

```text
Supabase account
  -> Supabase CLI authenticated session
  -> `supabase projects list --output-format json`
  -> normalized account project status
  -> 60-second Supabase snapshot
  -> portdeck-mac Supabase view
```

Supabase runtime lookup follows the PortDeck-managed provider contract: `PORTDECK_SUPABASE_BIN` is an authoritative development/test override, a packaged direct-download build uses `Contents/Resources/ProviderRuntimes/supabase/bin/supabase`, and a source build walks upward only from the PortDeck executable and bundle to the root `node_modules/.bin/supabase`. Every resolved executable must report exactly Supabase CLI 2.109.1 before PortDeck caches or uses it. The root npm dependency and lockfile own that source-build version; PortDeck never searches monitored projects for a Supabase executable or changes their dependencies.

The CLI process runs from a neutral temporary directory with `SUPABASE_TELEMETRY_DISABLED=1`, so the account-wide command does not inspect a linked project's Supabase directory or emit CLI analytics. The packaged resource path is a contract for a later distribution step; this slice does not embed or sign the complete Supabase runtime tree.

The Supabase view polls immediately when selected and every 60 seconds afterward. Leaving or hiding the tab cancels its polling task, while manual refresh starts an immediate fetch. Successful responses replace the snapshot, including a legitimate empty project list. Missing or incompatible runtimes, expired authentication, rate limits, malformed output, and transient CLI failures retain the last successful snapshot and show an inline degraded warning. This path cannot create, delete, link, pause, restore, configure, migrate, query, deploy, or otherwise modify Supabase projects, databases, schemas, data, auth, storage, functions, secrets, branches, or credentials.

The Cloudflare adapter combines account-wide Pages visibility with repo-linked Workers. Wrangler 4.111.0 owns authentication and PortDeck invokes only `whoami --json`, Pages project and production-deployment list commands, and Worker deployment list/status commands. The current Pages JSON format is a presentation contract rather than the raw API object, so PortDeck deliberately renders only project names, domains, Git-provider flags, relative modification/status values, deployment IDs, branch, short commit SHA, deployment URL, and the CLI-provided dashboard URL. It does not invent production branches, commit messages, exact timestamps, or raw stage values that Wrangler omits.

```text
Wrangler authenticated accounts
  -> account-scoped Pages project + production deployment lists
active local project/worktree snapshot
  -> top-level Wrangler name/account_id candidate resolution
  -> account-scoped Worker deployment list + status
  -> independent 60-second Pages and Workers snapshots
  -> portdeck-mac Cloudflare view
```

Cloudflare runtime lookup is deterministic: `PORTDECK_WRANGLER_BIN` is authoritative, direct-download packaging uses `Contents/Resources/ProviderRuntimes/cloudflare/bin/wrangler`, and source builds walk upward only from PortDeck roots to the root `node_modules/.bin/wrangler`. Every executable must report exactly 4.111.0. Commands run in a private PortDeck temporary directory with telemetry and error reporting disabled, log sanitization enabled, and Wrangler's default log level preserved because Pages emits its structured JSON through that logger; PortDeck captures stderr separately and discards it after successful commands. PortDeck never searches monitored repos for Wrangler, reads credential stores, exports a token, or starts login.

Pages status is limited to successful relative-time output, active deployment work, failures, cancellations, and unknown future values. Workers expose active traffic and percentage-split gradual rollouts, not general runtime health or a paused state. Unscoped Workers are queried only when exactly one authenticated account exists; multiple accounts produce an explicit ambiguous state without guessing or polling. Pages and Workers preserve last-good data independently across rate limits, expired auth, malformed output, and transient command failures. The adapter never reads payloads, logs, secrets, bindings, routes, zones, DNS, analytics, D1, KV, R2, Queues, Durable Objects, Containers, or application data, and it cannot modify any Cloudflare resource.

The Railway adapter is account-wide and strictly read-only. Railway CLI 5.26.2 owns authentication. PortDeck validates that exact runtime, checks the existing session with `railway whoami --json`, lists accessible projects and workspaces once with `railway list --json`, then requests production services with explicit project and environment scopes. A single `railway deployment list ... --limit 1 --json` request per service enriches the latest deployment with whitelisted branch and commit metadata when present.

```text
Railway CLI authenticated session
  -> account-wide `railway list --json`
  -> scoped production `railway service list`
  -> scoped latest `railway deployment list --limit 1`
  -> independently retained project/service snapshots
  -> 60-second portdeck-mac Railway view
```

Runtime lookup is deterministic: `PORTDECK_RAILWAY_BIN` is authoritative, direct-download packaging uses `Contents/Resources/ProviderRuntimes/railway/bin/railway`, and source builds walk upward only from PortDeck roots to the root `node_modules/.bin/railway`. An invalid override never falls through. Commands run from a private PortDeck directory with `RAILWAY_NO_TELEMETRY=1` and `DO_NOT_TRACK=1`; inherited `RAILWAY_TOKEN` and `RAILWAY_API_TOKEN` values are removed so PortDeck uses only the Railway CLI-owned user session.

The adapter decodes project/workspace identity, production environment identity, services, current/latest deployment state and time, whitelisted branch/commit metadata, replica/region summaries, and public HTTPS URLs. It ignores email, variables, volumes, application configuration, private networking, logs, metrics, and unrelated deployment metadata. `railway status` and `railway service status` are not polling commands because their broader or redundant payloads are unnecessary. Scoped requests share a four-command concurrency limit. Partial failures preserve unaffected projects and prior service metadata, while projects without production remain visible with an explicit unavailable state.

Railway polls immediately and every 60 seconds only while selected and visible. Leaving or hiding the tab cancels its owner task, automatic overlap is rejected, and manual refresh bypasses the timer. The provider cannot deploy, redeploy, restart, link, unlink, configure, scale, delete, open shells, read logs or variables, or modify Railway resources, local CLI context, credentials, or monitored projects.

The Fly.io adapter is account-wide and strictly read-only. PortDeck validates exactly flyctl 0.4.71 for Darwin, checks only whether the CLI-owned session succeeds, lists organizations and apps once, then enriches each app through explicitly scoped status and release commands. All app-scoped commands share one four-command concurrency limit.

```text
flyctl authenticated session
  -> `flyctl orgs list --json`
  -> `flyctl apps list --json`
  -> scoped `flyctl status --app <name> --json`
  -> scoped `flyctl releases --app <name> --json`
  -> retained app/Machine/check/release snapshots
  -> 60-second portdeck-mac Fly.io view
```

Runtime lookup is deterministic: `PORTDECK_FLY_BIN` is authoritative, direct-download packaging uses `Contents/Resources/ProviderRuntimes/fly/bin/flyctl`, and source builds may use only PortDeck's `.build/provider-runtimes/fly/bin/flyctl` staging path found upward from PortDeck executable or bundle roots. An invalid override never falls through, PATH and Homebrew are not searched, and PortDeck never downloads flyctl at runtime or looks in monitored repositories.

Fly commands run directly through `Process` from a private `0700` PortDeck temporary directory with separate `0600` stdout/stderr files. Successful stderr is discarded, displayed failures are bounded and credential-redacted, inherited Fly token/context variables are removed, telemetry is disabled, and cancellation terminates the child before any result can apply. PortDeck uses only flyctl's user session and never reads credential/config files or invokes login.

The adapter decodes organization slug/name; app identity, status, deployed flag, hostname, safe HTTPS URL, and current release version; Machine identity/name/state/region/host status/update time; check name/status/time; and latest release identity/version/status/description/time. It deliberately ignores authenticated and release-user email, Machine config/environment, private IPs, image references, events, services, commands, files, mounts, sizing, metadata, secrets, networking, certificates, DNS, billing, metrics, logs, and SSH data.

`apps list` is authoritative membership, app status is authoritative Machine/check state, and releases are optional enrichment. Legitimate empty lists replace old state; scoped failures preserve only the affected last-good data; release data is retained only when its version still matches the current status version; global transient/rate-limit failures keep the last-good snapshot visibly stale. App deployed state alone is never called healthy, and a Machine without checks renders **No checks** rather than **Healthy**. The provider cannot deploy, restart, scale, start, stop, suspend, destroy, SSH, proxy, read logs/secrets/configuration, or mutate apps, Machines, releases, volumes, certificates, networks, credentials, CLI context, or monitored projects.

The Netlify adapter is account-wide and strictly read-only. PortDeck validates exactly Netlify CLI 26.2.0 for Darwin with Node.js 20.12.2 or newer, uses only the CLI-owned authenticated user session, lists every accessible site once, and enriches each site with its latest production deployment. The site list is the authoritative membership boundary; PortDeck treats the CLI's 1,000-site pagination ceiling as incomplete rather than silently presenting a partial account.

```text
Netlify CLI authenticated session
  -> `netlify sites:list --json`
  -> scoped `netlify api listSiteDeploys --data {site_id, production: true, per_page: 1}`
  -> retained site/latest-production-deployment snapshots
  -> 60-second portdeck-mac Netlify view
```

Runtime lookup is deterministic: `PORTDECK_NETLIFY_BIN` is authoritative, direct-download packaging uses `Contents/Resources/ProviderRuntimes/netlify/bin/netlify`, and source builds may use only PortDeck's root `node_modules/.bin/netlify`. An invalid override never falls through. PATH, Homebrew, user configuration directories, and monitored repositories are not searched, and PortDeck never downloads a Netlify CLI at runtime.

Netlify commands run directly through `Process` from a private `0700` PortDeck temporary directory with separate `0600` stdout/stderr files. The runner refuses a directory beneath a Netlify project state file, discards successful stderr, bounds and credential-redacts failures, removes inherited Netlify token, site, API, proxy, debug, and test endpoint variables, disables telemetry/update prompts/color, and terminates children on cancellation. PortDeck never invokes login or reads Netlify credential files directly.

The adapter decodes only account identity; site identity/name/public URL/admin URL; and latest production deployment identity/state/time/public URL/dashboard URL. It deliberately ignores environment variables, forms, functions, DNS, build configuration, deploy logs, collaborators, billing, repository metadata, plugins, secrets, and unrelated deployment fields. Safe links are restricted to public HTTPS URLs and canonical `app.netlify.com/sites/...` dashboard routes.

Site-scoped deployment requests share one four-command concurrency limit. Legitimate empty lists replace old membership or deployment state. A scoped failure preserves only that site's last-good deployment when site identity still matches; global transient and rate-limit failures retain the last-good account snapshot visibly stale. Unknown future deployment states render Unknown rather than Healthy. The provider cannot deploy, retry, cancel, rollback, lock, publish, build, configure, read logs/environment variables, log in, link/unlink sites, or mutate Netlify resources, credentials, CLI context, or monitored projects.

## Control Boundary

`portdeck-app` also owns focused service control actions that depend on discovered process or container identity. `portdeck-mac` must call those actions through the CLI instead of sending signals, stopping containers, or re-resolving owners in Swift.

The current control surface is `portdeck stop --service-id <id> --json`. The CLI refreshes the current status snapshot, finds the service by its status JSON `id`, and stops only safely identified process or Docker services.

Saved projects use the same boundary. `portdeck-app` owns read-only command suggestions, versioned private profile storage, canonical-folder merging, port checks, detached process-group ownership, bounded current-run logs, and start/stop/restart actions. For Add Running Project, Swift passes the selected service IDs and the helper may reduce a recognized running process to a stable reusable command; it never copies raw session flags or credentials. Swift renders the JSON and invokes those actions; it does not infer commands, store shell recipes, or manage child processes itself.

A profile stores only stable ID, display name, canonical folder, confirmed command template, and optional port. The `{port}` placeholder is the complete v1 port-switching contract. Commands without it remain start/stop capable. Existing project-level orchestration such as Compose or `concurrently` stays inside the confirmed command, while normal discovery remains authoritative for every child process, container, and listener it creates.

The launcher uses the user's login shell and a detached process group. Stop sends graceful `SIGTERM` to the owned group and does not escalate to force-kill. Port changes persist only after the new port binds; failed changes leave the profile's previous port intact and expose a start-again recovery action. Processes discovered under the same canonical folder without a live ownership record render once as running outside PortDeck and require explicit takeover confirmation.

The Mac app keeps **Local** as the leftmost navigation item and presents saved launchers in a fixed **Projects** tab immediately after it. Projects is the intentional control surface: it keeps stopped profiles visible and exposes one primary Add Running Project action beside search, plus Start, Stop, Open, port changes, and a jump to the live Local view. The empty state explains that a project must be running without repeating actions or exposing a folder-picker setup path. Local remains an observation surface and renders only discovered services; stopped profiles and saved-project state do not create Local cards. Unsaved running groups expose a visible **Add to Projects** action. Projects uses the Local polling loop because saved ownership and child services are reconciled through the same status payload. The app opens on Local for a fresh user and persists the most recently selected Projects/provider tab afterward.

## Mac App Direction

The source-built Mac app shells out to the built CLI JavaScript and decodes the JSON through Swift models. The local arm64 release candidate bundles one Node 24 ESM helper artifact and Node.js 24.18.0 at `Contents/Resources/PortDeckRuntime`, making Local discovery and saved-project controls independent of a source checkout, PortDeck CLI installation, or system Node.js installation. Runtime resolution checks authoritative `PORTDECK_NODE` and `PORTDECK_CLI` overrides first, then the packaged runtime, then the source-checkout helper and system Node development paths. Invalid overrides and incomplete packaged runtimes fail explicitly instead of falling through.

That local candidate is an unsandboxed, ad-hoc-signed packaging proof. It does not bundle managed provider runtimes and is not a public direct-download artifact. The App Store build compiles launcher controls out until the bundled-helper, Node JIT entitlement, and process-control design are separately proven under App Sandbox. Source, local-candidate, future Developer ID direct-download, and App Store paths all keep the same status JSON boundary so CLI dogfooding, app rendering, and future automation stay aligned.

Provider tab visibility and ordering belong to an app-owned configuration model in `portdeck-mac`; they do not change the CLI status contract or any provider adapter. The model persists one canonical `UserDefaults` payload containing ordered provider identifiers and visibility. Decoding filters unknown and duplicate identifiers, appends newly introduced providers visibly in default order, and resets malformed or all-hidden payloads to Local, Vercel, Convex, GitHub, Supabase, Cloudflare, Railway, Fly.io, and Netlify. At least one provider must remain visible.

The provider configuration model keeps selection as runtime state, while the Mac view persists the last top-level Projects/provider tab separately. Fresh installs default to Local. On relaunch, a still-visible provider is restored; a hidden or unavailable provider falls back to the first visible provider. Hidden providers are omitted from tabs and command-palette source actions.

All provider models remain app-owned above the tab view, so changing tab order does not recreate clients or discard last-good snapshots. Polling is keyed only to the selected top-level tab: Local uses its five-second discovery loop while either Local or Projects is selected, and Vercel, Convex, GitHub, Supabase, Cloudflare, Railway, Fly.io, and Netlify retain their provider-specific cadences. Hiding or leaving a provider cancels its polling task. Convex, GitHub, and Cloudflare Workers use the last available local status snapshot until Local or Projects refreshes it again; account-wide Supabase, Cloudflare Pages, Railway, Fly.io, and Netlify do not depend on local discovery.

Local retains its last successful decoded status and raw JSON when a later discovery command fails. The last-successful timestamp advances only after a valid snapshot, while a bounded credential-redacted error marks the retained view as degraded. Successful refreshes preserve the existing project, worktree, service, and unknown-service order for still-present identities so five-second polling does not cause avoidable row movement; newly discovered identities append in discovery order.

## Future Workspace Awareness

Workspace and package awareness belongs in the discovery/status layer first. Parent repos can contain multiple subfolders, apps, or packages, but `portdeck-app` should resolve the most specific package or subcontext and expose it in status JSON. `portdeck-mac` should render that grouping once the contract supports it.
