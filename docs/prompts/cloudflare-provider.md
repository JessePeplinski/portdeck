# Cloudflare Provider Implementation Prompt

Copy the prompt below into a fresh Codex task from the PortDeck repository.

---

Implement a read-only Cloudflare Workers and Pages provider in PortDeck.

## Current state

- Repo: `<path-to-portdeck>`
- Start from the latest `main` at or after commit `58b0c7d`.
- The SwiftPM macOS menu-bar app is under `portdeck-mac`.
- Existing providers: Local, Vercel, Convex, GitHub Actions, and Supabase.
- Provider visibility, ordering, selected-only polling, command-palette filtering, app-owned provider models, and last-good snapshot patterns already exist.
- Existing launcher: `portdeck-mac/scripts/run-dev-app.sh`.

## Goal

Add a Cloudflare provider that shows:

- account-wide Cloudflare Pages projects and their latest production deployments;
- repo-linked Cloudflare Workers and their current production deployment state.

The provider is status-only. It must not read application payloads, tail logs, inspect secret values, or modify any Cloudflare or project resource.

## Git and scope

- Create branch `feature/cloudflare-provider` before tracked edits.
- Keep the change focused on Cloudflare Workers/Pages visibility and deployment status.
- Do not push, merge, deploy, or create a PR unless explicitly asked later.
- Leave the marketing site unchanged.
- Do not modify monitored repositories, Wrangler files, package manifests, dependencies, environment files, Workers, Pages projects, deployments, routes, zones, DNS, bindings, D1, KV, R2, Queues, Durable Objects, Containers, secrets, logs, analytics, or authentication state.
- Do not initiate Cloudflare login, install agent skills, or request/copy credentials. Reuse an existing Wrangler session if available.

## Documentation verification

