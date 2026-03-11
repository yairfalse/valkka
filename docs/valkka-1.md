# Valkka-1 — The Power Layer

> Valkka-0 is awareness. Valkka-1 is speed.

---

## What Valkka-1 Adds

Five features that transform Valkka from "nice dashboard" to "I can't work without this":

1. **Command palette** — `Cmd+K` fuzzy search across everything
2. **AI commit messages** — generate messages from staged diffs
3. **Pull support** — complete the push/pull loop
4. **Kerto integration** — optional context intelligence in the right panel
5. **PR review** — fetch, read, and comment on PRs without leaving Valkka

Each feature is independent. Ship order = build order listed above. No feature blocks another.

---

## Principles

- **Kerto is optional.** Every feature works without Kerto. Kerto enriches — it never gates. Code paths check `Valkka.Kerto.available?/0` and degrade gracefully.
- **AI is optional.** Commit messages, PR review summaries — all work manually. AI enhances but never blocks.
- **Keyboard-first.** Every new feature must be reachable from the command palette and usable without a mouse.
- **No new processes unless necessary.** Pure functions > GenServers. The existing Repo.Worker, Plugin system, and PubSub handle most coordination.

---

## Feature 1: Command Palette

### What

Overlay triggered by `Cmd+K`. Fuzzy search across repos, branches, files, git actions, and navigation. The universal entry point for everything.

### UX

```
┌──────────────────────────────────────────────┐
│ > search commands, repos, branches...        │
├──────────────────────────────────────────────┤
│                                              │
│  RECENT                                      │
│   ↩  push valkka                             │
│   ↩  switch to feat/v2 in false-protocol     │
│                                              │
│  GIT                                         │
│   ⎇  Commit...              c                │
│   ⎇  Push                   p                │
│   ⎇  Pull                                    │
│   ⎇  Stage all              a                │
│   ⎇  Create branch...       b                │
│                                              │
│  NAVIGATION                                  │
│   →  Overview                                │
│   →  Agents                                  │
│   →  Graph                   1               │
│   →  Changes                 2               │
│                                              │
│  REPOS                                       │
│   ●  valkka                  Cmd+1           │
│   ◐  false-protocol          Cmd+2           │
│                                              │
└──────────────────────────────────────────────┘
```

### Architecture

**No new process.** The palette is a pure LiveView component with client-side JS for fuzzy matching speed.

```
ValkkaWeb.PaletteComponent (LiveComponent)
├── Collects items from:
│   ├── Static command registry (git ops, navigation)
│   ├── Repo list (from DashboardLive assigns)
│   ├── Branch list per repo (lazy-loaded on repo focus)
│   └── Plugin-contributed actions (via action_provider capability)
├── Sends selected action back to DashboardLive
└── DashboardLive dispatches the action

assets/js/hooks/palette_hook.js
├── Owns the fuzzy matching (client-side, no round-trips for typing)
├── Renders filtered results
├── Handles j/k navigation, Enter to select, Escape to close
└── Pushes selected item ID to server
```

**Why client-side fuzzy matching:** Typing in a command palette must feel instant (<16ms per keystroke). Round-tripping each keystroke to the server adds 5-50ms latency that makes it feel sluggish. The server sends the full item list once on open; JS filters locally.

### Item Schema

```elixir
%{
  id: "git:commit",
  label: "Commit...",
  category: "GIT",         # for grouping
  icon: "⎇",
  shortcut: "c",            # display only — actual binding in KeyboardHook
  action: :commit,          # atom dispatched to DashboardLive
  context: :repo,           # :global | :repo — only show when a repo is focused
  searchable: "commit git"  # extra search terms
}
```

### Commands registered

