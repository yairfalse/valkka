# Valkka: Developer Practices

> The definitive guide for contributing to Valkka. Read this on day 1.
> Every pattern here is battle-tested in Kerto (243 tests) and Sykli (25+ modules).

---

## 1. Elixir Conventions

### 1.1 Module Naming

Modules follow a strict namespace hierarchy that mirrors the architecture:

```
Valkka.                          # Root namespace
├── Git.Native                  # Rust NIF bindings (infrastructure)
├── Git.Commands                # High-level git operations
├── Git.Types                   # Commit, Branch, Diff structs
├── Repo.Worker                 # Per-repo GenServer
├── Repo.Supervisor             # DynamicSupervisor for repos
├── Repo.State                  # Repo state struct
├── AI.StreamManager            # LLM streaming GenServer
├── AI.ContextBuilder           # Builds prompts from repo state
├── AI.IntentParser             # NL -> Intent
├── AI.Provider                 # Behaviour for LLM providers
├── AI.Providers.Anthropic      # Concrete provider
├── Workspace.Registry          # Multi-repo workspace
├── Watcher.Handler             # File change events
├── Kerto.Emitter               # Occurrence emission
└── Sykli.StatusMonitor         # CI status
```

**Rules:**

- One module per file. File name matches module name: `Valkka.Repo.Worker` lives in `lib/valkka/repo/worker.ex`.
- Infrastructure modules (`Git.Native`, `AI.Providers.*`) never appear in domain code.
- Domain modules (`Git.Types`, `AI.Intent`) have zero dependencies on infrastructure.

```elixir
# GOOD: clear namespace hierarchy
defmodule Valkka.Repo.Worker do
  # ...
end

# BAD: flat namespace
defmodule ValkkaRepoWorker do
  # ...
end

# BAD: too deep without reason
defmodule Valkka.Core.Domain.Git.Repository.Worker.Impl do
  # ...
end
```

### 1.2 Error Handling

Three strategies, each with a specific use case.

#### `with` — for multi-step operations where any step can fail

Use `with` when you have a pipeline of operations that each return `{:ok, _}` or `{:error, _}` and you want to short-circuit on the first failure.

```elixir
# GOOD: with for multi-step fallible operations
def create_commit(repo_id, message) do
  with {:ok, handle} <- get_handle(repo_id),
       {:ok, status} <- Native.repo_info(handle),
       :ok <- validate_has_staged(status),
       {:ok, oid} <- Native.commit(handle, message, %{}) do
    broadcast(repo_id, {:commit_created, oid})
    {:ok, oid}
  end
end
```

#### `case` — for single operation with branching logic

Use `case` when one operation has multiple possible outcomes and you need different behavior for each.

```elixir
# GOOD: case for branching on a single result
def checkout(handle, ref) do
  case Native.checkout(handle, ref) do
    :ok ->
      :ok

    {:error, reason} when is_binary(reason) ->
      cond do
        reason =~ "uncommitted changes" ->
          {:error, %Error{code: :dirty_workdir, message: "Commit or stash first"}}

        reason =~ "not found" ->
          {:error, %Error{code: :ref_not_found, message: "Branch '#{ref}' not found"}}

        true ->
          {:error, %Error{code: :git_error, message: reason}}
      end
  end
end
```

#### Let it crash — for programming errors and unrecoverable state

Let the process crash and rely on OTP supervision when:
- A precondition is violated (indicates a bug)
- State is corrupted beyond repair
- An external resource is permanently unavailable

```elixir
# GOOD: let it crash on corrupted state
def handle_call({:git_op, op}, _from, %{handle: nil} = state) do
  # Handle is nil means repo_open failed and retries exhausted.
  # Crash. Supervisor will restart with a fresh attempt.
  raise "repo handle is nil — cannot perform git operations"
end

# GOOD: use pattern match to crash on unexpected data
def handle_call({:stage, paths}, _from, %{handle: handle} = state)
    when is_list(paths) do
  # If paths is not a list, the function head won't match.
  # That is intentional — it is a programming error.
  :ok = Native.stage(handle, paths)
  {:reply, :ok, refresh_status(state)}
end
```

**Decision table:**

| Situation | Strategy |
|---|---|
| Chain of fallible operations | `with` |
| One operation, multiple outcomes | `case` |
| Data validation at boundary | `case` or guards |
| Programming error / impossible state | Let it crash |
| External resource permanently gone | Let it crash |
| Transient failure (network, lock) | `case` + retry or `with` |

### 1.3 Type Specs

Spec all public functions. Skip private functions unless they are complex or non-obvious.

