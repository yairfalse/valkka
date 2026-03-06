# Valkka Architecture v2

> AI-native git command center for agent-driven workflows.
> This is the definitive architecture. v1 was exploration. v2 is the blueprint.

---

## 0. What Changed from v1

| v1 Problem | v2 Decision |
|---|---|
| LiveView + JS hooks is a frankenstack | LiveView for state, JS hooks ARE the rendering layer. Not SolidJS/Svelte. |
| NIF boundary too wide (25+ functions) | 8 NIF functions for MVP. Shell out for everything else. |
| No offline-first story | Offline by default. AI degrades gracefully. Git always works. |
| No plugin system | Behaviour-based plugins with lifecycle hooks and command registration. |
| UX architecture is shallow | Command palette, panel system, vim bindings, full keyboard-driven UX. |
| Supervision tree is naive | gen_statem for repos, Task.Supervisor for NIFs, circuit breaker for AI. |

---

## 1. Frontend Architecture: LiveView as App Shell, JS as Rendering Layer

### The Decision

LiveView manages state, routing, auth, and data flow. JavaScript (via LiveView hooks) owns all pixel-level rendering. This is not a compromise -- it is the correct separation of concerns for this application.

### Why Not SolidJS/Svelte as a Separate Frontend

The alternative -- SolidJS or Svelte as a standalone SPA with Phoenix as a pure JSON API -- was evaluated and rejected for these reasons:

1. **Real-time is the core product.** File watchers, AI token streaming, repo status changes -- every feature is real-time. LiveView gets this for free via PubSub. A separate SPA needs WebSocket plumbing, reconnection logic, state reconciliation, and a custom protocol. That is weeks of infrastructure work that produces exactly what LiveView already does.

2. **State lives on the server.** Repository handles (ResourceArcs), file watcher subscriptions, AI stream sessions -- all of this lives in BEAM processes. The frontend needs to reflect this state, not own it. LiveView's server-rendered model means the UI always shows the truth. An SPA would cache stale state and need invalidation logic.

3. **We already need Tauri.** The native app strategy (documented in native-app.md) wraps a WebView around `localhost:4420`. Whether that WebView renders LiveView HTML or a SolidJS SPA is invisible to the user. The Tauri shell provides native shortcuts, system tray, and file dialogs regardless.

4. **Two render targets, one state manager.** The chat interface, status bars, repo list, and notification toasts are simple enough for LiveView to render directly (server-rendered HTML, no hook needed). The graph and diff viewer are complex enough to demand JS. LiveView lets us use both in the same page without a build boundary.

5. **Team size.** This is a small team. Maintaining a separate frontend repo with its own build, types, and deployment is overhead that does not improve the product.

### The Contract Between LiveView and JS Hooks

LiveView sends **data** to hooks. Hooks send **events** back to LiveView. They never share DOM manipulation.

```
LiveView (Elixir)                    JS Hook
─────────────────                    ────────
assigns graph_data ──pushEvent──→    GraphHook.handleEvent("graph:update", data)
                                       → renders to <canvas> via WebGL
                                       → user clicks node
                  ←──pushEvent──     this.pushEvent("node_selected", {oid: "abc123"})
assigns diff_data ──pushEvent──→     DiffHook.handleEvent("diff:update", data)
                                       → renders syntax-highlighted diff
                                       → user selects lines
                  ←──pushEvent──     this.pushEvent("lines_selected", {range: [10, 25]})
```

### Which Components Use Hooks vs Pure LiveView

| Component | Rendering | Why |
|---|---|---|
| Dashboard (repo cards, status) | Pure LiveView | Simple HTML, real-time updates via PubSub |
| Chat interface | Pure LiveView | Text rendering, streaming tokens append to DOM |
| Command palette | Pure LiveView | Modal overlay, keyboard handling in phx-window-keydown |
| Notification toasts | Pure LiveView | Simple HTML, auto-dismiss via JS.push |
| Repo status bar | Pure LiveView | Text + badges |
| Commit graph | **JS Hook (WebGL)** | 60fps pan/zoom, 50k nodes, GPU rendering |
| Diff viewer | **JS Hook** | Syntax highlighting, line-level selection, side-by-side scroll sync |
| Branch topology minimap | **JS Hook (Canvas)** | Compact visual, interactive hover |

### Hook Architecture

Each hook is a self-contained rendering unit. They share no global state.

```
assets/js/hooks/
  graph_hook.js          WebGL commit graph renderer
  diff_hook.js           Syntax-highlighted diff with virtual scrolling
  minimap_hook.js        Branch topology minimap (Canvas 2D)
  index.js               Hook registry (exports all hooks for liveSocket)
```

Hooks are loaded via the standard Phoenix LiveView hook mechanism:

```javascript
// assets/js/app.js
import { GraphHook } from "./hooks/graph_hook"
import { DiffHook } from "./hooks/diff_hook"
import { MinimapHook } from "./hooks/minimap_hook"

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: { GraphHook, DiffHook, MinimapHook },
  params: { _csrf_token: csrfToken }
})
```

### Graph Renderer: WebGL

The commit graph is the most demanding visual component. Requirements:

- 1,000 commits in < 100ms render
- 50,000 commits with virtualized viewport
- 60fps pan and zoom
- Click/hover interactions feed back to LiveView

Technology: **Raw WebGL with a thin abstraction layer.** Not Three.js (too heavy), not SVG (too slow at scale), not Canvas 2D (no GPU acceleration for this many elements).

The graph hook receives a `%GraphLayout{}` from the Rust NIF (positions already computed) and draws it. Rust does the math. WebGL draws the pixels. LiveView manages which data is visible.

### Diff Renderer

The diff viewer uses a virtual-scrolling approach with syntax highlighting. For MVP, we use a lightweight JS library (CodeMirror 6 in read-only mode) wrapped in a hook. CodeMirror handles syntax highlighting for all languages tree-sitter supports on the Rust side, so the visual and semantic layers agree on language parsing.

---

## 2. NIF Boundary: 8 Functions for MVP

### The Principle

NIF what must be fast. Shell out for everything else. The v1 NIF surface had 25+ functions -- that is a maintenance burden, a build complexity multiplier, and a crash surface area that is too large.

The new boundary: **8 NIF functions** that cover all read-heavy, performance-critical paths. Everything that mutates remote state or runs infrequently goes through `System.cmd("git", ...)`.

### The 8 NIF Functions

```
Valkka.Git.Native
  repo_open(path)                     → {:ok, handle} | {:error, reason}
  repo_close(handle)                  → :ok
  status(handle)                      → {:ok, %Status{}}
  log(handle, opts)                   → {:ok, [%Commit{}]}
  diff(handle, opts)                  → {:ok, %Diff{}}
  semantic_diff(handle, opts)         → {:ok, %SemanticDiff{}}
  commit(handle, message, paths, opts) → {:ok, oid} | {:error, reason}
  graph(handle, opts)                 → {:ok, %GraphLayout{}}
```

### What Each Function Does

#### `repo_open(path) -> {:ok, handle} | {:error, reason}`

Opens a git2::Repository, wraps in ResourceArc<RepoHandle>. Same as v1. Schedule: `DirtyCpu`.

#### `repo_close(handle) -> :ok`

Explicit drop. Optional since BEAM GC handles it, but useful for deterministic cleanup when switching repos.

