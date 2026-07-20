# PortDeck Status JSON

`portdeck status --json` is the contract between discovery, the Mac app, and future automation.

## Current Contract

The current schema version is `"0.1"`.

Top-level fields:

- `schemaVersion`: contract version string.
- `generatedAt`: ISO timestamp for the status snapshot.
- `groups`: known project groups.
- `unknown`: running services that could not be attached to a project/worktree.
- `warnings`: non-fatal discovery issues.
- `portConflicts`: optional top-level incidents for same-port endpoint conflicts after PortDeck probes the ambiguous URLs.
- `exposures`: optional top-level public/local exposure records, currently ngrok tunnels discovered through the local ngrok agent API.

Project groups:

- `projectName`: display name, usually derived from the Git root or Docker Compose project.
- `repoRoot`: Git primary repo root when known.
- `remoteUrl`: raw `origin` Git remote URL when PortDeck can normalize it to a supported repository URL and it contains no URL userinfo. Credential-bearing remotes omit this field.
- `repositoryUrl`: browser URL for the Git repository when PortDeck can safely infer one. Currently this is GitHub-only.
- `worktrees`: groups of services under a Git worktree or Docker-only grouping.
- `savedProject`: optional saved-project header metadata. Saved projects stay in `groups` while stopped and may have no worktrees or service rows.

Saved project metadata:

- `id`: stable private profile identifier.
- `state`: `stopped`, `starting`, `running`, `external`, or `failed`. `external` means discovery found services under the saved folder without a live PortDeck ownership record.
- `port`: optional confirmed primary port.
- `supportsPortSwitching`: whether the confirmed command contains the `{port}` placeholder.
- `logPath`: bounded current-run log path when available.
- `lastError`: bounded launch failure detail when the last PortDeck-owned run failed.
- `previousPort`: last saved port after an attempted port change failed. The profile's own `port` remains unchanged until a new process binds successfully.

Worktree groups:

- `name`: branch, worktree, or fallback grouping name.
- `path`: worktree path when known.
- `branch`: Git branch when known.
- `remoteUrl`: raw `origin` Git remote URL when PortDeck can normalize it to a supported repository URL and it contains no URL userinfo. Credential-bearing remotes omit this field.
- `repositoryUrl`: browser URL for the Git repository when PortDeck can safely infer one. Currently this is GitHub-only.
- `services`: detected services for that group.

Services:

- `id`: stable-enough snapshot identifier for the detected service.
- `name`: display name inferred from command, process, Docker service, or container.
- `source`: discovery source such as `process`, `docker`, `registered`, or `portdeck-run`.
- `status`: service state such as `running`, `stale`, `stopped`, or `unknown`.
- `port`, `url`, `address`, and `protocol`: network details when known. `url` remains the preferred URL for opening the service. It uses the preferred concrete listener host/IP when discovery finds one, and falls back to `localhost` for wildcard binds such as `*`, `0.0.0.0`, or `::`.
- `listeners`: optional endpoint list for the service. Each listener preserves the discovered bind address and generated URL.
- `localhostCollision`: optional metadata explaining same-port ambiguity when `localhost:<port>` may not route to the same service as a concrete loopback URL.
- `endpointHealth`: optional probe result for `service.url` when the service belongs to an ambiguous same-port set.
- `exposures`: optional public tunnel records attached to this service. These are informational exposure metadata and do not replace `url` or `listeners`.
- `pid`, `processName`, `command`, and `cwd`: process details when known.
- `hostIp`, `containerName`, `containerId`, `containerPort`, and `image`: Docker details when known.
- `activity`: optional runtime activity snapshot. Includes process or container CPU and memory fields when PortDeck can collect them reliably.
- `confidence`: `high`, `medium`, or `low` grouping confidence.
- `subcontext`: optional package or workspace subcontext when the service can be tied to a more specific folder inside the worktree.
- `groupingReason`: optional concise explanation for why PortDeck could not safely attach a service to a project/worktree. This is used for ambiguous Docker attribution and process listeners whose cwd cannot be mapped to Git or a known Codex worktree.

Service actions:

- `portdeck stop --service-id <id> --json` uses the current status JSON `id` as the target handle.
- The stop action refreshes status before acting, so missing or stale identifiers fail cleanly.
- Process services require `pid`; Docker services require `containerId`.
- Unsupported or insufficient identity returns quiet structured JSON rather than raw process or Docker errors.

Saved project commands:

- `portdeck projects list --json` reads the private, versioned profile file.
- `portdeck projects suggest --path <path> [--service-id <id> ...] --json` inspects manifests, lockfiles, Compose files, workspaces, and likely executable repository scripts without changing or running anything. When the app supplies selected running-service IDs, the helper may also return a normalized allowlisted command from those processes. Raw process commands, session flags, and credentials are never copied into a suggestion.
- `portdeck projects save --input <project-json> --json` validates and atomically persists one confirmed name, canonical folder, command template, and optional port.
- `portdeck projects remove --project-id <id> --json` removes a stopped profile.
- `portdeck run start --project-id <id> [--port <port>] --json` starts the confirmed command.
- `portdeck run stop --project-id <id> --json` sends `SIGTERM` to only that PortDeck-owned process group.
- `portdeck run restart --project-id <id> --port <port> --json` checks the target port, gracefully stops the current owned group, and starts on the confirmed port.

Project configuration lives at `~/.portdeck/projects.json` with schema version `"1"`, a private `0700` parent directory, `0600` files, and atomic replacement. Ownership state and bounded logs live beside it but are not user-facing configuration. A malformed profile file is preserved and returned as a warning; PortDeck does not silently reset it.

Service listeners:

- `address`: exact listener address from discovery, such as `127.0.0.1`, `::1`, `*`, `0.0.0.0`, or `::`.
- `family`: optional inferred address family, currently `IPv4`, `IPv6`, or `unknown`.
- `port`: numeric host port.
- `url`: generated HTTP URL for that endpoint. IPv6 loopback is bracketed, for example `http://[::1]:3000`. Wildcard binds use `http://localhost:<port>`.
- `isWildcard`: whether the bind is a wildcard address.
- `isLoopback`: whether the bind is a loopback address.
- `isPreferred`: whether this listener produced `service.url`.

Localhost collision metadata:

- `port`: numeric port with same-port ambiguity.
- `localhostUrl`: `http://localhost:<port>`.
- `message`: short human-readable explanation.
- `conflictsWith`: other services on the same numeric port. Each conflict includes `serviceId`, `name`, and optional `projectName`, `worktreeName`, `url`, and `address`.

Endpoint health metadata:

- `url`: endpoint that was probed.
- `status`: `ok`, `http-error`, `unreachable`, `timeout`, or `unknown`.
- `statusCode`: HTTP status code when a response was received.
- `remoteAddress`: socket peer address when available. This is useful when `localhost` resolves to `::1` while another service is reachable at `127.0.0.1`.
- `latencyMs`: elapsed probe time in milliseconds.
- `error`: short transport error text when the endpoint could not be reached.

Port conflict metadata:

- `port`: numeric port shared by multiple distinct services.
- `severity`: `warning` for ambiguity, or `error` when the endpoint PortDeck would open is unhealthy or returns an HTTP error.
- `title`: short display label such as `Port 3000 conflict`.
- `message`: human-readable explanation, for example `localhost:3000 returns HTTP 500 while 127.0.0.1:3000 returns 200 OK`.
- `endpoints`: probed endpoints for the ambiguous port. Each endpoint includes `url`, optional service identity fields (`serviceId`, `name`, `projectName`, `worktreeName`, `address`), and optional `health`.

PortDeck probes only ambiguous same-port sets. A single service that listens on multiple addresses is not a port conflict, and unrelated services on unique ports do not receive endpoint health by default.

Exposure metadata:

- `id`: stable-enough snapshot identifier for the exposure, such as `ngrok-demo-ngrok-app`.
- `kind`: exposure provider. Currently `"ngrok"`.
- `publicUrl`: external URL exposed by the tunnel.
- `targetUrl`: local target URL reported or normalized from the tunnel configuration.
- `targetHost` and `targetPort`: parsed local target components when available.
- `agentApiUrl`: local agent API URL used for discovery, initially `http://127.0.0.1:4040/api/tunnels`.
- `agentPid` and `agentCwd`: optional ngrok agent process provenance when PortDeck can discover the local process. These fields do not assign tunnel ownership to a worktree.
- `status`: `"attached"` when exactly one running local service matches the target port, `"dangling"` when the target port has no running listener, or `"unknown"` when the target is malformed, non-loopback, missing a port, or ambiguous across multiple local services.
- `attachedServiceId`: service id when `status` is `"attached"`.

Example attached ngrok exposure:

```json
{
  "id": "ngrok-demo-ngrok-app",
  "kind": "ngrok",
  "publicUrl": "https://demo.ngrok.app",
  "targetUrl": "http://localhost:3000",
  "targetHost": "localhost",
  "targetPort": 3000,
  "agentApiUrl": "http://127.0.0.1:4040/api/tunnels",
  "agentPid": 7501,
  "agentCwd": "/repo/acme-web",
  "status": "attached",
  "attachedServiceId": "pid-7502-port-3000"
}
```