```elixir
defmodule Valkka.Git.Commands do
  # GOOD: all public functions have specs
  @spec checkout(ResourceArc.t(), String.t()) :: :ok | {:error, Error.t()}
  def checkout(handle, ref) do
    # ...
  end

  @spec log(ResourceArc.t(), log_opts()) :: {:ok, [Commit.t()]} | {:error, String.t()}
  def log(handle, opts \\ %{}) do
    # ...
  end

  # GOOD: custom types for complex option maps
  @type log_opts :: %{
    optional(:limit) => pos_integer(),
    optional(:since) => String.t(),
    optional(:author) => String.t(),
    optional(:path) => String.t(),
    optional(:branch) => String.t()
  }

  # Private: skip spec (simple helper)
  defp normalize_ref("HEAD"), do: "HEAD"
  defp normalize_ref(ref), do: ref

  # Private: add spec (complex logic)
  @spec parse_nif_commits([map()]) :: [Commit.t()]
  defp parse_nif_commits(raw_commits) do
    Enum.map(raw_commits, &Commit.from_nif_map/1)
  end
end
```

**Use `@enforce_keys` for domain structs** — borrowed from Kerto:

```elixir
defmodule Valkka.Git.Commit do
  @enforce_keys [:oid, :message, :author_name, :timestamp]
  defstruct [:oid, :message, :author_name, :author_email,
             :timestamp, parents: []]

  @type t :: %__MODULE__{
    oid: String.t(),
    message: String.t(),
    author_name: String.t(),
    author_email: String.t() | nil,
    timestamp: DateTime.t(),
    parents: [String.t()]
  }
end
```

### 1.4 GenServer Conventions

**`call` for reads, `cast` for fire-and-forget. Never `cast` for operations that need confirmation.**

```elixir
defmodule Valkka.Repo.Worker do
  use GenServer

  # GOOD: call for reads — caller needs the result
  @spec status(GenServer.server()) :: RepoStatus.t()
  def status(server) do
    GenServer.call(server, :status)
  end

  @spec log(GenServer.server(), map()) :: {:ok, [Commit.t()]} | {:error, term()}
  def log(server, opts \\ %{}) do
    GenServer.call(server, {:log, opts})
  end

  # GOOD: call for mutations — caller needs to know if it succeeded
  @spec commit(GenServer.server(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def commit(server, message) do
    GenServer.call(server, {:commit, message})
  end

  # GOOD: cast for fire-and-forget notifications
  @spec refresh(GenServer.server()) :: :ok
  def refresh(server) do
    GenServer.cast(server, :refresh)
  end

  # BAD: cast for mutation — caller has no way to know if it worked
  # def commit(server, message) do
  #   GenServer.cast(server, {:commit, message})  # DON'T
  # end

  # Server callbacks — pattern match in function heads
  @impl true
  def handle_call(:status, _from, %{status: status} = state) do
    {:reply, status, state}
  end

  @impl true
  def handle_call({:log, opts}, _from, %{handle: handle} = state) do
    result = Native.log(handle, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:commit, message}, _from, %{handle: handle} = state) do
    case Native.commit(handle, message, %{}) do
      {:ok, oid} = result ->
        Phoenix.PubSub.broadcast(Valkka.PubSub, "repo:#{state.repo_id}", {:commit_created, oid})
        {:reply, result, refresh_status(state)}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_cast(:refresh, state) do
    {:noreply, refresh_status(state)}
  end
end
```

**Always use `@impl true`** to mark callback implementations. The compiler will warn if the callback does not exist.

### 1.5 Pattern Matching

Match in function heads, not in function bodies.

```elixir
# GOOD: match in function head
def handle_info({:file_event, _watcher, {path, _events}}, state) do
  {:noreply, process_file_change(state, path)}
end

def handle_info({:repo_error, reason}, state) do
  Logger.error("Repo error: #{reason}", repo_id: state.repo_id)
  {:noreply, %{state | status: :error}}
end

# BAD: match in body
def handle_info(msg, state) do
  case msg do
    {:file_event, _, {path, _}} -> {:noreply, process_file_change(state, path)}
    {:repo_error, reason} -> # ...
  end
end
```

```elixir
# GOOD: multi-clause with guards
def classify_freshness(weight) when weight > 0.7, do: :active
def classify_freshness(weight) when weight > 0.3, do: :stale
def classify_freshness(_weight), do: :abandoned

# BAD: conditional in body
def classify_freshness(weight) do
  cond do
    weight > 0.7 -> :active
    weight > 0.3 -> :stale
    true -> :abandoned
  end
end
```

### 1.6 Pipeline Style

Use `|>` for data transformations. Do not use `|>` for side effects.

```elixir
# GOOD: pipeline for data transformation
def active_branches(repo_id) do
  repo_id
  |> Git.Commands.branches()
  |> Enum.filter(& &1.is_head == false)
  |> Enum.reject(& &1.is_remote)
  |> Enum.sort_by(& &1.name)
end

# GOOD: pipeline for building a struct
def build_context(repo_id, staged_files) do
  staged_files
  |> Enum.map(&Git.Commands.file_diff(repo_id, &1))
  |> Enum.map(&SemanticChange.from_diff/1)
  |> Enum.reject(&is_nil/1)
  |> ContextBuilder.assemble(token_budget: 4000)
end

# BAD: pipeline for side effects
def do_everything(repo_id) do
  repo_id
  |> Git.Commands.status()
  |> IO.inspect()           # side effect
  |> broadcast_status()     # side effect
  |> Logger.info()          # side effect
end

# GOOD: separate data flow from side effects
def do_everything(repo_id) do
  status = Git.Commands.status(repo_id)
  broadcast_status(repo_id, status)
  Logger.info("Status refreshed", repo_id: repo_id)
  status
end
```