#### `status(handle) -> {:ok, %Status{}}`

Combines v1's `repo_info` and `branches` into a single call. One NIF round-trip instead of two.

```elixir
%Status{
  head: "abc123...",
  branch: "main" | nil,
  state: :clean | :dirty | :merging | :rebasing | :cherry_picking,
  staged: [%FileDelta{}],
  unstaged: [%FileDelta{}],
  untracked: [path],
  ahead: integer,
  behind: integer,
  branches: [%Branch{name, target, is_head, upstream, ahead, behind}]
}
```

#### `log(handle, opts) -> {:ok, [%Commit{}]}`

Commit history with filtering. Opts: `limit`, `since`, `until`, `author`, `path`, `branch`.

#### `diff(handle, opts) -> {:ok, %Diff{}}`

All diff types via opts. This replaces v1's `diff`, `diff_stats`, and the separate `from`/`to` parameters.

```elixir
# Opts:
%{
  from: "HEAD" | "STAGED" | "WORKDIR" | oid | branch,
  to: "HEAD" | "STAGED" | "WORKDIR" | oid | branch,
  stats_only: boolean    # true = no hunks, just file-level stats
}
```

Common patterns:
- `diff(handle, %{from: "HEAD", to: "STAGED"})` -- staged changes
- `diff(handle, %{from: "STAGED", to: "WORKDIR"})` -- unstaged changes
- `diff(handle, %{from: "main", to: "feat/x"})` -- branch diff
- `diff(handle, %{from: "abc123", to: "def456", stats_only: true})` -- quick stats

#### `semantic_diff(handle, opts) -> {:ok, %SemanticDiff{}}`

Tree-sitter-powered structural diff. Same opts as `diff` (from, to). Returns function/type/import level changes. This is the technical moat -- it stays in Rust because tree-sitter is C/Rust only and the AST comparison is CPU-intensive.

#### `commit(handle, message, paths, opts) -> {:ok, oid} | {:error, reason}`

Stage + commit in one call. Paths is a list of files to stage (empty = stage all tracked modified). This eliminates the separate `stage`/`unstage`/`commit` round-trips.

```elixir
# Opts:
%{
  author_name: String | nil,    # nil = git config
  author_email: String | nil,
  amend: boolean                # default false
}
```

#### `graph(handle, opts) -> {:ok, %GraphLayout{}}`

Compute visual layout for the commit graph. This must be a NIF because the layout algorithm is O(n * max_columns) and runs on every graph view/scroll.

```elixir
# Opts:
%{
  limit: integer,          # max commits (default 500)
  offset: integer,         # for virtualized scrolling
  branch: String | nil     # filter to branch
}

# Returns:
%GraphLayout{
  nodes: [%GraphNode{oid, column, row, message, author, timestamp, branch, is_merge, parents}],
  max_columns: integer,
  branches: [%{name, column, color_index}],
  total_commits: integer
}
```

### Everything Else: Shell Out via System.cmd

These operations are infrequent (user-initiated, not on hot paths) and benefit from using the real `git` CLI which handles edge cases (auth, config, hooks) that git2-rs does not.

```elixir
defmodule Valkka.Git.CLI do
  @moduledoc """
  Git operations via System.cmd. For operations that don't need NIF speed
  or that benefit from git CLI's full feature set (auth, hooks, config).
  """

  def merge(repo_path, source, opts \\ []) do
    args = ["merge", source]
    args = if opts[:no_ff], do: args ++ ["--no-ff"], else: args
    run(repo_path, args)
  end

  def rebase(repo_path, onto, opts \\ []) do
    args = ["rebase", onto]
    args = if opts[:interactive], do: args ++ ["-i"], else: args
    run(repo_path, args)
  end

  def push(repo_path, remote \\ "origin", branch \\ nil, opts \\ []) do
    args = ["push", remote]
    args = if branch, do: args ++ [branch], else: args
    args = if opts[:force], do: args ++ ["--force-with-lease"], else: args
    args = if opts[:set_upstream], do: args ++ ["-u"], else: args
    run(repo_path, args)
  end

  def pull(repo_path, remote \\ "origin", branch \\ nil) do
    args = ["pull", remote]
    args = if branch, do: args ++ [branch], else: args
    run(repo_path, args)
  end

  def cherry_pick(repo_path, oid) do
    run(repo_path, ["cherry-pick", oid])
  end

  def stash(repo_path, message \\ nil) do
    args = ["stash"]
    args = if message, do: args ++ ["push", "-m", message], else: args
    run(repo_path, args)
  end

  def stash_pop(repo_path) do
    run(repo_path, ["stash", "pop"])
  end

  def checkout(repo_path, ref, opts \\ []) do
    args = ["checkout", ref]
    args = if opts[:create], do: ["-b" | args], else: args
    run(repo_path, args)
  end

  def create_branch(repo_path, name, start_point \\ nil) do
    args = ["checkout", "-b", name]
    args = if start_point, do: args ++ [start_point], else: args
    run(repo_path, args)
  end

  def delete_branch(repo_path, name, opts \\ []) do
    flag = if opts[:force], do: "-D", else: "-d"
    run(repo_path, ["branch", flag, name])
  end

  def blame(repo_path, file_path) do
    run(repo_path, ["blame", "--porcelain", file_path])
  end

  defp run(repo_path, args) do
    case System.cmd("git", args, cd: repo_path, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, %{code: code, output: output}}
    end
  end
end
```

### Why This Split

| Operation | NIF or CLI | Reason |
|---|---|---|
| status | NIF | Called on every file change event. Must be < 20ms. |
| log | NIF | Browsing history. Frequent, latency-sensitive. |
| diff | NIF | Viewing diffs. Frequent, structured data needed. |
| semantic_diff | NIF | tree-sitter is Rust-only. CPU-intensive. |
| graph | NIF | Layout computation. O(n * cols). Called on scroll. |
| commit | NIF | Stage + commit atomically. Frequent operation. |
| merge | CLI | Infrequent. git CLI handles three-way merge edge cases and hooks. |
| rebase | CLI | Infrequent. Interactive rebase is complex in git2-rs. |
| push/pull | CLI | Network operations. git CLI handles SSH/HTTPS auth, credential helpers. |
| cherry-pick | CLI | Infrequent. Conflict handling is simpler via CLI. |
| stash | CLI | Infrequent. Simple operation. |
| checkout | CLI | Infrequent. git CLI handles submodule updates, hooks. |
| blame | CLI | Infrequent. Porcelain output is easy to parse. |
| branch CRUD | CLI | Infrequent. Trivial operations. |

---

## 3. Offline-First Architecture

### Principle

Git is local. Valkka is a local application. Offline is the default state. Network is optional.

### What Works Offline (Everything Except Remote Operations)

All git read operations: status, log, diff, semantic_diff, graph, blame, file history.
All git local write operations: commit, branch, merge, rebase, cherry-pick, stash.
File watching and real-time updates.
Intent parsing (regex fast path).
Full UI including graph, diff viewer, chat interface.
Plugins (local hooks and commands).

### What Requires Network

Push, pull, fetch.
Remote AI providers (OpenAI, Anthropic).
GitHub/GitLab API (PR reviews, issue linking).

### AI Provider Behaviour with Offline Adapter

