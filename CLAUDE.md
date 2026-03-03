# Känni

Elixir/Phoenix LiveView + Rust NIFs (libgit2). No database — git repos + ETS caches.
OTP app `:kanni`, module prefix `Kanni`. No umlaut in code.

## Commands

- `mix compile` — Elixir + Rust NIF
- `mix test` — run tests
- `mix phx.server` — localhost:4420
- `mix format` — format code

## Key Patterns

- **Repo.Worker** — `gen_statem`: initializing → idle → operating → error
- **NIF boundary** — complex data as JSON strings, simple as atoms/tuples
- **Dirty CPU scheduler** for all NIFs (`#[rustler::nif(schedule = "DirtyCpu")]`)
- **Caches** — ETS owned by GenServers, public read
- **Plugins** — behaviour-based (`Kanni.Plugin`), config-activated, zero required. Capabilities: context_provider, event_consumer, action_provider, panel_provider
- **PubSub topics** — `"file_events"`, `"repo:{path}"`, `"repos"`

## Conventions

- Minimal deps — prefer stdlib over libraries
- `docs/` — do not modify without asking
