# Valkka × Sykli Integration

> See CI status without leaving your git command center.
> Know if your changes pass before you push.

---

## 1. The Integration

Sykli runs CI. Valkka shows results and acts on them.

```
Sykli (CI engine)                  Valkka (git command center)
──────────────                     ──────────────────────────
Pipeline runs → ─────────────────→ Real-time task status in repo view
Task fails → ───────────────────→ Error context in chat + Kerto learning
Occurrence emitted → ───────────→ Structured CI data for AI review
Context generated → ────────────→ .sykli/context.json enriches AI prompts

Valkka triggers → ───────────────→ "run tests" → sykli run
Valkka queries → ────────────────→ "did CI pass?" → read occurrence
```

---

## 2. CI Status in Repo View

### Real-Time Pipeline Status

```elixir
defmodule Valkka.Sykli.StatusMonitor do
  @moduledoc "Watches Sykli pipeline status for monitored repos."

  use GenServer

  def init(repo_path) do
    # Watch .sykli/occurrence.json for changes
    :ok = FileSystem.subscribe(Path.join(repo_path, ".sykli"))

    # Read current status
    status = read_current_status(repo_path)
    {:ok, %{path: repo_path, status: status}}
  end

  def handle_info({:file_event, _watcher, {path, _events}}, state) do
    if String.ends_with?(path, "occurrence.json") do
      status = read_current_status(state.path)
      Phoenix.PubSub.broadcast(
        Valkka.PubSub,
        "repo:#{state.path}:ci",
        {:ci_status_updated, status}
      )
      {:noreply, %{state | status: status}}
    else
      {:noreply, state}
    end
  end

  defp read_current_status(repo_path) do
    occurrence_path = Path.join(repo_path, ".sykli/occurrence.json")

    case File.read(occurrence_path) do
      {:ok, content} ->
        content
        |> Jason.decode!()
        |> parse_occurrence()
      {:error, _} ->
        %{status: :no_ci}
    end
  end

  defp parse_occurrence(occurrence) do
    %{
      status: determine_status(occurrence),
      tasks: parse_tasks(occurrence),
      duration: occurrence["history"]["duration_ms"],
      timestamp: occurrence["context"]["timestamp"],
      error: occurrence["error"],
      reasoning: occurrence["reasoning"]
    }
  end
end
```

### Dashboard Display

```
┌─ repo: valkka (main) ────────────────────┐
│ 3 uncommitted changes                   │
│ CI: ✓ passed (12s ago)                  │
│   test ✓  lint ✓  build ✓  clippy ✓    │
└──────────────────────────────────────────┘

┌─ repo: false-protocol (feat/v2) ────────┐
│ clean, 1 PR open                        │
│ CI: ✗ failed (2 min ago)                │
│   test ✗  lint ✓  build ✓              │
│   "test_occurrence_roundtrip failed:     │
│    expected {:ok, _}, got {:error, ...}" │
│                                         │
│   [Show details] [Re-run] [Fix with AI] │
└──────────────────────────────────────────┘
```

---

## 3. CI-Aware AI Context

When Valkka's AI reviews code or generates commit messages, it includes Sykli context.

### Context Builder Integration

```elixir
defmodule Valkka.AI.ContextBuilder do
  def build_context(repo_id, intent) do
    base_context = build_git_context(repo_id, intent)

    # Enrich with Sykli CI context
    sykli_context = Valkka.Sykli.ContextProvider.get_context(repo_id)
    kerto_context = Valkka.Kerto.ContextProvider.get_context(repo_id)

    %{
      git: base_context,
      ci: sykli_context,
      knowledge: kerto_context
    }
  end
end

defmodule Valkka.Sykli.ContextProvider do
  def get_context(repo_path) do
    context_path = Path.join(repo_path, ".sykli/context.json")

    case File.read(context_path) do
      {:ok, content} ->
        context = Jason.decode!(content)
        %{
          pipeline_health: context["health"],
          recent_failures: context["health"]["recent_failures"],
          flaky_tasks: context["health"]["flaky_tasks"],
          file_coverage: context["coverage"]["file_to_tasks"],
          last_run: context["last_run"]
        }
      {:error, _} ->
        nil
    end
  end

  def files_with_failing_tests(repo_path, changed_files) do
    context = get_context(repo_path)
    return nil if context == nil

    # Map changed files to their test tasks
    changed_files
    |> Enum.flat_map(fn file ->
      tasks = Map.get(context.file_coverage || %{}, file, [])
      failing = Enum.filter(tasks, fn task ->
        task in (context.recent_failures || [])
      end)
      if failing != [], do: [{file, failing}], else: []
    end)
  end
end
```

### AI Prompt Enrichment

```
When reviewing a PR, the AI sees:

## Git Context
- 5 files changed, 120 insertions, 30 deletions
- Semantic: 2 functions added, 1 modified

## CI Context (from Sykli)
- Pipeline health: 85% pass rate (last 10 runs)
- Flaky tasks: test_session (failed 3/10 runs)
- File coverage: auth/handler.go → [test, lint, security-scan]
- Last failure: "test_session: timeout after 30s"

## Knowledge Context (from Kerto)
- auth/handler.go breaks login_test.go (weight 0.78)
- Decided: JWT over sessions (weight 0.85)

→ AI produces a review that considers CI history and known patterns
```

