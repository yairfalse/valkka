# Valkka

Command center for AI coding agents.

*Välkkä* — Finnish slang for recess. Short for *välitunti*. The best 20 minutes of the school day: sunny outside, bad sandwich, hateful kids, but for a moment you had hopes that it might be fun. That's the feeling. Agents write code, you supervise — and it doesn't feel like work.

Multi-repo, local-first, no editor. See what your agents are doing, review their changes, commit, push — never leave Valkka.

## Stack

- **Elixir + Phoenix LiveView** — real-time UI, server-managed state
- **Rust NIFs (libgit2)** — fast git operations via Rustler
- **JavaScript hooks** — graph and diff rendering in LiveView
- **No database** — all state from git repos + ETS caches

## Requirements

- OTP 28+
- Elixir 1.19+
- Rust 1.89+
- Cargo

## Getting Started

```bash
mix setup          # deps + assets
mix phx.server     # http://localhost:4420
```

Or inside IEx:

```bash
iex -S mix phx.server
```

## Development

```bash
mix compile        # Elixir + Rust NIF
mix test           # run tests
mix format         # format code
```

## Project Structure

```
lib/valkka/            Core domain logic
  repo/               Repository supervision & state machines
  git/                NIF bindings + CLI fallback + types
  ai/                 AI provider behaviour & implementations
  cache/              ETS-backed caches (graph, commit, status)
  watcher/            Filesystem event handling

lib/valkka_web/        Phoenix web layer
  live/               LiveView pages

native/valkka_git/     Rust NIF crate (libgit2 bindings)
assets/js/hooks/      LiveView JS hooks (graph, diff)
docs/                 Design documents
```

## Design Documents

Architecture decisions, domain model, testing strategy, and more are in [`docs/`](docs/).

## License

Private. All rights reserved.