### 1.7 Config

Use `Application.compile_env/3` for values that never change at runtime. Use `Application.get_env/3` for values that may change.

```elixir
# GOOD: compile-time config (OTP app name, static feature flags)
defmodule Valkka.Git.Native do
  use Rustler,
    otp_app: Application.compile_env!(:valkka, :otp_app),
    crate: :valkka_git
end

# GOOD: runtime config (provider can change, model can change)
defmodule Valkka.AI.StreamManager do
  defp provider do
    Application.get_env(:valkka, :ai_provider, Valkka.AI.Providers.Anthropic)
  end

  defp model do
    Application.get_env(:valkka, :ai_model, "claude-sonnet-4-20250514")
  end
end

# config/config.exs — defaults
config :valkka,
  otp_app: :valkka,
  ai_provider: Valkka.AI.Providers.Anthropic

# config/test.exs — test overrides
config :valkka,
  ai_provider: Valkka.AI.Providers.Mock

# config/runtime.exs — runtime overrides from environment
config :valkka,
  ai_model: System.get_env("VALKKA_AI_MODEL", "claude-sonnet-4-20250514")
```

---

## 2. Rust NIF Conventions

### 2.1 Never Panic

A panic in a NIF crashes the entire BEAM VM. Every NIF function must be wrapped in `catch_unwind`.

```rust
use std::panic;

/// Wraps any NIF function to catch panics and convert to errors.
fn safe_nif<F, T>(f: F) -> Result<T, String>
where
    F: FnOnce() -> Result<T, String> + panic::UnwindSafe,
{
    match panic::catch_unwind(f) {
        Ok(result) => result,
        Err(panic_info) => {
            let msg = if let Some(s) = panic_info.downcast_ref::<&str>() {
                format!("NIF panic: {}", s)
            } else if let Some(s) = panic_info.downcast_ref::<String>() {
                format!("NIF panic: {}", s)
            } else {
                "NIF panic: unknown error".to_string()
            };
            eprintln!("[VALKKA NIF ERROR] {}", msg);
            Err(msg)
        }
    }
}

// GOOD: every NIF uses safe_nif + Result
#[rustler::nif(schedule = "DirtyCpu")]
fn repo_open(path: String) -> Result<ResourceArc<RepoHandle>, String> {
    safe_nif(|| {
        let repo = git2::Repository::open(&path)
            .map_err(|e| format!("failed to open repo at {}: {}", path, e))?;
        Ok(ResourceArc::new(RepoHandle {
            repo: Mutex::new(repo),
            path: PathBuf::from(path),
        }))
    })
}

// BAD: unwrap can panic
#[rustler::nif(schedule = "DirtyCpu")]
fn repo_open_bad(path: String) -> ResourceArc<RepoHandle> {
    let repo = git2::Repository::open(&path).unwrap(); // BOOM — kills the BEAM
    ResourceArc::new(RepoHandle {
        repo: Mutex::new(repo),
        path: PathBuf::from(path),
    })
}
```

**Rules:**
- Use `Result<T, String>` everywhere. Never return bare values from NIFs.
- Never use `.unwrap()`, `.expect()`, or array indexing without bounds checks.
- Convert all `?` errors to `String` via `.map_err(|e| format!(...))`.
- Wrap the entire NIF body in `safe_nif(|| { ... })`.

### 2.2 ResourceArc

One `ResourceArc` per repository, wrapping a `Mutex<git2::Repository>`.

```rust
pub struct RepoHandle {
    pub repo: Mutex<git2::Repository>,
    pub path: PathBuf,
}

// Safety justification:
// git2::Repository is not Send/Sync by default because it contains
// raw pointers to libgit2 data structures. We make this safe by:
// 1. Wrapping in Mutex — only one thread accesses the repo at a time
// 2. The Elixir GenServer already serializes calls per repo, so
//    concurrent Mutex contention should not occur in practice
// 3. All NIF operations are read-only or atomic write operations
//    that do not leave the repo in an inconsistent state on failure
unsafe impl Send for RepoHandle {}
unsafe impl Sync for RepoHandle {}
```

**Always document why `unsafe impl Send/Sync` is safe.** Every `unsafe` block must have a `// Safety:` comment.

### 2.3 Data Serialization

Return Elixir maps and tuples via rustler encoders. Never return raw bytes.