```elixir
defmodule Valkka.AI.Provider do
  @moduledoc "Behaviour for AI providers. Swap between cloud and local."

  @callback stream(prompt :: String.t(), opts :: keyword()) ::
    {:ok, Enumerable.t()} | {:error, term()}

  @callback available?() :: boolean()

  @callback name() :: String.t()
end

defmodule Valkka.AI.Providers.Anthropic do
  @behaviour Valkka.AI.Provider

  @impl true
  def stream(prompt, opts) do
    # Req HTTP client with SSE streaming
    # Returns enumerable of token chunks
  end

  @impl true
  def available? do
    case Req.head("https://api.anthropic.com/v1/messages", receive_timeout: 2_000) do
      {:ok, %{status: status}} when status < 500 -> true
      _ -> false
    end
  end

  @impl true
  def name, do: "Anthropic Claude"
end

defmodule Valkka.AI.Providers.Ollama do
  @behaviour Valkka.AI.Provider

  @impl true
  def stream(prompt, opts) do
    model = Keyword.get(opts, :model, "llama3.2")
    # Ollama runs locally on port 11434
    # Same streaming interface as cloud providers
    url = "http://localhost:11434/api/generate"
    body = %{model: model, prompt: prompt, stream: true}
    # Stream response chunks
  end

  @impl true
  def available? do
    case Req.head("http://localhost:11434/api/tags", receive_timeout: 1_000) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  end

  @impl true
  def name, do: "Ollama (local)"
end

defmodule Valkka.AI.Providers.Null do
  @moduledoc "No-op provider. Used when no AI is available."
  @behaviour Valkka.AI.Provider

  @impl true
  def stream(_prompt, _opts), do: {:error, :no_ai_available}

  @impl true
  def available?, do: false

  @impl true
  def name, do: "None (offline)"
end
```

### Provider Selection Logic

```elixir
defmodule Valkka.AI.ProviderSelector do
  @moduledoc "Selects the best available AI provider."

  def select(config) do
    preferred = config.ai_provider

    cond do
      preferred != :auto and provider_module(preferred).available?() ->
        provider_module(preferred)

      Valkka.AI.Providers.Anthropic.available?() ->
        Valkka.AI.Providers.Anthropic

      Valkka.AI.Providers.Ollama.available?() ->
        Valkka.AI.Providers.Ollama

      true ->
        Valkka.AI.Providers.Null
    end
  end

  defp provider_module(:anthropic), do: Valkka.AI.Providers.Anthropic
  defp provider_module(:openai), do: Valkka.AI.Providers.OpenAI
  defp provider_module(:ollama), do: Valkka.AI.Providers.Ollama
end
```

### Graceful Degradation

| Subsystem | Online | Offline | UI Indicator |
|---|---|---|---|
| Git (local ops) | Full | Full | None (always works) |
| Git (push/pull) | Full | Disabled | "Offline -- push/pull unavailable" |
| AI (cloud) | Streaming | Disabled | "AI: offline" in status bar |
| AI (Ollama) | Streaming | Streaming | "AI: Ollama (local)" in status bar |
| AI (none) | N/A | Regex intent only | "AI: none -- using patterns only" |
| Kerto | Full | Full (embedded) | None (always works) |
| Sykli | Full | Full (local exec) | None (always works) |
| PR reviews | Full | Disabled | "GitHub: offline" |

### Intent Parser Fast Path (No LLM Required)

The regex-based intent parser handles 80%+ of common commands without any AI:

```elixir
defmodule Valkka.AI.IntentParser do
  @fast_patterns [
    {~r/^commit$/i, {:ai_op, :generate_commit_msg, %{}}},
    {~r/^commit (.+)$/i, fn [msg] -> {:git_op, :commit, %{message: msg}} end},
    {~r/^switch to (.+)$/i, fn [ref] -> {:git_op, :checkout, %{ref: ref}} end},
    {~r/^checkout (.+)$/i, fn [ref] -> {:git_op, :checkout, %{ref: ref}} end},
    {~r/^push$/i, {:git_op, :push, %{}}},
    {~r/^pull$/i, {:git_op, :pull, %{}}},
    {~r/^status$/i, {:query, :status, %{}}},
    {~r/^what changed(?:\s+today)?$/i, {:query, :changes_since, %{since: :today}}},
    {~r/^what changed (?:in the )?last (\d+) days?$/i,
      fn [n] -> {:query, :changes_since, %{since: {:days_ago, String.to_integer(n)}}} end},
    {~r/^show (?:the )?diff$/i, {:query, :diff, %{}}},
    {~r/^show (?:the )?graph$/i, {:query, :graph, %{}}},
    {~r/^squash (?:the )?last (\d+) commits?$/i,
      fn [n] -> {:git_op, :squash, %{count: String.to_integer(n)}} end},
    {~r/^merge (.+) into (.+)$/i,
      fn [source, target] -> {:git_op, :merge, %{source: source, target: target}} end},
    {~r/^create branch (.+)$/i, fn [name] -> {:git_op, :create_branch, %{name: name}} end},
    {~r/^delete branch (.+)$/i, fn [name] -> {:git_op, :delete_branch, %{name: name}} end},
    {~r/^who changed (.+)$/i, fn [path] -> {:query, :blame, %{path: path}} end},
    {~r/^stash$/i, {:git_op, :stash, %{}}},
    {~r/^stash pop$/i, {:git_op, :stash_pop, %{}}},
    {~r/^undo (?:the )?last commit$/i, {:git_op, :reset, %{mode: :soft, count: 1}}},
    {~r/^run tests?$/i, {:sykli_op, :run, %{}}},
    {~r/^run ci$/i, {:sykli_op, :run, %{}}},
  ]

  def parse(text, repo_context) do
    case parse_fast(text) do
      :unknown -> parse_with_llm(text, repo_context)
      intent -> {:ok, intent}
    end
  end

  def parse_fast(text) do
    text = String.trim(text)

    Enum.find_value(@fast_patterns, :unknown, fn
      {regex, intent} when is_tuple(intent) ->
        if Regex.match?(regex, text), do: intent

      {regex, fun} when is_function(fun) ->
        case Regex.run(regex, text, capture: :all_but_first) do
          nil -> nil
          captures -> fun.(captures)
        end
    end)
  end
end
```

This means: if you have no internet and no Ollama, you can still type "commit", "push", "show diff", "squash last 3 commits", and Valkka understands you. The LLM is only needed for ambiguous or novel phrasing.

---

## 4. Plugin System

### Design

A plugin is an Elixir module that implements the `Valkka.Plugin` behaviour. Plugins hook into lifecycle events, register custom commands (including natural language patterns), and can contribute UI components.

### Plugin Behaviour

