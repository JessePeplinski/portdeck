# Read-only Netlify Provider

## Objective

Add an account-wide Netlify provider to PortDeck after Fly.io. Show accessible sites and each site's latest production deployment state, time, public URL, and safe Netlify dashboard link without changing provider resources, authentication, local CLI context, or monitored repositories.

## Verified CLI contract

- CLI: support `netlify-cli >=26.2.0 <27.0.0`, with Node.js 20.12.2 or newer.
- Package integrity: `sha512-3jQg9WQoa1H74478fHZisj3T8dLM67x4F4Sgi7kROBHzJD9NNCYYw99dKRYWJOtEa1dUNyZu2W4VTdPzA1kjiw==`; license: MIT; tarball: `https://registry.npmjs.org/netlify-cli/-/netlify-cli-26.2.0.tgz`.
- Version evidence: `netlify-cli/26.2.0 darwin-arm64 node-v25.8.1` in the implementation environment. Accept Darwin arm64 or x64 and validate the minimum Node version before caching the runtime.
- Account membership: `netlify sites:list --json`. The command documents that it lists all projects the user can access. The CLI paginates in batches of 100 but stops after 10 pages, so exactly 1,000 returned sites is not authoritative and must surface as incomplete.
- Latest production deployment: `netlify api listSiteDeploys --data '{"site_id":"SITE_ID","production":true,"per_page":1}'`. Every request must carry the exact site ID returned by the account list.
- Authentication: use only Netlify CLI's existing user session. Never invoke login, export a token, read Netlify credential files directly, or accept token inheritance from PortDeck's parent environment.
- PortDeck uses the user's installed Netlify CLI and does not redistribute it.

Official sources verified on 2026-07-16:

- [Netlify CLI repository and installation requirements](https://github.com/netlify/cli)
- [Netlify CLI 26.2.0 release](https://github.com/netlify/cli/releases/tag/v26.2.0)
- [Netlify API authentication and account-wide site listing](https://docs.netlify.com/api-and-cli-guides/api-guides/get-started-with-api/)
- [Netlify OpenAPI operation for site deployments](https://open-api.netlify.com/#operation/listSiteDeploys)
- [Netlify deployment dashboard route documentation](https://docs.netlify.com/deploy/deploy-overview/#share-log-content)

## Runtime resolution

Resolve in this order only:

1. authoritative `PORTDECK_NETLIFY_BIN` development/test override;
2. the user's login shell;
3. `/opt/homebrew/bin/netlify`;
4. `/usr/local/bin/netlify`.

Do not search Netlify configuration directories, monitored repositories, PortDeck dependencies, or arbitrary parent directories. An invalid override is a hard failure and never falls through. Do not download or install a CLI from the app.

## Secure execution boundary

- Execute the resolved binary directly through `Process`; never through a shell.
- Accept only `--version`, `sites:list --json`, and the exact site-scoped `api listSiteDeploys` request above.
- Run from a private `0700` temporary directory outside monitored repositories and fail closed if a `.netlify/state.json` exists in the working directory or any parent.
- Capture stdout and stderr separately in `0600` files. Discard successful stderr; bound and credential-redact displayed failures; always clean up.
- Strip inherited Netlify authentication, site/context, endpoint, proxy, test, and debug variables. Set CI/update/color controls that disable telemetry, update prompts, and interactive output.
- The stripped set is `NETLIFY_AUTH_TOKEN`, `NETLIFY_SITE_ID`, `NETLIFY_ACCOUNT_ID`, `NETLIFY_ACCOUNT_SLUG`, `NETLIFY_API_URL`, `NETLIFY_WEB_UI`, `NETLIFY_PROXY_CERTIFICATE_FILENAME`, `NETLIFY_CLI_EXECA_PATH`, Netlify test telemetry endpoint/wait variables, `NETLIFY_BUILD_DEBUG`, `NETLIFY_DEPLOY_SOURCE`, `CONTEXT`, `DEBUG`, `XDG_CONFIG_HOME`, HTTP/HTTPS proxy variables, inherited CI-provider flags, and inherited update/color controls. PortDeck then sets only `CI=1`, `NO_UPDATE_NOTIFIER=1`, `NO_COLOR=1`, and `FORCE_COLOR=0` for deterministic non-interactive execution.
- Terminate an in-flight process on task cancellation and reject stale results at the model generation boundary.

## Data boundary

Decode only fields rendered by PortDeck:

- account identity evidence exposed by the CLI;
- site ID, name, public URL, and Netlify admin URL;
- deployment ID, state, creation/update/publish time, public deploy URL, and dashboard URL.

Ignore environment variables, forms, functions, DNS, build settings, repository configuration, plugins, collaborators, billing, logs, deploy messages, and unrelated deployment metadata. Public links must be HTTPS and must reject credentials, custom ports, localhost/private hosts, query strings, and fragments. Dashboard links must use canonical `app.netlify.com/sites/...` routes.

## Polling, retention, and presentation

- Poll immediately and every 60 seconds only while Netlify is selected and visible.
- Keep one model-owned refresh task; reject automatic overlap, allow manual refresh, cancel on leave/hide, and terminate active child commands.
- Limit all site-scoped requests to four concurrent commands.
- Treat the site list as authoritative membership. Legitimate empty results replace old state.
- Preserve only the affected site's last-good deployment on a scoped failure when site identity still matches. Preserve the entire last-good snapshot as visibly stale on a global transient or rate-limit failure.
- Map known Netlify states conservatively: `ready` is healthy; `error` is failed; `rejected` is inactive; queued/build/upload/processing/retry states are deploying; unknown future values remain Unknown.
- Present account-grouped site cards with status, deployment time, deployment ID, public URL, dashboard link, stale/partial evidence, search, refresh, and setup guidance. Do not add deploy, retry, cancel, rollback, build, login, link, log, environment, or configuration controls.

## Verification

- Add focused runtime, allowlist, environment, decoding, status, retention, concurrency, cancellation, safe-link, configuration, and app-model tests.
- Run Netlify-focused tests, neighboring provider regressions, the full Swift suite, `git diff --check`, and `npm run verify`.
- Launch through `portdeck-mac/scripts/run-dev-app.sh`, exercise loading, healthy, active deployment, failed, empty, partial, stale, auth-required, missing-runtime, search, refresh, and safe-link states using temporary fixtures, then remove the fixtures and leave the normal development app running.