- Before implementation, review the current official Cloudflare changelog and Wrangler documentation.
- Start with the official [general commands](https://developers.cloudflare.com/workers/wrangler/commands/general/), [Workers commands](https://developers.cloudflare.com/workers/wrangler/commands/workers/), [Pages commands](https://developers.cloudflare.com/workers/wrangler/commands/pages/), and [system environment variables](https://developers.cloudflare.com/workers/wrangler/system-environment-variables/) references.
- Run `wrangler --help` and every proposed command with `--help`; do not rely on remembered syntax.
- Confirm the current stable Wrangler version and the actual JSON output contracts before pinning or decoding them.
- Wrangler `4.111.0` was the verified stable release when this prompt was written. Re-check it; use the newly verified stable version if it has changed and document the chosen exact version.
- Verify these read-only commands and flags:
  - `wrangler whoami --json`
  - `wrangler pages project list --json`
  - `wrangler pages deployment list --project-name <name> --environment production --json`
  - `wrangler deployments list --name <worker> --json`
  - `wrangler deployments status --name <worker> --json`
- Use `CLOUDFLARE_ACCOUNT_ID` per process for explicit account scoping. Never change persistent Wrangler account or project configuration.

## CLI and authentication

- Support Wrangler `>=4.111.0 <5.0.0`.
- Resolve `PORTDECK_WRANGLER_BIN` authoritatively, then the user's login shell, `/opt/homebrew/bin/wrangler`, and `/usr/local/bin/wrangler`.
- Never search linked projects or PortDeck's dependency tree, and never bundle or auto-install Wrangler.
- Never search linked projects for their Wrangler executable or alter their dependencies.
- Wrangler owns authentication. Use `wrangler whoami --json` to inspect connection/account state.
- Never invoke `wrangler login`, `wrangler logout`, `wrangler auth token`, deploy commands, or any command that prints/changes credentials.
- Run from a neutral PortDeck-owned temporary directory with `WRANGLER_SEND_METRICS=false`, `WRANGLER_SEND_ERROR_REPORTS=false`, `WRANGLER_LOG=error`, `WRANGLER_LOG_SANITIZE=true`, and explicit `CLOUDFLARE_ACCOUNT_ID` when known.
- Do not read `.dev.vars`, `.env*`, secret files, or Cloudflare credential stores directly.

## Provider discovery

### Pages

- Discover Pages projects account-wide through `wrangler pages project list --json` for each authenticated account.
- Fetch only production deployments through `wrangler pages deployment list --project-name <name> --environment production --json`.
- Decode only fields PortDeck renders: account ID/name, project name, production branch, domains/URLs when present, deployment ID, environment, deployment status, branch, commit SHA/message when safely present, created timestamp, and latest-stage result.

### Workers

- Keep Workers repo-linked for v1 because Wrangler's deployment commands require a Worker name and there is no verified account-wide Wrangler list command that avoids exporting an auth token.
- Derive candidates only from active projects/worktrees already present in the local PortDeck status snapshot.
- Recognize `wrangler.json`, `wrangler.jsonc`, and `wrangler.toml`; parse only the top-level Worker `name` and optional `account_id`. Do not decode bindings, variables, routes, or other application configuration.
- Accept packages that declare Wrangler as a dependency even when configuration lives in a supported parent package directory, following the existing Convex candidate resolver's package/worktree rules.
- Deduplicate candidates by account ID plus Worker name while retaining associated local project names.
- If multiple Cloudflare accounts exist and a Worker has no explicit `account_id`, show an ambiguous-account state rather than prompting, guessing, changing config, or exporting a token.
- Fetch only `wrangler deployments list --name <worker> --json` and `wrangler deployments status --name <worker> --json` from a neutral directory with explicit account scope.
- Do not download Worker source, settings, bindings, routes, secrets, versions, logs, analytics, or content.

## Provider behavior

- Add `.cloudflare` after `.supabase` in the default provider order.
- Fresh users see Local, Vercel, Convex, GitHub, Supabase, Cloudflare.
- Existing preferences append Cloudflare visibly without resetting order or hidden choices.
- Include Cloudflare in hide/reorder controls and command-palette source switching.
- Hidden or unselected Cloudflare must not poll.
- Poll immediately when selected and every 60 seconds afterward.
- Leaving or hiding the tab cancels polling; manual refresh fetches immediately.
- Prevent overlapping refreshes.
- Preserve the last successful Pages and Workers snapshots during rate limits, malformed output, authentication expiry, runtime errors, or other transient failures.
- Reordering tabs must not recreate the model or discard either snapshot.

## Status and presentation

- Model Pages and Workers as distinct resource kinds in one Cloudflare provider.
- Normalize only statuses verified from the pinned JSON contracts. At minimum present clear Healthy, Deploying, Degraded, Gradual rollout, Paused, and Unknown states where the upstream values support them.
- Unknown future values must map to Unknown rather than failing the response.
- Sort failed/degraded and active transitions first, then unknown/paused, then healthy resources alphabetically.
- Add provider-specific search across resource kind, project/Worker name, associated local project, account, branch, commit, URL, raw status, and normalized status.
- Show compact Cloudflare-orange rows with resource-kind labels, status badges, last deployment time, production URL when available, and safe dashboard links.
- Provide explicit states for missing runtime, incompatible runtime, authentication required, multiple-account ambiguity, no Pages/Worker resources, connected resources, partial Pages-versus-Workers failure, rate limiting, and degraded refresh with retained data.
- Authentication-required UI may offer a copyable `wrangler login` command, but it must never launch or complete login.

## Architecture

- Put runtime resolution, process execution, parsing, candidate resolution, status types, sorting, and search in `PortDeckCore`.
- Put polling ownership, snapshot preservation, connection state, and SwiftUI presentation in `PortDeckMac`.
- Add the Cloudflare model as an app-level `@StateObject` and add independent `cloudflareSearchText` in `StatusView`.
- Keep Pages and Workers refresh results independently preservable so one side can degrade without erasing the other.
- Do not change the local `portdeck status --json` contract unless candidate discovery proves a missing general-purpose package/config field; prefer the existing status/project/worktree paths first.
- Update `docs/architecture.md`, `docs/distribution.md`, `docs/app-store-readiness.md`, `docs/provider-roadmap.md`, and `TODO.md` with the final verified runtime/auth/read-only boundary and completion state.

## Tests

Add focused Swift coverage for:

- runtime precedence, exact-version validation, and authoritative override failure;
- exact command arguments, neutral working directory, account scoping, and telemetry/error-report suppression;
- authentication, multiple-account, missing-runtime, incompatible-runtime, rate-limit, transient, and malformed states;
- verified `whoami`, Pages project/deployment, and Worker deployment JSON decoding;
- defensive unknown status handling;
- JSON/JSONC/TOML Worker-name candidate discovery without reading unrelated config fields;
- candidate deduplication across worktrees and account ambiguity;
- Pages/Workers independent snapshot preservation and partial failure;
- sorting, search, timestamps, production URLs, and safe dashboard links;
- immediate plus 60-second polling, cancellation, manual refresh, and overlap prevention;
- default provider inclusion, migration of stored preferences, hidden-provider command-palette filtering, and no polling while hidden/unselected;
- provider model/snapshot preservation after tab reorder.

## Verification

- Run focused Swift tests during implementation.
- Run `git diff --check` and complete `npm run verify`.
- Launch through `portdeck-mac/scripts/run-dev-app.sh` and leave the final app running.
- Visually verify Cloudflare presentation, Workers/Pages grouping, search, refresh, hide/reorder, command palette, polling cancellation, persistence after relaunch, and every connection/setup state available locally.
- If an existing Wrangler session is authenticated, verify real read-only rendering without exposing project names, account IDs, tokens, or other private values in the handoff. If not authenticated, verify the authentication-required state and do not initiate login.

## Final handoff

- Report the branch, pinned Wrangler version, implemented Pages/Workers boundary, checks, visual verification, and anything unverified.
- Explicitly confirm that no monitored repository, Wrangler configuration, Cloudflare credential, Worker, Pages project, deployment, route, zone, DNS record, binding, database, storage resource, queue, secret, log stream, analytics setting, or external provider state was modified.

---
