# Railway Provider Implementation Contract

This document records the verified contract for PortDeck's read-only Railway provider.

## Runtime and authentication

- Pin root dependency `@railway/cli` exactly to 5.26.2.
- Resolve `PORTDECK_RAILWAY_BIN` authoritatively, then `Contents/Resources/ProviderRuntimes/railway/bin/railway`, then PortDeck-root `node_modules/.bin/railway`.
- Require exact version output `railway 5.26.2` before caching the executable.
- Use the Railway CLI-owned user session only. Never initiate login or read credential files.
- Remove inherited `RAILWAY_TOKEN` and `RAILWAY_API_TOKEN`; set `RAILWAY_NO_TELEMETRY=1` and `DO_NOT_TRACK=1`.
- Run from a private `0700` PortDeck working directory, capture stdout/stderr separately in `0600` files, discard successful stderr, and sanitize displayed failures.

## Read-only command boundary

PortDeck may invoke only:

```text
railway --version
railway whoami --json
railway list --json
railway service list --project <project-id> --environment production --json
railway deployment list --project <project-id> --environment production --service <service-id> --limit 1 --json
```

`railway status` and `railway service status` were inspected as CLI contracts but are not polling commands. Never invoke login/logout, link/unlink, deploy/redeploy/restart, logs, variables, shell, scale, delete, configuration, or other resource-management commands.

## Rendered data boundary

Decode only workspace ID/name; project ID/name, archived state, and production environment ID; service ID/name; current/latest deployment ID/status/time; whitelisted source branch/commit SHA/message; replica/region summary; and safe public HTTPS URLs. Ignore email, memberships, billing, variables, volumes, configuration, private networking, logs, metrics, application data, and unrelated deployment metadata.

Map only `SUCCESS`, `FAILED`, `CRASHED`, `BUILDING`, `DEPLOYING`, `INITIALIZING`, `WAITING`, `QUEUED`, `REMOVING`, and `REMOVED`; future or malformed values are Unknown. A successful deployment is not general runtime health. Replica evidence is displayed separately.

## Snapshot and UI behavior

- Run one runtime/auth/project baseline, then explicitly scoped production requests with no more than four scoped commands concurrently.
- Preserve projects without production, legitimate empty service lists, unaffected partial successes, and last-good project/service metadata during failures.
- Poll immediately and every 60 seconds only while Railway is selected and visible; cancel on hide/leave and reject automatic overlap.
- Keep the model app-owned so provider reordering cannot discard snapshots.
- Show setup, auth, empty, partial, rate-limit, incompatible-runtime, and retained-data states. Authentication UI may copy `railway login` but never run it.
- Validate production links as HTTPS and dashboard links as Railway project URLs.

## Verification boundary

Use fake identifiers and source-derived fixtures in tests. The local Railway OAuth session was expired during implementation, so real account resource rendering remains unverified unless a later user-managed login provides a session. Never expose real Railway identifiers in logs, fixtures, screenshots, or handoff notes.