| ID | Label | Action | Context |
|---|---|---|---|
| `git:commit` | Commit... | `:focus_commit` | `:repo` |
| `git:push` | Push | `:push` | `:repo` |
| `git:pull` | Pull | `:pull` | `:repo` |
| `git:stage_all` | Stage all | `:stage_all` | `:repo` |
| `git:create_branch` | Create branch... | `:toggle_branch` | `:repo` |
| `git:discard_all` | Discard all changes | `:discard_all` | `:repo` |
| `nav:overview` | Overview | `{:switch_view, "overview"}` | `:global` |
| `nav:agents` | Agents | `{:switch_view, "agents"}` | `:global` |
| `nav:graph` | Graph | `{:switch_tab, "graph"}` | `:repo` |
| `nav:changes` | Changes | `{:switch_tab, "changes"}` | `:repo` |
| `ai:commit_msg` | Generate commit message | `:ai_commit_msg` | `:repo` |
| `ai:review` | Review current changes | `:ai_review` | `:repo` |
| `repo:{path}` | (dynamic per repo) | `{:select_repo, path}` | `:global` |
| `branch:{name}` | (dynamic per branch) | `{:switch_branch, name}` | `:repo` |

Plugin actions are added dynamically from `Valkka.Plugin.Actions.all/0`.

### Keyboard binding

In `keyboard_hook.js`, add `Cmd+K` / `Ctrl+K` handler that pushes `"palette:open"` event. The palette component handles the rest client-side until a selection is made.

### Files to create/modify

| File | Change |
|---|---|
| `lib/valkka_web/live/palette_component.ex` | New LiveComponent |
| `lib/valkka/palette.ex` | Static command registry (pure module, no process) |
| `assets/js/hooks/palette_hook.js` | New JS hook: fuzzy match, keyboard nav, rendering |
| `assets/js/hooks/index.js` | Register PaletteHook |
| `assets/js/hooks/keyboard_hook.js` | Add Cmd+K binding |
| `lib/valkka_web/live/dashboard_live.ex` | Mount palette, handle dispatched actions |
| `assets/css/app.css` | Palette styles |

---

## Feature 2: AI Commit Messages

### What

When the user hits `c` to commit (or selects "Generate commit message" from palette), Valkka gets the staged diff and asks the AI provider to suggest a commit message. The user can accept, edit, or discard.

### UX Flow

```
1. User stages files, hits `c` → commit textarea focuses
2. User clicks "✦ Generate" button (or Cmd+G in textarea)
3. Textarea shows "Generating..." placeholder
4. AI response streams into textarea
5. User edits if needed, Cmd+Enter to commit
```

The generate button sits next to the commit textarea:

```
┌────────────────────────────────────────────┐
│ feat: add timeout handling to repo worker  │
│                                            │
│ Add configurable timeouts to prevent...    │
├────────────────────────────────────────────┤
│ [✦ Generate]  [Commit staged]  [Push]      │
└────────────────────────────────────────────┘
```

### Architecture

```
CommitComponent
├── "generate" event → calls Valkka.AI.CommitMessage.generate/2
│   ├── Gets staged diff via Valkka.Git.Native.repo_status + repo_diff_file
│   ├── Calls active AI provider's suggest_commit_message/1
│   └── Returns {:ok, message} | {:error, reason}
└── Sets textarea value to generated message

Valkka.AI.CommitMessage (new, pure module)
├── gather_staged_diff(handle) → builds diff text from staged files
├── generate(repo_path, opts) → calls provider, returns message
└── Truncates large diffs to stay within token limits
```

**The AI provider is already defined.** `Valkka.AI.Provider` has `suggest_commit_message/1`. We need:
1. An Anthropic provider implementation (uses `Req` to call the API)
2. A way to configure the active provider and API key
3. The `CommitMessage` module that gathers the diff and calls the provider

### Provider configuration

```elixir
# config/dev.exs
config :valkka, :ai,
  provider: Valkka.AI.Providers.Anthropic,
  api_key: {:system, "ANTHROPIC_API_KEY"},  # read from env at runtime
  model: "claude-sonnet-4-20250514"
```

When no API key is set, falls back to `Valkka.AI.Providers.Null` automatically.

### Diff truncation strategy

Large diffs blow up token counts. Strategy:
1. If total diff < 8000 chars → send full diff
2. If total diff < 32000 chars → send stat summary + first 8000 chars of hunks
3. If total diff > 32000 chars → send file list with change counts only

This is a pure function in `Valkka.AI.CommitMessage.truncate_diff/1`.

### Files to create/modify