```rust
use rustler::{Encoder, Env, Term};

// GOOD: return structured Elixir map
#[rustler::nif(schedule = "DirtyCpu")]
fn commit_detail(handle: ResourceArc<RepoHandle>, oid: String) -> Result<CommitDetail, String> {
    safe_nif(|| {
        let repo = handle.repo.lock()
            .map_err(|_| "failed to acquire repo lock".to_string())?;

        let oid = git2::Oid::from_str(&oid)
            .map_err(|e| format!("invalid OID '{}': {}", oid, e))?;

        let commit = repo.find_commit(oid)
            .map_err(|e| format!("commit {} not found: {}", oid, e))?;

        Ok(CommitDetail {
            oid: commit.id().to_string(),
            message: commit.message().unwrap_or("").to_string(),
            author_name: commit.author().name().unwrap_or("").to_string(),
            author_email: commit.author().email().unwrap_or("").to_string(),
            timestamp: commit.time().seconds(),
        })
    })
}

// CommitDetail derives NifStruct for automatic Elixir encoding
#[derive(NifStruct)]
#[module = "Valkka.Git.NifCommit"]
struct CommitDetail {
    oid: String,
    message: String,
    author_name: String,
    author_email: String,
    timestamp: i64,
}

// BAD: returning raw bytes
#[rustler::nif(schedule = "DirtyCpu")]
fn get_blob(handle: ResourceArc<RepoHandle>, oid: String) -> Vec<u8> {
    // DON'T — Elixir side gets opaque binary with no structure
}
```

### 2.4 Dirty Schedulers

ALL NIFs use `schedule = "DirtyCpu"`. No exceptions. Git operations touch the filesystem and can block. Even "fast" operations (reading HEAD) can stall on network filesystems or under I/O pressure.

```rust
// GOOD: always DirtyCpu
#[rustler::nif(schedule = "DirtyCpu")]
fn branches(handle: ResourceArc<RepoHandle>) -> Result<Vec<BranchInfo>, String> { ... }

#[rustler::nif(schedule = "DirtyCpu")]
fn repo_info(handle: ResourceArc<RepoHandle>) -> Result<RepoInfo, String> { ... }

// BAD: no schedule annotation (runs on BEAM scheduler, can block all Erlang processes)
#[rustler::nif]
fn branches(handle: ResourceArc<RepoHandle>) -> Result<Vec<BranchInfo>, String> { ... }
```

### 2.5 Error Messages

Error messages must include context. The person reading the error should know what was being attempted and why it failed.

```rust
// GOOD: contextual error messages
.map_err(|e| format!("failed to open repo at {}: {}", path, e))?;
.map_err(|e| format!("failed to parse OID '{}': {}", oid, e))?;
.map_err(|_| format!("repo lock poisoned for {}", handle.path.display()))?;
.map_err(|e| format!("checkout '{}' failed: {}", ref_name, e))?;
.map_err(|e| format!("merge {} into {}: {}", source, target, e))?;

// BAD: no context
.map_err(|e| e.to_string())?;
.map_err(|_| "failed".to_string())?;
.map_err(|e| format!("{}", e))?;
```

---

## 3. Cross-Boundary Patterns

### 3.1 Type Mapping Table

| Elixir | Rust | Notes |
|---|---|---|
| `String.t()` | `String` | UTF-8 guaranteed by both runtimes |
| `integer()` | `i64` | Always use signed integers. Rustler maps `i64` to Elixir integers seamlessly |
| `boolean()` | `bool` | Direct mapping |
| `atom()` | `Atom` | Use `rustler::Atom`. Define atoms with `rustler::atoms!{}` macro |
| `map()` | `HashMap<String, T>` or struct | Prefer struct with `NifStruct` derive. Use HashMap only for truly dynamic keys |
| `list(T)` | `Vec<T>` | Direct mapping. Element types must also be NIF-compatible |
| `{:ok, T}` | `Result<T, E>` | Rustler auto-converts `Ok(v)` to `{:ok, v}` and `Err(e)` to `{:error, e}` |
| `nil` | `Option<T>` | `None` becomes `nil`, `Some(v)` becomes `v` |
| `{:error, String.t()}` | `Result<T, String>` | Standard error pattern |
| `:ok` (bare atom) | `Atom` | Return `rustler::atoms::ok()` |
| `reference()` | `ResourceArc<T>` | Opaque handle. Elixir never inspects the contents |

```rust
// Defining atoms for use in return values
rustler::atoms! {
    ok,
    error,
    clean,
    dirty,
    merging,
    rebasing,
}

// Using Option<T> for nullable fields
#[derive(NifStruct)]
#[module = "Valkka.Git.NifBranch"]
struct BranchInfo {
    name: String,          // always present
    target: String,        // always present
    upstream: Option<String>, // None → nil in Elixir
    is_head: bool,
    ahead: i64,
    behind: i64,
}
```

### 3.2 Adding a New NIF (Checklist)

Follow this checklist every time you add a new NIF function.

**Step 1: Define the Rust function**

```rust
// In the appropriate module (e.g., src/search.rs)
#[rustler::nif(schedule = "DirtyCpu")]
fn file_history(
    handle: ResourceArc<RepoHandle>,
    path: String,
    opts: FileHistoryOpts,
) -> Result<Vec<CommitInfo>, String> {
    safe_nif(|| {
        let repo = handle.repo.lock()
            .map_err(|_| format!("lock poisoned for {}", handle.path.display()))?;
        // ... implementation
    })
}
```

