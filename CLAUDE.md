# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is Valkka

Command center for AI coding agents. Elixir/Phoenix LiveView + Rust NIFs (libgit2) + optional Tauri desktop shell. No database — git repos + ETS caches. OTP app `:valkka`, module prefix `Valkka`.

## Commands

- `mix setup` — install deps + build assets (first-time setup)
- `mix compile` — Elixir + Rust NIF (Rust compiles automatically via Rustler)
- `mix test` — run all tests
- `mix test test/valkka/activity_test.exs` — run a single test file
- `mix test test/valkka/activity_test.exs:42` — run a single test by line
- `mix phx.server` — localhost:4420
- `mix format` — format code
- `mix precommit` — compile (warnings-as-errors) + unlock unused deps + format + test

## Architecture

### Supervision tree boot order

`Application.start/2` starts children in order: Telemetry → PubSub → TaskSupervisor → Caches (Graph, Commit, Status) → Plugin.Registry → Plugin.Supervisor → Repo.Registry → Repo.Supervisor → Watcher.Handler → Endpoint. After boot, a Task starts plugins then scans the workspace (`Valkka.Workspace.scan/0`), which discovers repos and starts workers.

### Repo.Worker (`lib/valkka/repo/worker.ex`)

`gen_statem` state machine per watched repo. States: `initializing → idle → operating → error`. During `operating`, all refreshes, file events, and new operations are **postponed** (queued by gen_statem) until the operation completes — this serializes mutations per repo. 5-second refresh cycle in `idle` is intentional load management. Workers subscribe to `"agents"` PubSub topic to track agent activity.

### Dual git interface

- **NIF** (`lib/valkka/git/native.ex` ↔ `native/valkka_git/`) — fast read operations (status, head info, diff, stage/unstage, commit). All NIFs use dirty CPU scheduler. Returns complex data as JSON strings decoded with Jason, simple values as atoms/tuples.
- **CLI** (`lib/valkka/git/cli.ex`) — operations NIFs don't cover: push, branch creation/checkout, log parsing, user config lookup. Shells out to `git` via `System.cmd/3`.

### NIF handle lifecycle

Repo handles are `ResourceArc<RepoHandle>` where `RepoHandle` wraps `Mutex<Repository>`. ResourceArc integrates with BEAM GC — when the owning Elixir process dies, Rust's `Drop` runs. The Mutex serializes access from concurrent dirty schedulers. Each Repo.Worker holds one handle reference.

### Caches (`lib/valkka/cache/`)

ETS tables owned by GenServers, public read. Graph, commit, and status caches. The GenServer owns the table (creator process), all other processes read directly from ETS.

### Plugins (`lib/valkka/plugin.ex`)

Behaviour-based, config-activated (`config :valkka, plugins: [...]`), zero required. Capabilities: `context_provider`, `event_consumer`, `action_provider`, `panel_provider`, `agent_detector`. Plugin.Registry indexes plugins by capability in ETS for fast lookup. ClaudeDetector uses ps+lsof for agent detection (intentional — no SDK integration).

### PubSub topics

`"file_events"`, `"repo:{path}"`, `"repos"`, `"agents"`. Workers subscribe to `"agents"` to know when an agent is active on their repo. Both per-repo and global broadcasts are required — `"repo:{path}"` for targeted updates, `"repos"` for the dashboard to update any repo.

### Activity (`lib/valkka/activity.ex`)

Pure-function module (no process). DashboardLive holds activity state and buffer. File changes are debounced with a 2-second window before being flushed to activity entries. State changes (branch switch, commit, dirty count transitions) are detected by comparing old vs new repo snapshots.

### LiveView (`lib/valkka_web/live/`)

Single `DashboardLive` page with three panels. Views: `overview`, `agents`, `repo` (with tabs: graph, changes, diff). JS hooks in `assets/js/hooks/` for keyboard shortcuts (`KeyboardHook`) and canvas graph rendering (`GraphHook`). Component communication uses `send_update/2` for parent→child and `send(self(), msg)` for child→parent.

### Workspace config

Configured in `config/dev.exs`: `workspace_roots` (list of paths, supports `~/`), `scan_depth` (how deep to look for `.git` repos). NIF `workspace_scan/2` does the actual directory traversal in Rust.

## Conventions

- Minimal deps — prefer stdlib over libraries
- `docs/` — do not modify without asking
- CSS classes use `.valkka-` prefix
- Port 4420 in dev, 4421 in test
