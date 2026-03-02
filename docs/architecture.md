# Känni Architecture

> AI-native git command center for agent-driven workflows.
> For people who don't open the editor.

## 1. The Three Questions

### What are the components?

```
┌─────────────────────────────────────────────────────────┐
│                    Känni Application                     │
│                                                         │
│  ┌─────────────┐  ┌──────────────┐  ┌───────────────┐  │
│  │   LiveView   │  │  AI Engine   │  │  Repo Manager  │ │
│  │   (UI Layer) │  │  (Brain)     │  │  (Git Layer)   │ │
│  └──────┬───────┘  └──────┬───────┘  └───────┬───────┘  │
│         │                 │                   │          │
│  ┌──────┴─────────────────┴───────────────────┴───────┐ │
│  │              Application Services                   │ │
│  │  (Use cases: review PR, explain diff, resolve       │ │
│  │   conflict, generate commit msg, natural language)   │ │
│  └──────────────────────┬──────────────────────────────┘ │
│                         │                                │
│  ┌──────────────────────┴──────────────────────────────┐ │
│  │                  Domain Core                         │ │
│  │  (Repository, Commit, Branch, Diff, Graph,           │ │
│  │   Conflict, Review, Agent)                           │ │
│  └──────────────────────┬──────────────────────────────┘ │
│                         │                                │
│  ┌──────────────────────┴──────────────────────────────┐ │
│  │              Infrastructure                          │ │
│  │  ┌────────────┐  ┌──────────┐  ┌─────────────────┐  │ │
│  │  │ Rust NIFs  │  │ AI APIs  │  │ File System     │  │ │
│  │  │ (git2-rs)  │  │ (LLM)   │  │ (watchers)      │  │ │
│  │  └────────────┘  └──────────┘  └─────────────────┘  │ │
│  └─────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

### How do they communicate?

- **LiveView ↔ Application**: Phoenix PubSub. LiveView subscribes to topics, application broadcasts changes.
- **Application ↔ Rust NIFs**: Synchronous NIF calls on dirty schedulers. Rust returns structured data (maps/tuples), never raw binary.
- **Application ↔ AI**: Async GenServer. Streams tokens via PubSub. LiveView receives chunks and renders progressively.
- **Repo Manager ↔ File System**: `FileSystem` library watches for changes, publishes events to the repo's GenServer.

### What can change independently?

| Component | Can change without touching... |
|---|---|
| LiveView templates | Domain, Rust NIFs, AI |
| AI provider (OpenAI → Anthropic → local) | UI, Git operations, Domain |
| Rust NIF internals | Elixir application code (boundary is the NIF API) |
| Git hosting (GitHub → GitLab) | UI, AI, Domain |
| Graph rendering (Canvas → WebGL → SVG) | Backend, Domain |

---

## 2. Supervision Tree

```
Känni.Application
├── Känni.Repo.Supervisor (DynamicSupervisor)
│   ├── Känni.Repo.Worker (GenServer, per repo)
│   │   ├── Holds Rust ResourceArc to git2 Repository
│   │   ├── Handles all git operations for this repo
│   │   ├── Publishes state changes via PubSub
│   │   └── Monitors file system for changes
│   ├── Känni.Repo.Worker (repo 2)
│   └── Känni.Repo.Worker (repo N)
│
├── Känni.AI.Supervisor
│   ├── Känni.AI.StreamManager (GenServer)
│   │   ├── Manages concurrent AI requests
│   │   ├── Rate limiting, backpressure
│   │   └── Streams tokens to PubSub topics
│   └── Känni.AI.ContextBuilder (GenServer)
│       ├── Builds context from repo state for AI prompts
│       └── Manages token budgets
│
├── Känni.Workspace.Registry (Registry)
│   └── Maps workspace IDs to repo workers
│
├── Känni.FileWatcher.Supervisor (DynamicSupervisor)
│   ├── One FileSystem watcher per monitored repo
│   └── Publishes change events to repo workers
│
├── KänniWeb.Endpoint (Phoenix)
│   └── LiveView connections
│
└── Känni.PubSub (Phoenix.PubSub)
    Topics:
    ├── "repo:{repo_id}" — repo state changes
    ├── "repo:{repo_id}:graph" — graph updates
    ├── "repo:{repo_id}:ai" — AI stream chunks
    └── "workspace:{workspace_id}" — workspace-level events
