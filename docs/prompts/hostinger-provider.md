# Read-only Hostinger Provider

## Goal

Add an account-wide Hostinger provider to PortDeck using only the user's installed official Hostinger CLI. Show hosted websites and their Hostinger enabled state without changing remote resources, authentication, local CLI context, or monitored repositories.

## Current verified CLI contract

- Official CLI: [`hostinger/api-cli`](https://github.com/hostinger/api-cli)
- Verified baseline: `v3.7.0`
- Install: `brew install hostinger/tap/hostinger`
- Version: `hostinger version`
- Read-only data: `hostinger hosting websites list --page <n> --per-page 100 --format json`
- Authentication setup: `hostinger hosting websites list --format json` run directly by the user in Terminal

## Boundaries

- Resolve authoritative `PORTDECK_HOSTINGER_BIN`, then the login shell, `/opt/homebrew/bin/hostinger`, and `/usr/local/bin/hostinger`.
- Never bundle, install, upgrade, or download Hostinger CLI.
- Never invoke any Hostinger command except `version` and the paginated website list.
- Pass the standard `.hostinger.yaml` path explicitly; PortDeck must not read or copy the config file.
- Strip inherited `HOSTINGER_API_TOKEN`, `HOSTINGER_API_URL`, `HAPI_API_TOKEN`, `HAPI_API_URL`, and `HOSTINGER_OAUTH_ISSUER`.
- Disable the automatic interactive OAuth path during refreshes with a non-listening loopback issuer. Authentication that requires a browser or refresh must fail closed and send the user to Terminal.
- Decode only domain, enabled state, hosting order ID, parent domain, virtual-host type, and creation time.
- Treat enabled/disabled as Hostinger configuration state, not website uptime or health.
- Require complete, stable pagination and preserve the last successful snapshot on malformed, partial, rate-limited, authentication, or transient failures.
- Refresh once when Hostinger is selected or reopened, expose a manual per-view refresh, and cancel an in-flight request on hide, leave, or app disappearance.
- Do not access files, logs, databases, secrets, usernames, root directories, domains, DNS, VPS, billing, deployments, or any mutation command.

## Verification

- Focused runtime, allowlist, pagination, redaction, model, configuration, and command-palette tests.
- Full Swift suite and `npm run verify`.
- Launch through `portdeck-mac/scripts/run-dev-app.sh`.
- Visually confirm the missing-CLI/authentication state and, when a real CLI session is available, the connected website list.