Example dangling ngrok exposure:

```json
{
  "id": "ngrok-stale-ngrok-app",
  "kind": "ngrok",
  "publicUrl": "https://stale.ngrok.app",
  "targetUrl": "http://localhost:3000",
  "targetHost": "localhost",
  "targetPort": 3000,
  "agentApiUrl": "http://127.0.0.1:4040/api/tunnels",
  "status": "dangling"
}
```

Example unknown ngrok exposure:

```json
{
  "id": "ngrok-ambiguous-ngrok-app",
  "kind": "ngrok",
  "publicUrl": "https://ambiguous.ngrok.app",
  "targetUrl": "http://localhost:3000",
  "targetHost": "localhost",
  "targetPort": 3000,
  "agentApiUrl": "http://127.0.0.1:4040/api/tunnels",
  "status": "unknown"
}
```

When the ngrok agent API is unavailable, PortDeck omits `exposures` and does not fail status discovery. When a tunnel targets a local port with no listener, PortDeck keeps the tunnel in top-level `exposures` with `status: "dangling"` and adds a warning.

Service activity:

- `cpuPercent`: point-in-time CPU percentage when available.
- `memoryRssBytes`: process resident set size in bytes when available from process discovery.
- `memoryUsageBytes`: Docker container memory usage in bytes when available from Docker stats.
- `memoryLimitBytes`: Docker container memory limit in bytes when available from Docker stats.

Activity fields are optional and may be omitted when process metrics or Docker stats are unavailable. Request counts are intentionally not part of this contract yet because listening-port discovery is not a trustworthy request source; that requires a future proxy or logging integration.

Preferred listener rules:

- `127.0.0.1` is preferred first.
- `::1` is preferred second and is rendered as a bracketed URL.
- Other concrete addresses are preferred before wildcard binds.
- Wildcard binds (`*`, `0.0.0.0`, `::`, `[::]`) fall back to `localhost`.

Service subcontext:

- `type`: currently `"package"`.
- `name`: package manager name when available from `package.json`.
- `displayName`: label consumers can show for the package or subcontext.
- `path`: absolute package/subcontext path.
- `relativePath`: path relative to the Git worktree path, or `"."` for the worktree root package.
- `manifestPath`: absolute path to the `package.json` that identified the subcontext.

Docker attribution:

- Docker services are rendered in the same project/worktree hierarchy as process services when PortDeck can attribute them unambiguously.
- Strong attribution comes from Docker Compose path labels, Compose config file paths, bind mount source paths, or a container working directory mapped back through a bind mount.
- When exactly one Docker host path resolves to one Git worktree, the Docker service is attached to that worktree with `confidence: "high"` and may include `subcontext`.
- When no Docker host path resolves but the Compose project name matches exactly one known Git project with one known worktree, the Docker service is attached there with `confidence: "medium"`.
- When Docker path metadata or Compose project matching points at multiple plausible Git worktrees, the service stays in `unknown` with `confidence: "low"` and `groupingReason`.
- When no Git owner is known, Docker services remain in a Docker/Compose-derived project group instead of failing discovery.
- Published ports and listener URLs remain diagnostic truth. PortDeck does not infer Git ownership from a matching port alone.

Git repository metadata:

- `remoteUrl` and `repositoryUrl` are optional and additive under schema `"0.1"`.
- PortDeck reads `git remote get-url origin` quietly for Git-owned worktrees.
- Supported GitHub origin forms include `https://github.com/<owner>/<repo>.git`, `git@github.com:<owner>/<repo>.git`, and `ssh://git@github.com/<owner>/<repo>.git`.
- `repositoryUrl` normalizes supported origins to `https://github.com/<owner>/<repo>` and removes a trailing `.git`.
- Missing origins, unsupported hosts, unsupported remote syntaxes, and malformed values omit both fields and do not create warnings.

## Compatibility Rules

- Additive fields are allowed in schema version `"0.1"` when existing consumers can ignore them.
- Optional fields may be omitted when discovery cannot safely or reliably find them.
- Field removals, renames, type changes, or semantic changes require a schema version bump.
- Consumers should tolerate unknown fields and should not require optional fields to exist.
- Discovery failures should become `warnings` or `unknown` services instead of making the command fail when a useful partial snapshot can still be returned.

## Ownership

`portdeck-app` owns this contract. `portdeck-mac` consumes it and should keep its Swift models aligned with the documented shape.