```

### Why This Tree?

- **Each repo is isolated.** If repo 3 has a corrupted `.git`, it crashes alone. Supervisor restarts it. Other repos unaffected.
- **AI is separate from git.** An AI API timeout doesn't block git operations.
- **File watchers are separate.** A broken inotify watch doesn't take down the repo worker.

---

## 3. Rustler NIF Boundary

This is the most critical architectural decision. The boundary must be:
- **Narrow**: Few functions, well-defined inputs/outputs
- **Async-safe**: All NIFs run on dirty schedulers (never block BEAM schedulers)
- **Data-copying**: Rust returns Elixir terms (maps, lists, binaries). No shared mutable state across the boundary except `ResourceArc` handles.

### NIF Module: `Känni.Git.Native`

```
┌─────────────────────────────────────────────────┐
│              Rust NIF Surface                    │
│                                                  │
│  Repository Management                           │
│  ├── repo_open(path) → {:ok, ResourceArc}        │
│  ├── repo_info(handle) → %{head, branches, ...}  │
│  └── repo_close(handle) → :ok                    │
│                                                  │
│  Commit & History                                │
│  ├── log(handle, opts) → [%Commit{}]             │
│  ├── commit_detail(handle, oid) → %CommitDetail{}│
│  └── graph(handle, opts) → %Graph{}              │
│                                                  │
│  Branching                                       │
│  ├── branches(handle) → [%Branch{}]              │
│  ├── checkout(handle, ref) → :ok | {:error, _}   │
│  ├── create_branch(handle, name, target) → :ok   │
│  └── delete_branch(handle, name) → :ok           │
│                                                  │
│  Diffing                                         │
│  ├── diff(handle, from, to) → %Diff{}            │
│  ├── diff_stats(handle, from, to) → %DiffStats{} │
│  └── semantic_diff(handle, from, to) → %SDiff{}  │
│                                                  │
│  Operations                                      │
│  ├── stage(handle, paths) → :ok                  │
│  ├── unstage(handle, paths) → :ok                │
│  ├── commit(handle, message, opts) → {:ok, oid}  │
│  ├── merge(handle, source, target) → result      │
│  ├── rebase(handle, opts) → result               │
│  ├── stash(handle, message) → :ok                │
│  └── cherry_pick(handle, oid) → result           │
│                                                  │
│  Search                                          │
│  ├── blame(handle, path) → [%BlameLine{}]        │
│  ├── search_commits(handle, query) → [%Commit{}] │
│  └── file_history(handle, path) → [%Commit{}]    │
│                                                  │
│  Graph Computation                               │
│  ├── compute_graph(handle, opts) → %GraphLayout{} │
│  └── graph_subset(handle, range) → %GraphLayout{} │
└─────────────────────────────────────────────────┘
```

### ResourceArc Pattern

```rust
// Rust side
struct RepoHandle {
    repo: Mutex<git2::Repository>,
    path: PathBuf,
}

impl ResourceArc for RepoHandle {}

#[rustler::nif(schedule = "DirtyCpu")]
fn repo_open(path: String) -> Result<ResourceArc<RepoHandle>, Error> {
    let repo = git2::Repository::open(&path)?;
    Ok(ResourceArc::new(RepoHandle {
        repo: Mutex::new(repo),
        path: PathBuf::from(path),
    }))
}
```

```elixir
# Elixir side — the handle is opaque
{:ok, handle} = Känni.Git.Native.repo_open("/path/to/repo")
commits = Känni.Git.Native.log(handle, %{limit: 100})
# handle is garbage collected → Rust drops the Repository
```

### Semantic Diff (The Differentiator)

The `semantic_diff` NIF doesn't just return added/removed lines. It returns:

```elixir
%SemanticDiff{
  changes: [
    %{type: :function_modified, name: "handle_request", file: "src/server.rs",
      summary: "Added timeout parameter", lines_added: 3, lines_removed: 1},
    %{type: :function_added, name: "validate_input", file: "src/server.rs",
      summary: "New validation function", lines_added: 15},
    %{type: :import_changed, file: "src/server.rs",
      summary: "Added tokio::time import"},
    %{type: :file_renamed, from: "old.rs", to: "new.rs",
      similarity: 0.95}
  ],
  stats: %{files: 3, insertions: 20, deletions: 5,
           functions_modified: 1, functions_added: 1}
}
```

This is computed in Rust using tree-sitter for language-aware parsing. The AI layer receives structured change descriptions, not raw diffs.

---

## 4. LiveView Structure

### Page Architecture

```
KänniWeb.Router
├── / → DashboardLive (workspace overview, all repos)
├── /repo/:id → RepoLive (single repo view)
│   ├── RepoLive.GraphComponent (commit graph)
│   ├── RepoLive.DiffComponent (diff viewer)
│   ├── RepoLive.BranchComponent (branch list)
│   ├── RepoLive.AIComponent (AI chat/actions)
│   └── RepoLive.StatusComponent (repo status bar)
├── /repo/:id/pr/:number → PRLive (PR review)
└── /chat → ChatLive (natural language git across all repos)
```

### Real-Time Flow

```
File changes on disk
  → FileWatcher detects change
    → Publishes to "repo:{id}" PubSub topic
      → Repo.Worker receives, runs NIF to get new state
        → Broadcasts updated state to "repo:{id}"
          → LiveView handle_info receives update
            → UI re-renders (only the diff, not full page)