```elixir
defmodule Valkka.Plugin do
  @moduledoc "Behaviour for Valkka plugins."

  @type hook_result :: :ok | {:halt, reason :: term()}

  @callback name() :: String.t()
  @callback version() :: String.t()
  @callback description() :: String.t()

  # Lifecycle hooks -- return :ok to continue, {:halt, reason} to block
  @callback on_commit(repo_id :: String.t(), commit :: map()) :: hook_result()
  @callback on_merge(repo_id :: String.t(), source :: String.t(), target :: String.t(), result :: map()) :: hook_result()
  @callback on_push(repo_id :: String.t(), remote :: String.t(), branch :: String.t()) :: hook_result()
  @callback on_pull(repo_id :: String.t(), remote :: String.t(), branch :: String.t(), result :: map()) :: hook_result()
  @callback on_conflict(repo_id :: String.t(), files :: [String.t()]) :: hook_result()
  @callback on_review(repo_id :: String.t(), review :: map()) :: hook_result()

  # Custom commands this plugin provides
  @callback commands() :: [command_spec()]
  @callback handle_command(command :: atom(), args :: map(), context :: map()) :: {:ok, response :: String.t()} | {:error, reason :: term()}

  # Optional UI contribution
  @callback panel_component() :: module() | nil

  # All callbacks are optional -- provide defaults
  @optional_callbacks [
    on_commit: 2, on_merge: 3, on_push: 3, on_pull: 4,
    on_conflict: 2, on_review: 2,
    commands: 0, handle_command: 3, panel_component: 0
  ]

  @type command_spec :: %{
    name: atom(),
    description: String.t(),
    patterns: [Regex.t()],    # natural language patterns that trigger this command
    args: [arg_spec()]
  }

  @type arg_spec :: %{
    name: atom(),
    type: :string | :integer | :boolean,
    required: boolean()
  }
end
```

### Example Plugin: Conventional Commits Enforcer

```elixir
defmodule Valkka.Plugins.ConventionalCommits do
  @behaviour Valkka.Plugin

  @impl true
  def name, do: "conventional-commits"

  @impl true
  def version, do: "0.1.0"

  @impl true
  def description, do: "Enforces conventional commit message format"

  @impl true
  def on_commit(_repo_id, %{message: message}) do
    if Regex.match?(~r/^(feat|fix|docs|style|refactor|test|chore)(\(.+\))?: .+/, message) do
      :ok
    else
      {:halt, "Commit message must follow conventional commits format: type(scope): description"}
    end
  end

  @impl true
  def commands do
    [
      %{
        name: :fix_commit_message,
        description: "Reformat a commit message to conventional commits format",
        patterns: [~r/^fix (?:the )?commit message$/i],
        args: []
      }
    ]
  end

  @impl true
  def handle_command(:fix_commit_message, _args, %{repo_id: repo_id}) do
    # Get last commit message, reformat it
    {:ok, "Reformatted commit message to conventional format"}
  end
end
```

### Plugin Discovery and Loading

```elixir
defmodule Valkka.Plugin.Manager do
  @moduledoc "Discovers, loads, and manages plugins."

  use GenServer

  @plugin_dirs [
    "~/.valkka/plugins",     # user plugins
    "plugins"               # project-local plugins
  ]

  def init(_opts) do
    plugins = discover_plugins()
    {:ok, %{plugins: plugins}}
  end

  defp discover_plugins do
    # 1. Load from plugin directories (compiled .beam files or .ex scripts)
    dir_plugins = @plugin_dirs
    |> Enum.flat_map(&scan_plugin_dir/1)

    # 2. Load from Mix dependencies (modules implementing Valkka.Plugin)
    dep_plugins = :application.loaded_applications()
    |> Enum.flat_map(&find_plugin_modules/1)

    dir_plugins ++ dep_plugins
  end

  def run_hook(hook, args) do
    GenServer.call(__MODULE__, {:run_hook, hook, args})
  end

  def handle_call({:run_hook, hook, args}, _from, state) do
    result = state.plugins
    |> Enum.filter(&function_exported?(&1, hook, length(args)))
    |> Enum.reduce_while(:ok, fn plugin, :ok ->
      case apply(plugin, hook, args) do
        :ok -> {:cont, :ok}
        {:halt, reason} -> {:halt, {:halt, plugin.name(), reason}}
      end
    end)

    {:reply, result, state}
  end

  def match_command(text) do
    GenServer.call(__MODULE__, {:match_command, text})
  end

  def handle_call({:match_command, text}, _from, state) do
    result = state.plugins
    |> Enum.flat_map(fn plugin ->
      if function_exported?(plugin, :commands, 0) do
        plugin.commands()
        |> Enum.filter(fn cmd ->
          Enum.any?(cmd.patterns, &Regex.match?(&1, text))
        end)
        |> Enum.map(&{plugin, &1})
      else
        []
      end
    end)
    |> List.first()

    {:reply, result, state}
  end
end
```

### Integration with Intent Parser

Plugins register natural language patterns. The intent parser checks plugins after the built-in fast path but before falling through to the LLM:

```
User input
  -> Built-in regex patterns (fast path)
  -> Plugin command patterns (plugin path)
  -> LLM classification (slow path)
```

### Plugin Configuration

```elixir
# ~/.valkka/config.exs
config :valkka, :plugins,
  enabled: [
    Valkka.Plugins.ConventionalCommits,
    Valkka.Plugins.JiraLinker,
    Valkka.Plugins.SlackNotifier
  ],
  config: %{
    jira_linker: %{base_url: "https://mycompany.atlassian.net"},
    slack_notifier: %{webhook_url: "https://hooks.slack.com/..."}
  }
```

---

## 5. UX Architecture

### Panel System

The application uses a three-panel layout with collapsible side panels.

```
+------------------+----------------------------+------------------+
|                  |                            |                  |
|  LEFT PANEL      |  CENTER PANEL              |  RIGHT PANEL     |
|  (240px, resize) |  (flex)                    |  (320px, resize) |
|                  |                            |                  |
|  Workspace       |  View content:             |  Context:        |
|  - Repo list     |  - Dashboard               |  - AI chat       |
|  - Branch tree   |  - Graph view              |  - Commit detail |
|  - Quick status  |  - Diff view               |  - File info     |
|                  |  - Review view             |  - Kerto context |
|                  |  - Chat (full-width mode)  |  - CI status     |
|                  |                            |                  |
+------------------+----------------------------+------------------+
|  STATUS BAR                                                      |
|  repo: valkka  branch: main  clean  AI: Anthropic  CI: passed    |
+------------------------------------------------------------------+
```

Panels collapse with keyboard shortcuts:
- `Cmd+1` toggle left panel
- `Cmd+2` focus center panel
- `Cmd+3` toggle right panel

### View Modes

| View | Center Shows | Right Shows | When |
|---|---|---|---|
| Dashboard | All repo cards with status | AI chat | Default on launch |
| Repo | Selected repo detail (branch list, recent commits) | AI chat + Kerto context | Click repo or `focus <repo>` |
| Graph | Full commit graph (WebGL) | Commit detail on hover/click | `show graph` or `Cmd+G` |
| Diff | Diff viewer (syntax highlighted) | File-level AI analysis | `show diff` or click a diff |
| Review | PR/branch review with AI annotations | Review actions (approve/request changes) | `review PR #42` |
| Chat | Full-width chat interface | Hidden (chat IS the center) | `Cmd+/` or "chat mode" |

### Command Palette (Cmd+K)

The primary quick-action interface. Appears as a centered modal overlay.

```
+--------------------------------------------------+
|  > search commands, repos, branches...           |
+--------------------------------------------------+
|  Repos                                           |
|    valkka          main     clean                 |
|    false-protocol feat/v2  3 dirty               |
|                                                  |
|  Actions                                         |
|    Commit all changes          Cmd+Enter         |
|    Show graph                  Cmd+G             |
|    Switch branch...            Cmd+B             |
|    Push                        Cmd+Shift+P       |
|    Pull                        Cmd+Shift+L       |
|                                                  |
|  Recent                                          |
|    squash last 3 commits                         |
|    review PR #42                                 |
+--------------------------------------------------+
```

