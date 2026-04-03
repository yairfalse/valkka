# Valkka

Context for humans who supervise AI coding agents.

You run 10 or 12 agents across a dozen repos. Without Valkka, you're switching terminals, losing track, running after them. Each agent has context you don't — which files it changed, what branch it's on, whether it's still working or stopped 5 minutes ago. Valkka is a single screen that delivers that context to you: files changing, processes running, what each agent is doing right now. You don't operate it. You watch it.

*Välkkä* — Finnish slang for recess. Short for *välitunti*. The best 20 minutes of the school day: sunny outside, bad sandwich, hateful kids, but for a moment you had hopes that it might be fun. That's the feeling. Agents write code, you supervise — and it doesn't feel like work.

Multi-repo, local-first, no editor. Git files, running processes, and the context humans need to stay ahead of their agents.

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