| File | Change |
|---|---|
| `lib/valkka/ai/commit_message.ex` | New: gather diff, truncate, generate |
| `lib/valkka/ai/providers/anthropic.ex` | New: Req-based Anthropic API client |
| `lib/valkka/ai/config.ex` | New: provider selection, API key resolution |
| `lib/valkka_web/live/commit_component.ex` | Add generate button + event handler |
| `assets/js/hooks/keyboard_hook.js` | Add Cmd+G in textarea context |
| `config/dev.exs` | AI config block |
| `config/config.exs` | Default AI config (null provider) |

---

## Feature 3: Pull Support

### What

`git pull` in the worker + a Pull button/shortcut in the UI. Completes the push/pull loop.

### Architecture

This is the simplest feature. Pattern follows existing push exactly.

```elixir
# In Repo.Worker — add alongside existing push/1
def pull(path), do: operate(path, :pull)

# In execute_operation — add clause
defp execute_operation(:pull, _args, data) do
  Valkka.Git.CLI.pull(data.path)
end
```

```elixir
# In Git.CLI — add alongside existing push/1
def pull(repo_path) do
  run(repo_path, ["pull", "--ff-only"])
end
```

**Why `--ff-only`:** Safe default. If the pull would create a merge commit, it fails with a clear error. The user can then decide. No surprise merge commits.

### UI additions

- Pull button in `CommitComponent` next to Push
- `l` keyboard shortcut (mnemonic: puLl, since `p` is push)
- Command palette entry `git:pull`
- Activity entry on pull complete (like push)

### Conflict handling

`--ff-only` means no merge conflicts from pull. If it fails:
- Show error: "Pull failed: remote has diverged. Rebase or merge manually."
- Later (Valkka-2): add rebase/merge options

### Files to modify

| File | Change |
|---|---|
| `lib/valkka/repo/worker.ex` | Add `pull/1`, `execute_operation(:pull, ...)` |
| `lib/valkka/git/cli.ex` | Add `pull/1` |
| `lib/valkka_web/live/commit_component.ex` | Add Pull button |
| `lib/valkka_web/live/dashboard_live.ex` | Add `handle_event("key:pull", ...)`, pull activity entry |
| `assets/js/hooks/keyboard_hook.js` | Add `l` binding |

---

## Feature 4: Kerto Integration (Optional)

### Design Principle: Optional Dependency

Kerto is NOT a hard dep. Valkka must compile, run, and be fully functional without Kerto installed.

```elixir
# In mix.exs — optional dep
{:kerto, github: "yairfalse/kerto", optional: true}
```

All Kerto code lives behind `Code.ensure_loaded?/1` checks. The plugin system already supports this pattern — Kerto integration is a plugin.

### Architecture

```
Valkka.Plugins.KertoProvider (plugin, optional)
├── @behaviour Valkka.Plugin
├── capabilities: [:context_provider, :event_consumer]
├── context_provider:
│   ├── get_file_context(path) → queries Kerto.Engine.context(:file, path)
│   └── get_repo_context(name) → queries Kerto.Engine.context(:concept, "repo:name")
├── event_consumer:
│   ├── on_commit → emits vcs.commit occurrence to Kerto
│   ├── on_merge_conflict → emits context.learning occurrence
│   └── on_file_changed → (no-op, too noisy)
└── child_spec → starts Kerto.Engine if not already running
```

### How it plugs in

The right panel (`ContextPanel`) already calls `Valkka.Context.get_repo_context/1` and `Valkka.Context.get_file_context/1`. Those functions query all registered `context_provider` plugins. If KertoProvider is configured, it answers. If not, the panel shows activity/agents (current behavior).

**No code changes needed in existing components.** The plugin system handles dispatch.

### Context panel rendering

When Kerto is available, the context panel shows a new tab:

```
[Activity] [Agents] [Context]
                      ^^^^^^^^ new, only visible when Kerto plugin is active

CONTEXT: false-protocol

Patterns:
  ⚠ occurrence.go → parser_test.go  (w: 0.78)
  ★ Decided: v2 uses ULID  (w: 0.85)

Relationships:
  handler.go ─depends_on─→ types.go
  types.go ─changes_with─→ handler.go
```