The palette is fuzzy-searchable. Typing filters results in real-time. It shows:
1. Repos matching the search
2. Actions (built-in + plugin commands) matching the search
3. Recent commands matching the search
4. Branches matching the search (if a repo is focused)

Implementation: Pure LiveView. The palette is a `live_component` that receives keyboard events via `phx-window-keydown`. No JS hook needed -- LiveView's latency (< 50ms over localhost) is fast enough for fuzzy search.

### Keyboard Navigation

Two modes: **Normal** (default) and **Vim** (opt-in via config).

#### Normal Mode (Always Active)

| Key | Action |
|---|---|
| `Cmd+K` | Command palette |
| `Cmd+Enter` | Quick commit |
| `Cmd+G` | Show graph |
| `Cmd+B` | Switch branch |
| `Cmd+/` | Toggle chat / center view |
| `Cmd+1` | Toggle left panel |
| `Cmd+3` | Toggle right panel |
| `Cmd+Shift+P` | Push |
| `Cmd+Shift+L` | Pull |
| `Tab` | Cycle focus: left -> center -> right |
| `Escape` | Close palette / cancel / back |
| `Cmd+,` | Settings |

#### Vim Mode (Opt-in)

When the chat input is not focused:

| Key | Action |
|---|---|
| `j/k` | Navigate up/down in lists (repos, commits, files) |
| `h/l` | Collapse/expand panels, navigate tree structures |
| `Enter` | Open/select focused item |
| `gg` | Jump to top of list |
| `G` | Jump to bottom of list |
| `/` | Focus search / command palette |
| `i` | Focus chat input (enter "insert mode") |
| `Escape` | Unfocus chat input (return to "normal mode") |
| `d` | Show diff for selected commit |
| `g` | Show graph |
| `s` | Show status |

Vim mode is tracked as a LiveView assign (`:vim_mode`). Key events are handled in `handle_event("keydown", ...)`. The chat input gets focus via JS commands (`JS.focus`).

### Context Switching

Users move between views via:

1. **Command palette** -- type what you want, go there
2. **Chat commands** -- "show graph for kerto", "review PR #42"
3. **Keyboard shortcuts** -- Cmd+G for graph, Cmd+/ for chat
4. **Click navigation** -- click repo card, click commit in graph
5. **Breadcrumbs** -- status bar shows current context, click to go back

Context is preserved when switching. If you are viewing a diff and switch to the graph, switching back to diff returns to the same diff. This is managed by LiveView assigns -- each view's state is stored in the socket, not thrown away.

### Notification System

What deserves attention (ranked by urgency):

| Event | Notification Type | Behavior |
|---|---|---|
| CI failed | Toast (red) + status bar | Persists until dismissed or CI passes |
| Merge conflict detected | Toast (yellow) + status bar | Persists until resolved |
| Push rejected | Toast (red) | Auto-dismiss after 10s |
| AI response complete | Subtle indicator in chat | No toast -- it is already visible in the chat |
| File changes detected | Status bar update only | No toast -- too frequent |
| Repo opened/closed | Status bar update only | No toast |
| Plugin hook blocked an operation | Toast (yellow) | Auto-dismiss after 10s |

Toasts appear in the top-right corner, stack vertically, and auto-dismiss with configurable timeouts. They are LiveView components managed by a `NotificationLive` component in the layout.

In Tauri mode, critical notifications (CI failed, merge conflict) also trigger native OS notifications.

---

## 6. Supervision Tree

### Overview

```
Valkka.Application (Application)
|
+-- Valkka.PubSub (Phoenix.PubSub)
|
+-- Valkka.Plugin.Manager (GenServer)
|     Loads plugins, dispatches hooks
|
+-- Valkka.Repo.Supervisor (DynamicSupervisor)
|   |
|   +-- Valkka.Repo.Worker (gen_statem, per repo)  <-- NEW: state machine
|   |     States: :initializing -> :idle <-> :operating -> :error
|   |     Owns: ResourceArc handle, ETS cache table
|   |     Publishes: state changes via PubSub
|   |
|   +-- Valkka.Repo.Worker (repo 2)
|   +-- ...
|
+-- Valkka.NIF.TaskSupervisor (Task.Supervisor)  <-- NEW: async NIF calls
|     All NIF calls run as supervised tasks
|     Prevents NIF calls from blocking gen_statem
|
+-- Valkka.AI.Supervisor (Supervisor, one_for_one)
|   |
|   +-- Valkka.AI.StreamManager (GenServer)
|   |     Manages concurrent AI requests
|   |     Rate limiting, backpressure
|   |
|   +-- Valkka.AI.CircuitBreaker (GenServer)  <-- NEW
|   |     Trips after 3 consecutive failures
|   |     Half-open test after 30 seconds
|   |     Auto-resets on success
|   |
|   +-- Valkka.AI.ContextBuilder (GenServer)
|         Builds prompts from repo state + Kerto context
|
+-- Valkka.Watcher.Supervisor (DynamicSupervisor)
|   |
|   +-- Valkka.Watcher.Handler (GenServer, per repo)
|   |     FileSystem subscriber
|   |     Debounces rapid changes (100ms window)  <-- NEW
|   |     Publishes coalesced events to repo worker
|   |
|   +-- ...
|
+-- Valkka.Cache.Manager (GenServer)  <-- NEW
|     Owns ETS tables for shared caches
|     graph_cache: {repo_id, opts} -> %GraphLayout{}
|     commit_cache: {repo_id, oid} -> %Commit{}
|     TTL-based eviction
|
+-- Valkka.Workspace.Registry (Registry)
|     Maps workspace IDs to repo workers
|
+-- ValkkaWeb.Endpoint (Phoenix)
|     LiveView connections
|
+-- Valkka.Kerto.Bridge (GenServer)  <-- integration layer
|     Subscribes to PubSub repo events
|     Emits Kerto occurrences
|
+-- Valkka.Sykli.Monitor (GenServer)  <-- integration layer
      Watches .sykli/occurrence.json per repo
      Publishes CI status to PubSub
```

### Repo.Worker as gen_statem

The v1 Repo.Worker was a plain GenServer. This is insufficient because a repository has distinct states with different valid operations. A gen_statem makes illegal states unrepresentable.