```

### The Chat Interface (Core UX)

This is the primary interface. Not the graph, not the file tree — the chat.

```
┌─────────────────────────────────────────────┐
│ Känni — workspace: ~/projects                │
├─────────────────────────────────────────────┤
│                                             │
│  ┌─ repo: kanni (main) ──────────────────┐  │
│  │ 3 uncommitted changes                 │  │
│  │ 2 branches ahead of origin            │  │
│  └───────────────────────────────────────┘  │
│                                             │
│  ┌─ repo: false-protocol (feat/v2) ─────┐  │
│  │ clean, 1 PR open                      │  │
│  └───────────────────────────────────────┘  │
│                                             │
│  ─────────── conversation ────────────────  │
│                                             │
│  you: what changed in kanni today?          │
│                                             │
│  känni: 3 files modified in kanni:          │
│    • lib/repo/worker.ex — added timeout     │
│      handling to git operations (+15, -3)   │
│    • lib/ai/stream.ex — new file,           │
│      implements token streaming (42 lines)  │
│    • test/repo_test.exs — 2 new test cases  │
│                                             │
│    Suggested commit message:                │
│    "Add git operation timeouts and AI       │
│     token streaming"                        │
│                                             │
│    [Commit] [Show diff] [Edit message]      │
│                                             │
│  you: show me the graph for last 2 weeks    │
│                                             │
│  känni: [interactive graph renders here]    │
│                                             │
│  ──────────────────────────────────────────  │
│  > type a command or ask a question...      │
└─────────────────────────────────────────────┘
```

---

## 5. AI Engine Architecture

### Intent Recognition

Natural language input goes through a pipeline:

```
User input
  → Intent classifier (local, fast — regex + simple patterns first)
    → If clear intent: execute directly
    → If ambiguous: send to LLM for interpretation
      → LLM returns structured command
        → Command executor runs the operation
          → Result formatter presents output
```

### Intent Categories

```elixir
defmodule Känni.AI.Intent do
  # Direct git operations
  {:git_op, :commit, %{message: "..."}}
  {:git_op, :merge, %{source: "feat/x", target: "main"}}
  {:git_op, :rebase, %{onto: "main"}}
  {:git_op, :squash, %{count: 4, message: "..."}}

  # Queries
  {:query, :changes_since, %{ref: "v1.0.0"}}
  {:query, :who_changed, %{file: "src/main.rs"}}
  {:query, :branch_status, %{branch: "feat/x"}}
  {:query, :explain_diff, %{from: "abc123", to: "def456"}}

  # AI-assisted operations
  {:ai_op, :review_pr, %{pr: 42}}
  {:ai_op, :generate_commit_msg, %{}}
  {:ai_op, :resolve_conflict, %{file: "src/main.rs"}}
  {:ai_op, :explain_history, %{file: "src/main.rs"}}
end
```

### Streaming Architecture

```elixir
defmodule Känni.AI.StreamManager do
  use GenServer

  def request(repo_id, intent, opts \\ []) do
    GenServer.cast(__MODULE__, {:request, repo_id, intent, opts})
  end

  # Internally:
  # 1. Builds context (repo state, recent history, relevant diffs)
  # 2. Sends to LLM API with streaming enabled
  # 3. As tokens arrive, publishes to PubSub "repo:{id}:ai"
  # 4. LiveView receives tokens, appends to chat UI
  # 5. When stream completes, parses for actionable elements
  #    (commit buttons, diff links, branch actions)