### Configuration

```elixir
# config/dev.exs — only if Kerto is installed
config :valkka,
  plugins: [
    Valkka.Plugins.ClaudeDetector,
    Valkka.Plugins.KertoProvider   # add when Kerto is available
  ]
```

### Graceful absence

```elixir
defmodule Valkka.Plugins.KertoProvider do
  @moduledoc "Kerto integration plugin. Only loads if Kerto is available."

  # This module won't compile if Kerto isn't a dep,
  # but since it's only loaded via config, that's fine —
  # if Kerto isn't installed, don't add this to the plugins list.
  # The Plugin.Registry already handles missing modules gracefully.
end
```

The Plugin.Registry's `discover_plugins/0` already calls `Code.ensure_loaded/1` and logs a warning if a configured plugin can't be loaded. No changes needed.

### Files to create

| File | Change |
|---|---|
| `lib/valkka/plugins/kerto_provider.ex` | New plugin module |
| `lib/valkka_web/components/context_panel.ex` | Add "Context" tab (conditionally visible) |
| `mix.exs` | Add optional Kerto dep |
| `config/dev.exs` | Add KertoProvider to plugins list (commented out) |

---

## Feature 5: PR Review

### What

Fetch PRs from GitHub via `gh` CLI, display them in the focus panel with diffs and AI-generated review summaries. Comment and approve without leaving Valkka.

### Why `gh` CLI, not GitHub API directly

- Auth is already handled (user has `gh` installed and authed)
- No OAuth flow, no token management
- Same pattern as `Valkka.Git.CLI` — shell out, parse JSON
- Rate limiting handled by `gh`

### Architecture

```
Valkka.GitHub.CLI (new module)
├── list_prs(repo_path) → gh pr list --json ...
├── get_pr(repo_path, number) → gh pr view N --json ...
├── pr_diff(repo_path, number) → gh pr diff N
├── pr_comments(repo_path, number) → gh api repos/.../pulls/N/comments
├── create_comment(repo_path, number, body) → gh pr comment N --body ...
├── approve(repo_path, number) → gh pr review N --approve
└── request_changes(repo_path, number, body) → gh pr review N --request-changes --body ...

Valkka.PR (domain module, pure functions)
├── parse_pr_list(json) → [%PR{}]
├── parse_pr_detail(json) → %PR{}
└── PR struct: number, title, author, base, head, state, additions, deletions, files, comments

ValkkaWeb.PRComponent (new LiveComponent)
├── Lists PRs for focused repo
├── Shows PR detail: summary, diff, comments
├── AI review panel (optional, uses AI provider)
└── Action buttons: approve, request changes, comment
```

### PR as a focus panel view

Add `"prs"` as a new view alongside `"overview"`, `"agents"`, `"repo"`:

```
DashboardLive assigns:
  active_view: "overview" | "agents" | "repo" | "prs"  ← new
```

Or better: PRs are per-repo, so they're a tab within the repo view:

```
[Graph] [Changes] [PRs]    ← new tab
                   ^^^^
```

### PR list view

```
┌─ PRs for valkka ─────────────────────────────┐
│                                               │
│  #5  feat: rename Känni → Valkka    merged    │
│      yairfalse → main  ·  +8880 -2762         │
│                                               │
│  #4  feat: agent detection          merged    │
│      yairfalse → main  ·  +534 -120           │
│                                               │
│  (no open PRs)                                │
│                                               │
└───────────────────────────────────────────────┘
```

### PR detail view

```
┌─ PR #42: Add occurrence v2 format ────────────┐
│  by yair → main  │  open  │  +120 -30         │
│                                               │
│  ── AI REVIEW (optional) ──────────────────── │
│  Risk: LOW                                    │
│  Summary: Adds v2 occurrence format with      │
│  backwards-compatible parsing.                │
│  Suggestions:                                 │
│  1. Add migration test for v1→v2              │
│                                               │
│  ── FILES (5) ─────────────────────────────── │
│  ▶ lib/occurrence/v2.ex              +80      │
│  ▶ lib/occurrence/parser.ex          +20 -15  │
│  ▶ test/occurrence_test.exs          +30      │
│                                               │
│  [Approve] [Request changes] [Comment]        │
└───────────────────────────────────────────────┘
```