```elixir
defmodule Valkka.Repo.Worker do
  @behaviour :gen_statem

  # --- States ---

  # :initializing - opening the repo, loading initial status
  # :idle         - ready for operations, watching for changes
  # :operating    - executing a git operation (one at a time)
  # :error        - repo is broken, retrying or waiting for manual intervention

  defstruct [
    :repo_id,
    :path,
    :handle,        # ResourceArc | nil
    :status,        # %Status{} | nil
    :error,         # term() | nil
    :error_count,   # non_neg_integer()
    :cache_table    # ETS table reference
  ]

  def callback_mode, do: [:state_functions, :state_enter]

  def start_link(opts) do
    repo_id = Keyword.fetch!(opts, :repo_id)
    :gen_statem.start_link({:via, Registry, {Valkka.Workspace.Registry, repo_id}}, __MODULE__, opts, [])
  end

  def init(opts) do
    path = Keyword.fetch!(opts, :path)
    repo_id = Keyword.fetch!(opts, :repo_id)
    cache_table = :ets.new(:"valkka_repo_#{repo_id}", [:set, :public, read_concurrency: true])

    data = %__MODULE__{
      repo_id: repo_id,
      path: path,
      error_count: 0,
      cache_table: cache_table
    }

    {:ok, :initializing, data}
  end

  # --- :initializing ---

  def initializing(:enter, _old_state, data) do
    # Open repo async via Task.Supervisor
    Task.Supervisor.async_nolink(Valkka.NIF.TaskSupervisor, fn ->
      Valkka.Git.Native.repo_open(data.path)
    end)
    |> then(fn task -> {:keep_state, %{data | handle: {:pending, task.ref}}} end)
  end

  def initializing(:info, {ref, {:ok, handle}}, %{handle: {:pending, ref}} = data) do
    Process.demonitor(ref, [:flush])
    # Get initial status
    case Valkka.Git.Native.status(handle) do
      {:ok, status} ->
        Phoenix.PubSub.subscribe(Valkka.PubSub, "watcher:#{data.repo_id}")
        broadcast(data.repo_id, {:repo_opened, status})
        {:next_state, :idle, %{data | handle: handle, status: status, error_count: 0}}

      {:error, reason} ->
        {:next_state, :error, %{data | handle: handle, error: reason}}
    end
  end

  def initializing(:info, {:DOWN, ref, :process, _pid, reason}, %{handle: {:pending, ref}} = data) do
    {:next_state, :error, %{data | handle: nil, error: reason, error_count: data.error_count + 1}}
  end

  # --- :idle ---

  def idle(:enter, _old_state, _data), do: :keep_state_and_data

  def idle({:call, from}, {:execute, operation}, data) do
    task = Task.Supervisor.async_nolink(Valkka.NIF.TaskSupervisor, fn ->
      execute_operation(data.handle, data.path, operation)
    end)

    {:next_state, :operating, %{data | handle: data.handle},
     [{:reply, from, :accepted}, {:state_timeout, 30_000, :operation_timeout}]}
  end

  def idle(:info, {:file_changed, _events}, data) do
    # Refresh status (async)
    Task.Supervisor.async_nolink(Valkka.NIF.TaskSupervisor, fn ->
      Valkka.Git.Native.status(data.handle)
    end)
    :keep_state_and_data
  end

  def idle(:info, {ref, {:ok, new_status}}, data) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    if new_status != data.status do
      broadcast(data.repo_id, {:status_changed, new_status})
    end
    {:keep_state, %{data | status: new_status}}
  end

  # --- :operating ---

  def operating(:enter, _old_state, _data), do: :keep_state_and_data

  def operating(:info, {ref, result}, data) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    broadcast(data.repo_id, {:operation_completed, result})
    # Refresh status after operation
    case Valkka.Git.Native.status(data.handle) do
      {:ok, new_status} ->
        broadcast(data.repo_id, {:status_changed, new_status})
        {:next_state, :idle, %{data | status: new_status}}
      {:error, _} ->
        {:next_state, :idle, data}
    end
  end

  def operating(:state_timeout, :operation_timeout, data) do
    broadcast(data.repo_id, {:operation_timeout})
    {:next_state, :idle, data}
  end

  # --- :error ---

  def error(:enter, _old_state, %{error_count: count} = data) when count < 3 do
    # Schedule retry with exponential backoff
    delay = :timer.seconds(count * 2)
    {:keep_state_and_data, [{:state_timeout, delay, :retry}]}
  end

  def error(:enter, _old_state, data) do
    # Give up after 3 retries
    broadcast(data.repo_id, {:repo_error, data.error})
    :keep_state_and_data
  end

  def error(:state_timeout, :retry, data) do
    {:next_state, :initializing, data}
  end

  # --- Helpers ---

  defp execute_operation(handle, path, {:nif, function, args}) do
    apply(Valkka.Git.Native, function, [handle | args])
  end

  defp execute_operation(_handle, path, {:cli, function, args}) do
    apply(Valkka.Git.CLI, function, [path | args])
  end

  defp broadcast(repo_id, event) do
    Phoenix.PubSub.broadcast(Valkka.PubSub, "repo:#{repo_id}", event)
  end
end
```

### Task.Supervisor for NIF Calls

Every NIF call runs inside a supervised task. This prevents a slow or stuck NIF from blocking the gen_statem mailbox. If a NIF task crashes, the gen_statem receives a `:DOWN` message and handles it as an error -- it does not crash itself.

```elixir
# In application.ex children:
{Task.Supervisor, name: Valkka.NIF.TaskSupervisor}
```

### Circuit Breaker for AI Provider

```elixir
defmodule Valkka.AI.CircuitBreaker do
  use GenServer

  @max_failures 3
  @reset_timeout :timer.seconds(30)

  defstruct [
    state: :closed,       # :closed (normal), :open (tripped), :half_open (testing)
    failure_count: 0,
    last_failure: nil
  ]

  def request(fun) do
    GenServer.call(__MODULE__, {:request, fun})
  end

  def handle_call({:request, fun}, _from, %{state: :open} = state) do
    if time_since_last_failure(state) > @reset_timeout do
      # Try half-open
      try_request(fun, %{state | state: :half_open})
    else
      {:reply, {:error, :circuit_open}, state}
    end
  end

  def handle_call({:request, fun}, _from, state) do
    try_request(fun, state)
  end

  defp try_request(fun, state) do
    case fun.() do
      {:ok, result} ->
        {:reply, {:ok, result}, %{state | state: :closed, failure_count: 0}}

      {:error, reason} ->
        new_count = state.failure_count + 1
        new_state = if new_count >= @max_failures do
          %{state | state: :open, failure_count: new_count, last_failure: System.monotonic_time(:millisecond)}
        else
          %{state | failure_count: new_count, last_failure: System.monotonic_time(:millisecond)}
        end
        {:reply, {:error, reason}, new_state}
    end
  end
end
```

### ETS Cache for Graph Layouts and Commit History

```elixir
defmodule Valkka.Cache.Manager do
  use GenServer

  @graph_ttl :timer.minutes(5)
  @commit_ttl :timer.minutes(30)

  def init(_opts) do
    graph_table = :ets.new(:valkka_graph_cache, [:set, :public, read_concurrency: true])
    commit_table = :ets.new(:valkka_commit_cache, [:set, :public, read_concurrency: true])

    # Schedule periodic cleanup
    Process.send_after(self(), :cleanup, :timer.minutes(1))

    {:ok, %{graph: graph_table, commit: commit_table}}
  end

  def get_graph(repo_id, opts) do
    key = {repo_id, opts}
    case :ets.lookup(:valkka_graph_cache, key) do
      [{^key, layout, inserted_at}] ->
        if System.monotonic_time(:millisecond) - inserted_at < @graph_ttl do
          {:ok, layout}
        else
          :ets.delete(:valkka_graph_cache, key)
          :miss
        end
      [] -> :miss
    end
  end

  def put_graph(repo_id, opts, layout) do
    :ets.insert(:valkka_graph_cache, {{repo_id, opts}, layout, System.monotonic_time(:millisecond)})
  end

  def invalidate_repo(repo_id) do
    # Delete all cache entries for this repo
    :ets.match_delete(:valkka_graph_cache, {{repo_id, :_}, :_, :_})
    :ets.match_delete(:valkka_commit_cache, {{repo_id, :_}, :_, :_})
  end

  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:millisecond)
    cleanup_table(:valkka_graph_cache, now, @graph_ttl)
    cleanup_table(:valkka_commit_cache, now, @commit_ttl)
    Process.send_after(self(), :cleanup, :timer.minutes(1))
    {:noreply, state}
  end

  defp cleanup_table(table, now, ttl) do
    :ets.foldl(fn {key, _value, inserted_at}, acc ->
      if now - inserted_at > ttl, do: :ets.delete(table, key)
      acc
    end, nil, table)
  end
end
```