end
```

---

## 6. Data Flow Examples

### "Squash last 4 commits"

```
1. User types "squash last 4 commits" in chat
2. LiveView sends event to ChatLive
3. ChatLive calls AI.IntentParser.parse("squash last 4 commits")
4. Returns {:git_op, :squash, %{count: 4}}
5. ChatLive asks: "Squash into what message?" (or AI suggests one)
6. User confirms
7. ChatLive calls Repo.Worker.execute(repo_id, {:squash, 4, message})
8. Repo.Worker calls Rust NIF: interactive_rebase(handle, opts)
9. NIF performs the rebase in Rust, returns {:ok, new_oid}
10. Repo.Worker broadcasts new state via PubSub
11. LiveView updates: graph re-renders, status updates
12. Chat shows: "Squashed 4 commits into abc123"
```

### "Review this PR"

```
1. User: "review PR #42 on false-protocol"
2. Intent: {:ai_op, :review_pr, %{repo: "false-protocol", pr: 42}}
3. Repo.Worker fetches PR diff via NIF (or GitHub API)
4. AI.ContextBuilder assembles:
   - The full diff (semantic, not raw)
   - File context (what these files do)
   - Recent history of touched files
   - PR description
5. AI.StreamManager sends to LLM, streams response
6. LiveView renders review as it streams:
   - Summary
   - File-by-file analysis
   - Risk assessment
   - Suggested changes (with inline diff)