**Step 2: Register the NIF in `lib.rs`**

```rust
rustler::init!(
    "Elixir.Valkka.Git.Native",
    [
        repo_open,
        repo_info,
        // ... existing NIFs
        file_history,  // <-- add here
    ]
);
```

**Step 3: Add the Elixir stub in `Valkka.Git.Native`**

```elixir
defmodule Valkka.Git.Native do
  use Rustler, otp_app: :valkka, crate: :valkka_git

  # ... existing stubs

  @spec file_history(reference(), String.t(), map()) ::
          {:ok, [map()]} | {:error, String.t()}
  def file_history(_handle, _path, _opts), do: :erlang.nif_error(:not_loaded)
end
```

**Step 4: Add the high-level wrapper in `Valkka.Git.Commands`**

```elixir
defmodule Valkka.Git.Commands do
  @spec file_history(reference(), String.t(), keyword()) ::
          {:ok, [Commit.t()]} | {:error, Error.t()}
  def file_history(handle, path, opts \\ []) do
    nif_opts = %{limit: Keyword.get(opts, :limit, 50)}

    case Native.file_history(handle, path, nif_opts) do
      {:ok, raw_commits} ->
        {:ok, Enum.map(raw_commits, &Commit.from_nif_map/1)}

      {:error, reason} ->
        {:error, %Error{code: :git_error, message: reason}}
    end
  end
end
```

**Step 5: Write tests at both layers**

```rust
// Rust unit test
#[test]
fn file_history_returns_commits_touching_file() {
    let (_dir, repo) = create_repo_with_file_changes("README.md", 5);
    let commits = file_history_impl(&repo, "README.md", &Default::default());
    assert!(commits.is_ok());
    assert_eq!(commits.unwrap().len(), 5);
}
```

```elixir
# Elixir integration test
test "file_history returns commits for specific file", %{handle: handle} do
  {:ok, commits} = Valkka.Git.Commands.file_history(handle, "README.md")
  assert length(commits) > 0
  assert %Valkka.Git.Commit{} = hd(commits)
end
```

**Step 6: Add to the NIF contract doc (docs/nif-contract.md)**

Document the function signature, parameters, return shape, and errors.

### 3.3 Deprecating a NIF

Never remove a NIF in one step. Follow this migration path:

1. **Keep the old NIF**, add `@deprecated` in the Elixir wrapper
2. **Add the new NIF** alongside the old one
3. **Migrate all callers** to the new NIF
4. **Remove the old NIF** in a subsequent release

```elixir
# Step 1-2: old and new coexist
defmodule Valkka.Git.Native do
  @deprecated "Use diff_v2/3 instead"
  def diff(_handle, _from, _to), do: :erlang.nif_error(:not_loaded)

  def diff_v2(_handle, _from, _to), do: :erlang.nif_error(:not_loaded)
end
```

---

## 4. Frontend Conventions

### 4.1 JS Hooks

One hook per interactive component. Name hooks `{Component}Hook`.

```javascript
// assets/js/hooks/graph_hook.js
const GraphHook = {
  mounted() {
    this.canvas = this.el.querySelector("canvas");
    this.ctx = this.canvas.getContext("2d");
    this.renderGraph(this.el.dataset.graph);

    // Receive updates from server
    this.handleEvent("graph_updated", ({ graph }) => {
      this.renderGraph(graph);
    });
  },

  updated() {
    // Called when LiveView re-renders the parent element
    // Re-read data attributes if they changed
    const newGraph = this.el.dataset.graph;
    if (newGraph !== this.lastGraph) {
      this.renderGraph(newGraph);
    }
  },

  destroyed() {
    // Clean up WebGL contexts, animation frames, event listeners
    if (this.animationFrame) {
      cancelAnimationFrame(this.animationFrame);
    }
  },

  renderGraph(graphJson) {
    this.lastGraph = graphJson;
    const data = JSON.parse(graphJson);
    // ... rendering logic
  }
};

export default GraphHook;
```

```javascript
// assets/js/hooks/diff_hook.js
const DiffHook = {
  mounted() {
    this.highlightSyntax();
  },

  updated() {
    this.highlightSyntax();
  },

  destroyed() {
    // nothing to clean up
  },

  highlightSyntax() {
    // Apply syntax highlighting to code blocks
    this.el.querySelectorAll("code").forEach(block => {
      // ... highlighting
    });
  }
};

export default DiffHook;
```

Register all hooks in `app.js`:

```javascript
// assets/js/app.js
import GraphHook from "./hooks/graph_hook";
import DiffHook from "./hooks/diff_hook";

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: {
    GraphHook,
    DiffHook,
  },
  params: { _csrf_token: csrfToken },
});
```

### 4.2 Hook Lifecycle