### Rate Limiter for File Watcher Events

```elixir
defmodule Valkka.Watcher.Handler do
  use GenServer

  @debounce_ms 100

  defstruct [:repo_id, :path, :timer_ref, :pending_events]

  def init(opts) do
    repo_id = Keyword.fetch!(opts, :repo_id)
    path = Keyword.fetch!(opts, :path)

    {:ok, watcher_pid} = FileSystem.start_link(dirs: [path])
    FileSystem.subscribe(watcher_pid)

    {:ok, %__MODULE__{repo_id: repo_id, path: path, timer_ref: nil, pending_events: []}}
  end

  def handle_info({:file_event, _pid, {path, events}}, state) do
    # Accumulate events
    new_events = [{path, events} | state.pending_events]

    # Cancel existing timer
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

    # Set new debounce timer
    timer_ref = Process.send_after(self(), :flush_events, @debounce_ms)

    {:noreply, %{state | pending_events: new_events, timer_ref: timer_ref}}
  end

  def handle_info(:flush_events, state) do
    # Coalesce events: deduplicate paths, keep latest event type per path
    coalesced = state.pending_events
    |> Enum.reverse()
    |> Enum.uniq_by(fn {path, _events} -> path end)

    # Ignore .git directory changes (git internal bookkeeping)
    filtered = Enum.reject(coalesced, fn {path, _} ->
      String.contains?(path, "/.git/")
    end)

    if filtered != [] do
      Phoenix.PubSub.broadcast(
        Valkka.PubSub,
        "watcher:#{state.repo_id}",
        {:file_changed, filtered}
      )

      # Invalidate caches for this repo
      Valkka.Cache.Manager.invalidate_repo(state.repo_id)
    end

    {:noreply, %{state | pending_events: [], timer_ref: nil}}
  end
end
```

---

## 7. Data Flow Examples (v2)

### "commit" (No Message Provided)

```
1. User types "commit" in chat
2. LiveView sends event to ChatLive
3. IntentParser.parse_fast("commit") -> {:ai_op, :generate_commit_msg, %{}}
4. ChatLive calls Repo.Worker via gen_statem:
   a. Worker is in :idle state -> transitions to :operating
   b. Spawns Task via NIF.TaskSupervisor:
      - diff(handle, %{from: "HEAD", to: "STAGED"}) -> staged diff
      - semantic_diff(handle, %{from: "HEAD", to: "STAGED"}) -> structural changes
5. Worker broadcasts {:diff_ready, diff, semantic_diff} via PubSub
6. AI.ContextBuilder assembles prompt from semantic_diff + Kerto context
7. AI.CircuitBreaker.request(fn -> Provider.stream(prompt, opts) end)
   - If circuit open: fall back to simple message from semantic_diff summary
   - If circuit closed: stream to PubSub "repo:{id}:ai"
8. LiveView renders streaming tokens in chat
9. Stream completes -> LiveView shows: suggested message + [Commit] [Edit] buttons
10. User clicks [Commit]
11. Worker executes commit(handle, message, [], %{}) via Task.Supervisor
12. Worker transitions :operating -> :idle, broadcasts {:commit_created, oid}
13. Plugin.Manager.run_hook(:on_commit, [repo_id, commit])
14. Valkka.Kerto.Bridge receives PubSub event, emits Kerto occurrence
15. LiveView updates: chat shows "Committed abc123", graph re-renders
```

### "show graph" While Offline

```
1. User types "show graph"
2. IntentParser.parse_fast("show graph") -> {:query, :graph, %{}}
3. ChatLive tells center panel to switch to graph view
4. GraphLive checks ETS cache: Cache.Manager.get_graph(repo_id, default_opts)
   - Cache hit: send to JS hook immediately
   - Cache miss: call Worker -> NIF -> compute layout
5. NIF.TaskSupervisor runs graph(handle, %{limit: 500})
6. Result cached in ETS, pushed to GraphHook via pushEvent
7. GraphHook renders in WebGL
8. No network needed. No AI needed. Everything is local.
```

---

## 8. Project Structure (v2)

```
valkka/
  lib/
    valkka/
      application.ex              # Supervision tree (v2)
      repo/
        worker.ex                 # gen_statem (v2)
        supervisor.ex             # DynamicSupervisor
      git/
        native.ex                 # 8 NIF functions (v2)
        cli.ex                    # System.cmd git operations (NEW)
        types.ex                  # Commit, Branch, Diff, Status structs
      ai/
        provider.ex               # Provider behaviour (v2)
        providers/
          anthropic.ex
          openai.ex
          ollama.ex               # NEW: local LLM
          null.ex                 # NEW: offline fallback
        provider_selector.ex      # NEW: auto-select best provider
        circuit_breaker.ex        # NEW
        intent_parser.ex          # regex fast path + LLM fallback
        stream_manager.ex
        context_builder.ex
      plugin/                     # NEW: plugin system
        plugin.ex                 # Behaviour definition
        manager.ex                # Discovery, loading, hook dispatch
      cache/
        manager.ex                # NEW: ETS cache with TTL
      workspace/
        registry.ex
        config.ex
      watcher/
        supervisor.ex
        handler.ex                # Debounced file events (v2)
      kerto/
        bridge.ex                 # PubSub -> Kerto occurrences
        context_provider.ex       # Kerto -> AI context enrichment
        branch_health.ex          # EWMA branch freshness
      sykli/
        monitor.ex                # Watch .sykli/occurrence.json
        runner.ex                 # Trigger sykli runs
        context_provider.ex       # CI context for AI

    valkka_web/
      router.ex
      live/
        dashboard_live.ex         # Workspace overview
        repo_live.ex              # Single repo view
        chat_live.ex              # Chat interface
        graph_live.ex             # Graph view (hosts WebGL hook)
        diff_live.ex              # Diff view (hosts diff hook)
        review_live.ex            # PR/branch review
        command_palette_live.ex   # NEW: Cmd+K palette
        components/
          notification.ex         # NEW: toast notification system
          status_bar.ex
          panel_layout.ex         # NEW: three-panel layout component
          repo_card.ex
          branch_list.ex
          ai_chat.ex

  assets/
    js/
      app.js                      # Hook registration
      hooks/
        graph_hook.js             # WebGL commit graph
        diff_hook.js              # Syntax-highlighted diff (CodeMirror 6)
        minimap_hook.js           # Branch topology minimap
        index.js                  # Hook registry
    css/
      app.css

  native/valkka_git/               # Rust NIF crate
    Cargo.toml
    src/
      lib.rs                      # 8 NIF registrations (v2, down from 25+)
      error.rs
      handle.rs                   # RepoHandle (ResourceArc)
      types.rs
      repo.rs                     # repo_open, repo_close
      status.rs                   # combined status (NEW)
      log.rs                      # log with filtering
      diff.rs                     # unified diff function
      commit.rs                   # stage + commit atomic
      graph.rs                    # layout computation
      semantic/
        mod.rs                    # semantic_diff entry point
        parser.rs                 # tree-sitter
        languages.rs              # per-language heuristics

  tauri/                          # Native app shell
    Cargo.toml
    tauri.conf.json
    src/
      main.rs
      sidecar.rs
      tray.rs
      shortcuts.rs
      commands.rs

  config/
    config.exs
    dev.exs
    prod.exs
    test.exs

  test/
    valkka/
      repo/
      git/
      ai/
      plugin/
      cache/
    valkka_web/
      live/

  mix.exs
```