7. User can approve, request changes, or ask follow-ups
```

---

## 7. Project Structure

```
kanni/
├── lib/
│   ├── kanni/
│   │   ├── application.ex          # Supervision tree
│   │   ├── repo/
│   │   │   ├── worker.ex           # Per-repo GenServer
│   │   │   ├── supervisor.ex       # DynamicSupervisor
│   │   │   └── state.ex            # Repo state struct
│   │   ├── git/
│   │   │   ├── native.ex           # Rustler NIF bindings
│   │   │   ├── commands.ex         # High-level git operations
│   │   │   └── types.ex            # Commit, Branch, Diff structs
│   │   ├── ai/
│   │   │   ├── intent.ex           # Intent types
│   │   │   ├── intent_parser.ex    # NL → Intent
│   │   │   ├── stream_manager.ex   # LLM streaming
│   │   │   ├── context_builder.ex  # Build prompts from repo state
│   │   │   └── providers/
│   │   │       ├── anthropic.ex
│   │   │       └── openai.ex
│   │   ├── workspace/
│   │   │   ├── registry.ex         # Multi-repo workspace
│   │   │   └── config.ex           # Workspace settings
│   │   └── watcher/
│   │       ├── supervisor.ex
│   │       └── handler.ex          # File change events
│   │
│   └── kanni_web/
│       ├── router.ex
│       ├── live/
│       │   ├── dashboard_live.ex   # Workspace overview
│       │   ├── repo_live.ex        # Single repo view
│       │   ├── chat_live.ex        # Natural language interface
│       │   ├── pr_live.ex          # PR review
│       │   └── components/
│       │       ├── graph.ex        # Commit graph component
│       │       ├── diff.ex         # Diff viewer
│       │       ├── branch_list.ex  # Branch management
│       │       ├── ai_chat.ex      # AI chat panel
│       │       └── status_bar.ex   # Repo status
│       ├── hooks/                  # JS hooks for LiveView
│       │   ├── graph_renderer.js   # Canvas/WebGL graph
│       │   └── diff_renderer.js    # Syntax-highlighted diffs
│       └── layouts/
│
├── native/kanni_git/               # Rust NIF crate
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs                  # NIF entry point
│       ├── repo.rs                 # Repository operations
│       ├── log.rs                  # Commit log & history
│       ├── diff.rs                 # Diffing (raw + semantic)
│       ├── graph.rs                # Graph layout computation
│       ├── branch.rs               # Branch operations
│       ├── operations.rs           # merge, rebase, cherry-pick
│       ├── search.rs               # blame, file history
│       └── semantic/
│           ├── mod.rs              # Semantic diff engine
│           ├── parser.rs           # tree-sitter integration
│           └── languages.rs        # Language-specific heuristics
│
├── assets/                         # Frontend
│   ├── js/
│   │   ├── app.js
│   │   └── hooks/
│   │       ├── graph_hook.js       # WebGL commit graph
│   │       └── diff_hook.js        # Rich diff rendering
│   └── css/
│       └── app.css
│
├── config/
│   ├── config.exs
│   ├── dev.exs
│   └── prod.exs
│
├── test/
│   ├── kanni/
│   │   ├── repo/
│   │   ├── git/
│   │   ├── ai/
│   │   └── workspace/
│   └── kanni_web/
│       └── live/
│
├── docs/
│   ├── architecture.md             # This file
│   └── adr/                        # Architecture Decision Records
│
├── mix.exs
└── README.md
```

---

## 8. Key Architectural Decisions

### ADR-001: Rust NIFs over git CLI

**Decision:** Use Rust NIFs (git2-rs via Rustler) instead of shelling out to `git` CLI.

**Why:**
- Structured data without parsing text output
- Single process, no fork/exec overhead for each operation
- ResourceArc keeps repo handles open — no re-opening for each command
- Semantic diff requires tree-sitter, which is C/Rust only
- Graph layout computation is CPU-intensive, benefits from Rust

**Trade-off:** More complex build. Every developer needs Rust toolchain. Worth it for the performance and semantic diff capability.

### ADR-002: Chat-first, not graph-first

**Decision:** The primary interface is a natural language chat, not a visual commit graph.

**Why:**
- Target users work with AI agents, not IDEs. They think in commands and questions, not visual navigation.
- The graph is a visualization tool, not an interaction model.
- Chat naturally supports both queries ("what changed?") and operations ("squash these").
- AI streaming fits naturally into a chat UX.

**Trade-off:** The graph is still there and still important, but it's a component within the chat view, not the primary interface.

### ADR-003: Process-per-repo isolation

**Decision:** Each monitored repository gets its own GenServer process.

**Why:**
- Fault isolation. Corrupted repo doesn't crash the app.
- Natural concurrency. Operations on different repos run in parallel.
- State isolation. Each repo's state (head, branches, status) is encapsulated.
- Supervision. Individual repos can restart independently.

### ADR-004: PubSub for internal communication

**Decision:** Use Phoenix.PubSub for all inter-component communication.

**Why:**
- LiveView already integrates with PubSub natively.
- Decouples producers from consumers. Repo worker doesn't know about LiveView.
- Supports multiple subscribers. Dashboard and repo view can both listen.
- Scales to distributed (multi-node) in the future without code changes.

### ADR-005: AI provider abstraction

**Decision:** AI provider is behind a behaviour (interface). Can swap Anthropic, OpenAI, local models.

**Why:**
- AI landscape changes fast. Don't lock in.
- Different users may prefer different providers.
- Testing: use a mock provider in tests.

---

## 9. Performance Targets

| Metric | Target | How |
|---|---|---|
| App startup | < 2s | Phoenix is fast, lazy-load repos |
| Open a repo | < 200ms | Rust NIF, ResourceArc cached |
| Render graph (1000 commits) | < 100ms | Rust computes layout, WebGL renders |
| Render graph (50,000 commits) | < 500ms | Virtualized rendering, compute subset |
| Diff two commits | < 50ms | Rust NIF, git2-rs |
| Semantic diff | < 300ms | tree-sitter in Rust |
| AI response start | < 1s | Streaming, first token matters |
| File change detection | < 100ms | inotify/FSEvents via FileSystem |
| Idle RAM (5 repos) | < 150MB | BEAM + Rust handles, no Chromium |

---

## 10. Deployment Model

### Local Application (Primary)

```
mix release → single binary with embedded BEAM
  + bundled Rust NIF .so/.dylib
  + bundled assets (CSS/JS)

User runs: ./kanni
Opens browser: http://localhost:4420
```

Packaging options:
- **macOS**: `.app` bundle via Tauri-like wrapper or Homebrew formula
- **Linux**: AppImage, Flatpak, or distro packages
- **Windows**: MSIX or portable binary (BEAM runs on Windows)

### Future: Team/Cloud Mode

The same architecture scales to a hosted service:
- Multiple users connect to same Phoenix instance
- Each user's repos are their own process trees
- PubSub enables real-time collaboration
- No architectural changes needed — just deployment config

---

## 11. What Makes This Architecture Win

1. **The Rust NIF boundary is narrow and stable.** 20-30 functions that rarely change. Everything above it is pure Elixir.

2. **PubSub makes everything reactive for free.** File changes, AI responses, git operations — all flow through the same mechanism to the UI.

3. **Process-per-repo gives fault tolerance no other git client has.** GitKraken crashes on one repo, you lose everything. Känni shrugs it off.

4. **Chat-first means AI isn't bolted on — it IS the interface.** Every other git client adds AI as a feature. Känni is built around it.

5. **The semantic diff is the technical moat.** No other git client tells you "this function's signature changed and a new validation function was added." They show you green and red lines.