| Callback | When | Use for |
|---|---|---|
| `mounted()` | Element first inserted into DOM | Initialize, attach listeners, set up WebGL/Canvas |
| `updated()` | Parent LiveView re-rendered | Re-read data attributes, update visuals |
| `destroyed()` | Element removed from DOM | Clean up: cancel animation frames, remove listeners, release GPU resources |

```javascript
// GOOD: full lifecycle management
const StreamHook = {
  mounted() {
    this.buffer = [];
    this.handleEvent("ai_chunk", ({ chunk }) => {
      this.buffer.push(chunk);
      this.renderChunks();
    });
    this.handleEvent("ai_complete", () => {
      this.finalize();
    });
  },

  updated() {
    // Scroll to bottom when new content arrives
    this.el.scrollTop = this.el.scrollHeight;
  },

  destroyed() {
    this.buffer = null;
  },

  renderChunks() {
    const content = this.buffer.join("");
    this.el.querySelector(".stream-content").textContent = content;
    this.el.scrollTop = this.el.scrollHeight;
  },

  finalize() {
    // Parse markdown, add action buttons, etc.
  }
};
```

### 4.3 PubSub in LiveView

Subscribe in `mount`, handle in `handle_info`.

```elixir
defmodule ValkkaWeb.RepoLive do
  use ValkkaWeb, :live_view

  @impl true
  def mount(%{"id" => repo_id}, _session, socket) do
    if connected?(socket) do
      # Subscribe to repo events
      Phoenix.PubSub.subscribe(Valkka.PubSub, "repo:#{repo_id}")
      Phoenix.PubSub.subscribe(Valkka.PubSub, "repo:#{repo_id}:ai")
      Phoenix.PubSub.subscribe(Valkka.PubSub, "repo:#{repo_id}:ci")
    end

    status = Valkka.Repo.Worker.status(repo_id)

    {:ok, assign(socket,
      repo_id: repo_id,
      status: status,
      ai_chunks: [],
      ai_streaming: false
    )}
  end

  # Handle repo state changes
  @impl true
  def handle_info({:repo_refreshed, new_status}, socket) do
    {:noreply, assign(socket, status: new_status)}
  end

  # Handle AI streaming chunks
  def handle_info({:ai_chunk, chunk}, socket) do
    {:noreply, assign(socket,
      ai_chunks: socket.assigns.ai_chunks ++ [chunk],
      ai_streaming: true
    )}
  end

  # Handle AI stream completion
  def handle_info({:ai_complete, _response}, socket) do
    {:noreply, assign(socket, ai_streaming: false)}
  end

  # Handle CI status
  def handle_info({:ci_status_updated, ci_status}, socket) do
    {:noreply, assign(socket, ci_status: ci_status)}
  end
end
```

### 4.4 Streaming

Append to assigns list, render incrementally. Never replace the entire list on each chunk.

```elixir
# GOOD: append to list in assigns
def handle_info({:ai_chunk, chunk}, socket) do
  {:noreply, assign(socket,
    ai_chunks: socket.assigns.ai_chunks ++ [chunk]
  )}
end

# In template — render all chunks
# <div id="ai-response" phx-hook="StreamHook">
#   <%= for chunk <- @ai_chunks do %>
#     <span><%= chunk %></span>
#   <% end %>
# </div>

# BAD: re-assigning entire string each time (causes full re-render)
def handle_info({:ai_chunk, chunk}, socket) do
  {:noreply, assign(socket,
    ai_response: socket.assigns.ai_response <> chunk  # re-renders everything
  )}
end
```

For large streams, use `Phoenix.LiveView.stream/3` (LiveView 0.19+):

```elixir
def mount(_params, _session, socket) do
  {:ok, stream(socket, :ai_chunks, [])}
end

def handle_info({:ai_chunk, chunk}, socket) do
  chunk_item = %{id: System.unique_integer(), text: chunk}
  {:noreply, stream_insert(socket, :ai_chunks, chunk_item)}
end
```

---

## 5. AI Integration Patterns

### 5.1 Provider Behaviour

All AI providers implement the same behaviour. Swap providers without changing application code.

```elixir
defmodule Valkka.AI.Provider do
  @moduledoc "Behaviour for AI/LLM providers."

  @type stream_opts :: [
    model: String.t(),
    max_tokens: pos_integer(),
    temperature: float()
  ]

  @callback stream(prompt :: String.t(), opts :: stream_opts()) ::
    {:ok, Enumerable.t()} | {:error, term()}

  @callback complete(prompt :: String.t(), opts :: stream_opts()) ::
    {:ok, String.t()} | {:error, term()}
end

defmodule Valkka.AI.Providers.Anthropic do
  @behaviour Valkka.AI.Provider

  @impl true
  def stream(prompt, opts) do
    model = Keyword.get(opts, :model, default_model())
    max_tokens = Keyword.get(opts, :max_tokens, 4096)

    # Return an enumerable stream of chunks
    {:ok, do_stream(prompt, model, max_tokens)}
  end

  @impl true
  def complete(prompt, opts) do
    case stream(prompt, opts) do
      {:ok, stream} -> {:ok, Enum.join(stream)}
      error -> error
    end
  end

  defp default_model do
    Application.get_env(:valkka, :ai_model, "claude-sonnet-4-20250514")
  end
end

defmodule Valkka.AI.Providers.Mock do
  @behaviour Valkka.AI.Provider

  @impl true
  def stream(prompt, _opts) do
    response = cond do
      prompt =~ "commit message" ->
        "feat: add user authentication"
      prompt =~ "review" ->
        "## Summary\nLow risk change."
      true ->
        "I understand your request."
    end

    chunks = response
    |> String.graphemes()
    |> Enum.chunk_every(5)
    |> Enum.map(&Enum.join/1)

    {:ok, chunks}
  end

  @impl true
  def complete(prompt, opts) do
    {:ok, stream} = stream(prompt, opts)
    {:ok, Enum.join(stream)}
  end
end
```

