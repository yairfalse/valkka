# Känni — AI-Native Git Command Center

## Architecture

- **Elixir/Phoenix LiveView** — real-time UI, no REST API
- **Rust NIFs (Rustler)** — libgit2 bindings for fast git operations
- **No database** — all state from git repos + ETS caches
- OTP app: `:kanni`, module prefix: `Kanni`

## Key Directories

- `lib/kanni/` — core domain logic
- `lib/kanni_web/` — Phoenix web layer (LiveView, components)
- `native/kanni_git/` — Rust NIF crate (libgit2 bindings)
- `assets/js/hooks/` — LiveView JS hooks (graph, diff viewers)
- `docs/` — design documents (do not modify without asking)

## Supervision Tree

```
Kanni.Supervisor (one_for_one)
├── KanniWeb.Telemetry
├── DNSCluster
├── Phoenix.PubSub (name: Kanni.PubSub)
├── Task.Supervisor (name: Kanni.TaskSupervisor)
├── Kanni.Cache.GraphCache (ETS owner)
├── Kanni.Cache.CommitCache (ETS owner)
├── Kanni.Cache.StatusCache (ETS owner)
├── Kanni.Repo.Supervisor (DynamicSupervisor)
├── Kanni.Watcher.Handler (GenServer)
└── KanniWeb.Endpoint
```

## Key Patterns

- **Repo.Worker** — `gen_statem` with states: initializing → idle → operating → error
- **NIF boundary** — complex data crosses as JSON strings, simple data as atoms/tuples
- **AI Provider** — behaviour pattern, `Null` provider for offline use
- **Caches** — ETS tables owned by dedicated GenServers, public read access

## Commands

- `mix compile` — compiles Elixir + Rust NIF
- `mix test` — run tests
- `mix phx.server` — start on localhost:4420
- `mix format` — format code

## Conventions

- No umlaut in code — `Kanni` not `Känni` (brand stays in UI/docs)
- Dirty CPU scheduler for all NIFs (`#[rustler::nif(schedule = "DirtyCpu")]`)
- PubSub topics: `"file_events"`, `"repo:{path}"`
- Minimal deps — prefer stdlib over libraries
