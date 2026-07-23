# Fly.io Provider Implementation Contract

This document records the verified contract for PortDeck's read-only Fly.io provider.

## CLI and authentication

- Support the official native Go CLI at `>=0.4.71 <0.5.0`.
- Resolve authoritative `PORTDECK_FLY_BIN`, then the user's login shell, `/opt/homebrew/bin/flyctl`, and `/usr/local/bin/flyctl`. Never search user projects, `fly.toml`, monitored repositories, or PortDeck dependencies.
- Require `flyctl version --json` to report name `flyctl`, a supported version, Darwin, and a supported architecture before caching. Never download or install at application runtime.
- Use only flyctl's existing user session. Authentication UI may copy `flyctl auth login` but PortDeck never runs it, passes a token, reads credential/config files, or stores identity/credentials.
- Remove inherited Fly token/context/base-URL/logging variables. Set `FLY_SEND_METRICS=0`, `DO_NOT_TRACK=1`, and `NO_COLOR=1`.
- Run directly through `Process` from a private `0700` PortDeck directory with separate `0600` output files. Discard successful stderr, clean command output, bound/redact errors, and terminate the child on cancellation.

## Read-only command boundary

PortDeck may invoke only:

```text
flyctl version --json
flyctl auth whoami --json
flyctl orgs list --json
flyctl apps list --json
flyctl status --app <app-name> --json
flyctl releases --app <app-name> --json
```

Every app-scoped command includes `--app`; no command uses `--config` or a local `fly.toml`. Never invoke login/logout, launch, deploy, restart, scale, start/stop/suspend/destroy, clone/update, SSH/console/proxy, logs, secrets, configuration, volumes, certificates, IP allocation, Postgres management, token creation, dashboard opening, or any other mutation/inspection command.

## Rendered data boundary

Decode only organization slug/name; app stable ID/name/raw status/deployed flag/organization/hostname/safe HTTPS URL/current release version; Machine ID/name/state/region/host status/update time; check name/status/time; and latest release ID/version/status/description/time.

Ignore authenticated and release-user email, Machine configuration/environment, private IPs, images/digests, events/nonces, volumes/mounts, sizing, services/ports/processes/commands/files/metadata/secrets, container internals, private networking, certificates, DNS, billing, metrics, logs, SSH, and unrelated API metadata. Broad status payloads exist only in secure temporary output and are decoded through narrow private types.

Map app `deployed`/`suspended`; Machine `started`/`stopped`/`suspended`/`created`/`destroying`/`destroyed`; host `ok`/`unknown`/`unreachable`; checks `passing`/`warning`/`critical`; and releases `complete`/`failed`/`interrupted`/`pending`/`running`. Future or malformed values are Unknown. A deployed app alone is not healthy, stopped/suspended resources are not automatically failures, and no-check Machines render **No checks**.

## Snapshot and UI behavior

- Treat `apps list` as authoritative membership, status as current Machine/check truth, and releases as optional enrichment.
- Replace legitimate empty app/Machine/release results and remove apps absent from a successful fresh app list.
- Preserve unaffected apps and last-good Machine/check data across scoped status failures. Preserve release enrichment only when its version still matches the current status version.
- Preserve and visibly label the last-good snapshot during global transient/rate-limit failures.
- Run no more than four app-scoped commands concurrently.
- Poll immediately and every 60 seconds only while Fly.io is selected and visible; cancel on hide/leave, reject refresh overlap, and prevent cancelled results from applying.
- Keep the model app-owned so provider reorder cannot discard snapshots. Search is presentation-only.
- Group apps by organization and show compact app cards/Machine rows, separate check evidence, safe HTTPS app URLs, and dashboard links only as `https://fly.io/apps/<validated-app-name>`.

## Packaging and verification boundary

The source slice defines the direct-download resource contract but does not commit, embed, sign, or notarize flyctl. Tests and visual fixtures use temporary executables outside the repository. Real-account rendering is optional only when a pre-existing session already works; never expose real identifiers in fixtures, screenshots, logs, or handoff notes. No monitored repository, Fly configuration/context, credential, app, Machine, release, secret, volume, certificate, network, deployment, or external state may be changed.