### 5.2 Context Budget

Count tokens. Truncate oldest context first. Never exceed the model's context window.

```elixir
defmodule Valkka.AI.ContextBuilder do
  @moduledoc "Builds AI prompts from repo state, respecting token budgets."

  # Rough estimate: 1 token ~ 4 characters for English text, ~3 for code
  @chars_per_token 3.5

  @spec build(String.t(), atom(), keyword()) :: String.t()
  def build(repo_id, intent, opts \\ []) do
    budget = Keyword.get(opts, :token_budget, 8000)

    sections = [
      {:system, system_prompt(), :required},
      {:diff, get_diff_context(repo_id), :required},
      {:history, get_recent_history(repo_id), :optional},
      {:kerto, get_kerto_context(repo_id), :optional},
      {:sykli, get_ci_context(repo_id), :optional}
    ]

    fit_to_budget(sections, budget)
  end

  defp fit_to_budget(sections, budget) do
    # First pass: add all required sections
    {required, optional} = Enum.split_with(sections, fn {_, _, priority} ->
      priority == :required
    end)

    required_text = required
    |> Enum.map(fn {_name, content, _} -> content end)
    |> Enum.join("\n\n")

    remaining = budget - estimate_tokens(required_text)

    # Second pass: add optional sections until budget exhausted
    optional_text = optional
    |> Enum.reduce_while("", fn {_name, content, _}, acc ->
      tokens = estimate_tokens(content)
      if tokens <= remaining do
        {:cont, acc <> "\n\n" <> content}
      else
        # Truncate this section to fit
        truncated = truncate_to_tokens(content, remaining)
        {:halt, acc <> "\n\n" <> truncated}
      end
    end)

    required_text <> optional_text
  end

  defp estimate_tokens(text) do
    (String.length(text) / @chars_per_token) |> ceil()
  end

  defp truncate_to_tokens(text, max_tokens) do
    max_chars = floor(max_tokens * @chars_per_token)
    String.slice(text, 0, max_chars) <> "\n... (truncated)"
  end
end
```

### 5.3 Prompt Templates

Store in `priv/prompts/`, version controlled. Never inline prompts in application code.

```
priv/prompts/
├── commit_message.txt
├── pr_review.txt
├── conflict_resolution.txt
├── explain_diff.txt
└── intent_classification.txt
```

```elixir
defmodule Valkka.AI.Prompts do
  @moduledoc "Loads and renders prompt templates from priv/prompts/."

  @prompts_dir Application.app_dir(:valkka, "priv/prompts")

  @spec render(atom(), map()) :: String.t()
  def render(template_name, variables) do
    template_name
    |> load_template()
    |> interpolate(variables)
  end

  defp load_template(name) do
    path = Path.join(@prompts_dir, "#{name}.txt")
    File.read!(path)
  end

  defp interpolate(template, variables) do
    Enum.reduce(variables, template, fn {key, value}, acc ->
      String.replace(acc, "{{#{key}}}", to_string(value))
    end)
  end
end

# Usage:
prompt = Valkka.AI.Prompts.render(:commit_message, %{
  diff: semantic_diff_text,
  recent_commits: recent_messages,
  repo_name: "valkka"
})
```

Example template (`priv/prompts/commit_message.txt`):

```
You are generating a git commit message for the repository "{{repo_name}}".

Based on the following semantic diff, write a commit message following
conventional commits format (feat:, fix:, refactor:, docs:, test:, chore:).

Keep the first line under 72 characters.
Add a blank line and a body paragraph if the change is non-trivial.

## Semantic Diff
{{diff}}

## Recent Commit Messages (for style reference)
{{recent_commits}}
```

### 5.4 Never Hardcode Model Names

Model names must always come from configuration.

```elixir
# BAD: hardcoded model
def stream(prompt) do
  Req.post!("https://api.anthropic.com/v1/messages",
    json: %{model: "claude-sonnet-4-20250514", ...}  # DON'T
  )
end

# GOOD: configurable model
def stream(prompt, opts \\ []) do
  model = Keyword.get(opts, :model, Application.get_env(:valkka, :ai_model))

  Req.post!("https://api.anthropic.com/v1/messages",
    json: %{model: model, ...}
  )
end

# config/config.exs
config :valkka, :ai_model, "claude-sonnet-4-20250514"

# User can override via environment
# VALKKA_AI_MODEL=claude-opus-4-20250514 ./valkka
```