### AI PR review

Uses the same AI provider. New behaviour callback:

```elixir
# Add to Valkka.AI.Provider
@callback review_diff(diff :: String.t(), context :: map()) :: response()
```

The `context` map can include Kerto context (if available) — file risk scores, co-change relationships, known decisions. This is where Kerto makes AI review dramatically better.

```elixir
defmodule Valkka.AI.PRReview do
  def review(repo_path, pr_number) do
    diff = Valkka.GitHub.CLI.pr_diff(repo_path, pr_number)

    context =
      if Valkka.Kerto.available?() do
        files = extract_file_paths(diff)
        Enum.map(files, fn f -> {f, Valkka.Context.get_file_context(f)} end)
        |> Map.new()
      else
        %{}
      end

    provider = Valkka.AI.Config.provider()
    provider.review_diff(diff, context)
  end
end
```

### `gh` availability check

```elixir
defmodule Valkka.GitHub.CLI do
  def available? do
    case System.find_executable("gh") do
      nil -> false
      _ ->
        case System.cmd("gh", ["auth", "status"], stderr_to_stdout: true) do
          {_, 0} -> true
          _ -> false
        end
    end
  end
end
```

PR tab only shows if `gh` is available. No tab, no error, no broken state.

### Files to create/modify

| File | Change |
|---|---|
| `lib/valkka/github/cli.ex` | New: `gh` CLI wrapper |
| `lib/valkka/pr.ex` | New: PR struct and parsing |
| `lib/valkka/ai/pr_review.ex` | New: AI-powered PR review |
| `lib/valkka/ai/provider.ex` | Add `review_diff/2` callback |
| `lib/valkka/ai/providers/null.ex` | Implement `review_diff/2` |
| `lib/valkka/ai/providers/anthropic.ex` | Implement `review_diff/2` |
| `lib/valkka_web/live/pr_component.ex` | New: PR list + detail + review |
| `lib/valkka_web/live/dashboard_live.ex` | Add PR tab, handle PR events |
| `assets/css/app.css` | PR view styles |

---

## Kerto Availability Helper

A single utility used across features:

```elixir
defmodule Valkka.Kerto do
  @moduledoc "Kerto availability check. Returns false if Kerto is not installed."

  def available? do
    case Code.ensure_loaded(Kerto.Engine) do
      {:module, _} -> true
      {:error, _} -> false
    end
  end
end
```

Used in: AI commit messages (enrich with context), PR review (enrich with file risk), context panel (show/hide tab).

---

## Build Order

```
Phase 1: Pull support                    [small, unblocks nothing, quick win]
Phase 2: Command palette                 [medium, biggest UX impact]
Phase 3: AI commit messages              [medium, needs Anthropic provider]
Phase 4: PR review                       [medium-large, needs gh CLI wrapper]
Phase 5: Kerto integration               [medium, needs Kerto to exist]
```

Phase 1 and 2 can be built in parallel (no overlap). Phase 3 builds the AI provider that Phase 4 reuses. Phase 5 is independent and can happen whenever Kerto is ready.

---

## What Valkka-1 Is NOT

- No chat interface (Valkka-2)
- No conflict resolution (Valkka-2)
- No natural language git commands (Valkka-2)
- No Sykli/CI integration (Valkka-2)
- No semantic diff via tree-sitter (Valkka-2)
- No MCP server (Valkka-2)

---

## Success Criteria

1. **The speed test:** `Cmd+K` → type → execute in under 500ms total. No perceptible lag while typing.
2. **The commit test:** Stage → generate message → edit → commit → push in under 10 seconds.
3. **The pull test:** Pull from any repo with one keystroke. Fast-forward works, diverged fails clearly.
4. **The context test:** When Kerto is available, the context panel shows useful patterns for focused files. When Kerto is absent, nothing breaks.
5. **The review test:** Open a PR, read the diff, see AI summary, approve — all without opening GitHub.
