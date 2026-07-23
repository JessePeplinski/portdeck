# PortDeck Context

## Runtime glossary

- **PortDeck runtime**: The bundled Local/Projects execution boundary at `Contents/Resources/PortDeckRuntime`. It contains the PortDeck helper and Node.js needed for local discovery and saved-project controls. It is part of the app bundle.
- **Provider integration**: A read-only adapter and UI for Vercel, Convex, GitHub Actions, Supabase, Cloudflare, Railway, Fly.io, or Netlify. An integration owns its allowed commands, decoding, polling, failure behavior, and presentation.
- **Provider CLI**: A provider's user-installed executable and CLI-owned authenticated session. Provider CLIs are external dependencies; PortDeck does not bundle, install, upgrade, or copy their credentials.

Use **runtime** by itself only for the PortDeck runtime or a language/process runtime such as Node.js. Do not describe an external provider CLI as a PortDeck-managed runtime.

## Distribution invariant

`PortDeck.app` contains the PortDeck runtime and no provider CLI or provider dependency tree. The production verifier enforces the exact bundle contents, a 110 MiB installed limit, a 45,000,000-byte ZIP limit, and absence of `ProviderRuntimes`.

## Provider CLI invariant

External provider CLI resolution is: authoritative `PORTDECK_*_BIN` override, login-shell `command -v`, `/opt/homebrew/bin`, then `/usr/local/bin`. Invalid overrides fail without fallback. PortDeck never searches monitored projects or repository dependencies.