---

## 6. Git Conventions for Valkka Development

### 6.1 Branch Naming

```
feat/graph-rendering       # New feature
fix/nif-panic-on-empty     # Bug fix
refactor/ai-provider       # Code restructuring (no behavior change)
docs/nif-contract          # Documentation only
test/semantic-diff-rust    # Test additions only
chore/deps-update          # Dependency updates, CI config
```

**Rules:**
- Lowercase, hyphen-separated
- Prefix is mandatory
- Keep it short but descriptive (max ~40 characters)
- No issue numbers in the branch name (put them in the PR)

### 6.2 Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/).

```
feat: add semantic diff for Elixir files

Integrate tree-sitter-elixir grammar to detect function additions,
removals, and signature changes in .ex files.

Closes #42
```

**Format:**

```
<type>(<optional scope>): <description>

<optional body>

<optional footer>
```

**Types:**

| Type | When |
|---|---|
| `feat` | New feature visible to users |
| `fix` | Bug fix |
| `refactor` | Code change that neither fixes a bug nor adds a feature |
| `test` | Adding or correcting tests |
| `docs` | Documentation only |
| `chore` | Build process, dependencies, CI |
| `perf` | Performance improvement |
| `style` | Formatting, missing semicolons (no code change) |

**Scopes (optional):**

```
feat(nif): add file_history function
fix(ai): handle stream timeout gracefully
refactor(repo): extract status refresh into helper
test(graph): add merge topology test cases
chore(deps): update rustler to 0.34
```

**Rules:**
- First line under 72 characters
- Use imperative mood: "add", not "added" or "adds"
- Body explains *why*, not *what* (the diff shows *what*)
- Reference issues in the footer

### 6.3 PR Size

**Maximum 400 lines changed.** Split larger work into stacked PRs.

| PR size | Classification | Action |
|---|---|---|
| < 100 lines | Small | Review immediately |
| 100-400 lines | Medium | Review within 1 day |
| > 400 lines | Too large | Split before review |

**How to split large work:**

1. **Layer by layer:** First PR adds the NIF, second PR adds the Elixir wrapper, third PR adds the LiveView integration.
2. **Feature flag:** Land incomplete features behind a config flag.
3. **Refactor first:** Extract refactoring into its own PR before the feature PR.

```
# Example: adding semantic diff for a new language

PR 1: feat(nif): add tree-sitter-python grammar (~150 lines)
PR 2: feat(nif): implement Python semantic diff detection (~200 lines)
PR 3: feat: expose Python semantic diff in Elixir layer (~100 lines)
PR 4: test: add golden file tests for Python semantic diff (~150 lines)
```

### 6.4 Pre-commit Checklist

Before committing, verify:

```bash
# Format Elixir code
mix format

# Run Elixir tests
mix test

# Run Rust tests
cd native/valkka_git && cargo test

# Run Rust linter
cd native/valkka_git && cargo clippy -- -D warnings

# Check for compiler warnings
mix compile --warnings-as-errors
```

If using Sykli:

```bash
sykli   # runs format -> compile -> test -> clippy
```

### 6.5 Code Review Standards

When reviewing PRs, check for:

1. **NIF safety:** No `.unwrap()`, all NIFs use `safe_nif`, all use `DirtyCpu`
2. **Error handling:** `with`/`case`/crash used appropriately
3. **Type specs:** All public functions have `@spec`
4. **Tests:** Domain tests are pure (no GenServer), NIF tests at both layers
5. **Naming:** Follows module hierarchy, uses ubiquitous language from domain model
6. **PR size:** Under 400 lines changed
7. **Commit messages:** Conventional commits format

---

## Quick Reference Card

```
ELIXIR                          RUST NIF
-----------                     --------
Match in function heads         Never panic — use Result<T, String>
with for multi-step fallible    Wrap in safe_nif(|| { ... })
case for branching              Always schedule = "DirtyCpu"
Let it crash for bugs           Error messages include context
@spec all public functions      NifStruct for return types
call for reads, cast for F&F    ResourceArc + Mutex for handles
|> for transforms, not effects  Document unsafe Send/Sync

FRONTEND                        AI
--------                        --
One hook per component           Provider behaviour with stream/2
mounted/updated/destroyed        Token budget — truncate oldest first
Subscribe in mount               Prompts in priv/prompts/
Stream: append to assigns        Never hardcode model names

GIT                              BOUNDARIES
---                              ----------
feat/ fix/ refactor/ docs/       Elixir String = Rust String (UTF-8)
Conventional commits             {:ok, T} = Result<T, E>
Max 400 lines per PR             nil = Option<T> None
Imperative mood                  integer() = i64 (always signed)
```