---

## 4. Run Sykli from Valkka

### Natural Language CI Commands

```
you: run tests

valkka: Running Sykli pipeline...

  test     ████████████████ ✓  4.2s
  lint     ████████████████ ✓  1.1s
  build    ██████████░░░░░░ ...  (running)

you: run just the tests for auth

valkka: Running: sykli run --only test --filter "auth"

  test[auth] ████████████████ ✓  1.8s

  All tests passing.
```

### Implementation

```elixir
defmodule Valkka.Sykli.Runner do
  @moduledoc "Triggers Sykli pipelines from Valkka."

  def run(repo_path, opts \\ []) do
    args = build_args(opts)
    task = Task.async(fn ->
      System.cmd("sykli", ["run" | args], cd: repo_path, stderr_to_stdout: true)
    end)

    # Stream output to PubSub
    stream_output(task, repo_path)
  end

  def run_task(repo_path, task_name) do
    run(repo_path, only: [task_name])
  end

  defp build_args(opts) do
    args = []
    args = if opts[:only], do: args ++ ["--only", Enum.join(opts[:only], ",")], else: args
    args = if opts[:filter], do: args ++ ["--filter", opts[:filter]], else: args
    args
  end
end
```

### Intent Integration

```elixir
# In IntentParser
{"run tests", {:sykli_op, :run, %{}}},
{"run ci", {:sykli_op, :run, %{}}},
{"run lint", {:sykli_op, :run, %{only: ["lint"]}}},
{"did ci pass", {:sykli_query, :status, %{}}},
{"why did ci fail", {:sykli_query, :failure_reason, %{}}},
{"rerun failed tests", {:sykli_op, :run, %{only: :failed}}},
```

---

## 5. CI Failure → Kerto Learning

When Sykli reports a failure, Valkka feeds it to Kerto.

```elixir
defmodule Valkka.Sykli.KertoFeeder do
  @moduledoc "Feeds Sykli results into Kerto's knowledge graph."

  def on_ci_status_updated(%{status: :failed} = ci_status, repo_path) do
    # Get changed files from last commit
    changed_files = Valkka.Git.Commands.last_commit_files(repo_path)

    # Emit ci.run.failed occurrence to Kerto
    for task <- ci_status.tasks, task.status == :failed do
      Valkka.Kerto.Emitter.on_ci_result(
        repo_path,
        task.name,
        :failed,
        changed_files
      )
    end
  end

  def on_ci_status_updated(%{status: :passed}, repo_path) do
    changed_files = Valkka.Git.Commands.last_commit_files(repo_path)

    # Emit ci.run.passed → weakens existing :breaks relationships
    Valkka.Kerto.Emitter.on_ci_result(repo_path, "pipeline", :passed, changed_files)
  end
end
```

### The Feedback Loop

```
1. Developer changes auth.go
2. Sykli runs → login_test fails
3. Valkka sees failure → emits ci.run.failed to Kerto
4. Kerto learns: auth.go :breaks login_test (weight 0.7)
5. Next time someone touches auth.go...
6. Valkka shows: "⚠ This file has broken login_test 3 times"
7. Developer writes better code
8. Sykli runs → passes
9. Valkka emits ci.run.passed → Kerto weakens the :breaks edge
10. Over time, if auth.go stops breaking things, the warning fades
```

---

## 6. Occurrence-Based Architecture

Both Sykli and Kerto use FALSE Protocol occurrences. Valkka is the bridge.

```
┌─────────┐     occurrence.json     ┌─────────┐
│  Sykli  │ ──────────────────────→ │  Valkka  │
│  (CI)   │                         │ (bridge) │
└─────────┘                         └────┬────┘
                                         │
                                    occurrence
                                         │
                                    ┌────▼────┐
                                    │  Kerto  │
                                    │ (graph) │
                                    └─────────┘
```

Valkka doesn't need to understand Sykli internals. It reads the occurrence (standardized FALSE Protocol format) and passes it to Kerto. The occurrence IS the API.

---

## 7. Pre-Push CI Check

Before pushing, Valkka can run a quick CI check.

```
you: push

valkka: Before pushing, want me to run tests? Last push to this branch
       failed CI 2 days ago (login_test timeout).

       [Run tests first] [Push anyway] [Cancel]

you: run tests first

valkka: Running Sykli...
  test     ✓  4.2s
  lint     ✓  1.1s

  All clear. Pushing to origin/feat/auth...
  ✓ Pushed successfully.
```

### Implementation

```elixir
defmodule Valkka.Git.Commands do
  def push_with_ci_check(repo_id, remote, branch) do
    # Check Kerto for previous CI failures on this branch
    history = Valkka.Kerto.BranchHealth.assess(repo_id, branch)

    if history.known_issues != [] do
      # Suggest running CI first
      {:suggest_ci, history.known_issues}
    else
      # Safe to push
      do_push(repo_id, remote, branch)
    end
  end
end
```

---

## 8. Configuration

```elixir
# config/config.exs
config :valkka, :sykli,
  enabled: true,
  auto_run_on_commit: false,        # run CI after every commit?
  pre_push_check: true,             # suggest CI before push?
  watch_occurrence: true,           # watch .sykli/occurrence.json?
  binary_path: "sykli"              # path to sykli binary
```