---

## 9. Performance Targets (v2)

| Metric | Target | How |
|---|---|---|
| App startup | < 2s | Phoenix fast boot, lazy-load repos |
| Open a repo | < 200ms | NIF repo_open, ResourceArc cached |
| Status refresh | < 20ms | NIF status, single call |
| Render graph (1,000 commits) | < 100ms | NIF layout + WebGL render |
| Render graph (50,000 commits) | < 500ms | Virtualized viewport, NIF subset |
| Diff two commits | < 50ms | NIF diff |
| Semantic diff | < 300ms | NIF tree-sitter |
| AI response start (cloud) | < 1s | Streaming, first token |
| AI response start (Ollama) | < 3s | Local model load + inference |
| File change to UI update | < 200ms | FSEvents -> debounce 100ms -> NIF -> PubSub -> LiveView |
| Command palette open | < 50ms | LiveView component mount |
| Intent parse (regex) | < 1ms | No I/O, pattern matching only |
| Cache hit (ETS) | < 1ms | :ets.lookup, read_concurrency |
| Idle RAM (5 repos) | < 150MB | BEAM + NIF handles, no Chromium |
| Idle RAM (Tauri) | < 200MB | BEAM + NIF + system WebView |

---

## 10. Kerto Integration (Unchanged from v1)

Kerto embeds as a library dependency. Valkka.Kerto.Bridge subscribes to PubSub repo events and emits Kerto occurrences. Kerto context enriches AI prompts and diff annotations. See `docs/kerto-integration.md` for full details. No architectural changes needed -- the v1 design was already correct.

---

## 11. Sykli Integration (Unchanged from v1)

Valkka.Sykli.Monitor watches `.sykli/occurrence.json` for changes and publishes CI status via PubSub. CI context feeds into AI prompts. See `docs/sykli-integration.md` for full details. No architectural changes needed.

---

## 12. Key Architectural Decisions (v2)

### ADR-001v2: Hybrid NIF + CLI (replaces ADR-001 NIF-only)

**Decision:** Use Rust NIFs for the 8 performance-critical read operations and commit. Use git CLI for everything else.

**Why:** The v1 NIF surface of 25+ functions created excessive build complexity, crash surface area, and maintenance burden. Most git operations (merge, rebase, push, pull) are infrequent user-initiated actions where 50ms vs 200ms latency is imperceptible. The git CLI handles authentication, hooks, and edge cases that git2-rs requires manual implementation for.

**Trade-off:** Two code paths for git operations (NIF and CLI). Mitigated by `Valkka.Git.Commands` module that presents a unified interface -- callers never know which path is used.

### ADR-002v2: LiveView + JS Hooks (replaces consideration of SPA)

**Decision:** LiveView for state management and simple rendering. JS hooks (WebGL, CodeMirror) for complex visual components.

**Why:** Real-time state is the core product. LiveView gives it for free. A separate SPA would require building a custom WebSocket protocol, state reconciliation, and reconnection logic. The only components that need JS are the graph renderer and diff viewer -- those are hooks, not an application architecture.

### ADR-003v2: gen_statem for Repo.Worker (replaces GenServer)

**Decision:** Model repository lifecycle as a state machine with explicit states: initializing, idle, operating, error.

**Why:** A GenServer with boolean flags (`is_loading`, `has_error`, `is_operating`) is a state machine in disguise -- but without the compile-time guarantees. gen_statem makes transitions explicit, prevents invalid states (you cannot operate on a repo that is in error state), and gives built-in state timeout support for retry backoff.

### ADR-004v2: Task.Supervisor for NIF Calls

**Decision:** All NIF calls run inside Task.Supervisor, not inside the gen_statem process.

**Why:** A NIF call that takes 500ms (large semantic diff) would block the gen_statem from processing file change events or status queries. By running NIFs in supervised tasks, the gen_statem remains responsive. If a NIF task crashes, the gen_statem receives a `:DOWN` message and handles it gracefully.

### ADR-005v2: Circuit Breaker for AI

**Decision:** Wrap AI provider calls in a circuit breaker that trips after 3 consecutive failures and auto-resets after 30 seconds.

**Why:** AI APIs fail. They timeout, rate-limit, and go down. Without a circuit breaker, a down API means every user action that triggers AI (commit messages, reviews, intent parsing) waits for a timeout. With the breaker, the first 3 failures trip the circuit, and subsequent requests immediately fall back to offline behavior (regex intent parsing, no AI suggestions) until the API recovers.

### ADR-006: Plugin System via Behaviours

**Decision:** Plugins are Elixir modules implementing `Valkka.Plugin` behaviour. Discovery via filesystem scanning and Mix dependencies.

**Why:** Elixir behaviours provide compile-time callback checking, clear contracts, and zero runtime overhead. The alternative -- a dynamic plugin protocol over JSON/HTTP -- adds serialization cost and loses type safety. Since Valkka is an Elixir application, plugins written in Elixir get full access to the runtime (PubSub, ETS, NIF calls) without an interop layer.

### ADR-007: Offline by Default

**Decision:** All core functionality works without network. AI degrades to regex intent parsing. Cloud features show "offline" state.

**Why:** The target user works with local git repos. Network should enhance, not gate, the experience. The Ollama adapter means users with a local LLM get full AI functionality without any cloud dependency.

---

## 13. What Makes v2 Win

1. **The NIF boundary is minimal and stable.** 8 functions that rarely change. Everything else shells out to git CLI. Build complexity is bounded. Crash surface is small.

2. **Offline by default means it always works.** Git is local. Valkka is local. AI is optional. This is a tool you can rely on in an airplane, a coffee shop with bad wifi, or a classified environment with no internet.

3. **gen_statem + Task.Supervisor means the UI never freezes.** A 500ms semantic diff does not block status updates. A stuck AI request does not block commits. Everything is async, everything is supervised, everything recovers.

4. **The plugin system turns Valkka into a platform.** Conventional commits enforcement, Jira linking, Slack notifications, custom deployment workflows -- all implementable without forking Valkka.

5. **The UX is keyboard-driven.** Command palette, vim bindings, panel shortcuts. This is built for developers who think in commands, not clicks. The mouse works, but it is never required.

6. **LiveView + hooks is the right split.** Server-rendered state management (where correctness matters) plus client-side rendering (where performance matters). No framework duplication, no state synchronization bugs, no build boundary between frontend and backend.

7. **The semantic diff is still the technical moat.** No other git client tells you "this function's signature changed and a new validation function was added." They show green and red lines. tree-sitter in Rust, structured output to the AI -- this is what makes Valkka's commit messages and reviews better than anyone else's.
