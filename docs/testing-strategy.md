# Valkka: Testing Strategy

> Borrowed from Kerto's discipline: 243 tests, no mocks for domain code.
> Borrowed from Sykli's approach: real test projects, integration over unit.

---

## 1. Testing Philosophy

1. **Pure domain is tested purely.** No GenServers, no ETS, no I/O. Data in, data out.
2. **NIFs are tested at both layers.** Rust unit tests for logic. Elixir integration tests for the boundary.
3. **AI is tested with deterministic mocks.** Never call a real LLM in tests.
4. **LiveView is tested with LiveViewTest.** No browser automation for MVP.
5. **Real git repos for integration.** Temp repos with known state, not mocked git.

---

## 2. Test Layers

```
┌─────────────────────────────────────────────────┐
│  Layer 4: E2E Tests                              │
│  Real browser, full stack, happy paths only      │
│  ~10 tests, run manually before release          │
├─────────────────────────────────────────────────┤
│  Layer 3: LiveView Integration Tests             │
│  Phoenix.LiveViewTest, real PubSub, mock AI      │
│  ~30 tests                                       │
├─────────────────────────────────────────────────┤
│  Layer 2: Application Integration Tests          │
│  Real GenServers, real NIFs, temp git repos      │
│  ~50 tests                                       │
├─────────────────────────────────────────────────┤
│  Layer 1: Domain Unit Tests                      │
│  Pure functions, no I/O, fast                    │
│  ~100 tests                                      │
├─────────────────────────────────────────────────┤
│  Layer 0: Rust Unit Tests                        │
│  git2 operations, tree-sitter parsing            │
│  ~80 tests                                       │
└─────────────────────────────────────────────────┘
```

**Target: ~270 tests at MVP. Run in < 30 seconds.**

---

## 3. Layer 0: Rust Unit Tests

### What to Test

| Module | Tests | Strategy |
|---|---|---|
| repo.rs | Open, close, info | Real temp repos via `tempfile` |
| log.rs | Log, commit detail, filtering | Repos with known commit history |
| branch.rs | CRUD, checkout | Branch operations on temp repos |
| diff.rs | Diff, stats | Known file changes |
| operations.rs | Stage, commit, merge, rebase | Full operation sequences |
| graph.rs | Layout computation | Known topologies (linear, branching, merging) |
| semantic/parser.rs | tree-sitter parsing | Known source files per language |
| semantic/languages.rs | Change detection | Known before/after file pairs |

### Test Fixtures

```
native/valkka_git/tests/fixtures/
├── repos/
│   ├── linear/          # 10 commits, no branches
│   ├── branching/       # 3 branches, merges
│   ├── conflict/        # merge conflict state
│   └── large/           # 1000+ commits for perf tests
├── files/
│   ├── rust_before.rs   # Known Rust file (before change)
│   ├── rust_after.rs    # Known Rust file (after change)
│   ├── go_before.go
│   ├── go_after.go
│   ├── elixir_before.ex
│   └── elixir_after.ex
```

### Example Rust Test

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn create_repo_with_commits(n: usize) -> (TempDir, git2::Repository) {
        let dir = TempDir::new().unwrap();
        let repo = git2::Repository::init(dir.path()).unwrap();

        for i in 0..n {
            // Create file, stage, commit
            let path = dir.path().join(format!("file_{}.txt", i));
            std::fs::write(&path, format!("content {}", i)).unwrap();
            // ... add to index, create commit
        }
        (dir, repo)
    }

    #[test]
    fn log_returns_commits_in_reverse_chronological_order() {
        let (_dir, repo) = create_repo_with_commits(5);
        let commits = log(&repo, &LogOpts { limit: 10, ..Default::default() });
        assert_eq!(commits.len(), 5);
        // timestamps should be descending
        for window in commits.windows(2) {
            assert!(window[0].timestamp >= window[1].timestamp);
        }
    }

    #[test]
    fn semantic_diff_detects_function_added() {
        let before = "";
        let after = "fn new_function() -> bool { true }";
        let changes = semantic_diff_content("test.rs", before, after);
        assert_eq!(changes[0].change_type, ChangeType::FunctionAdded);
        assert_eq!(changes[0].name, "new_function");
    }

    #[test]
    fn graph_layout_linear_uses_single_column() {
        let (_dir, repo) = create_repo_with_commits(10);
        let layout = compute_graph(&repo, &GraphOpts { limit: 10 });
        assert!(layout.nodes.iter().all(|n| n.column == 0));
        assert_eq!(layout.max_columns, 1);
    }

    #[test]
    fn merge_conflict_returns_both_sides() {
        let (_dir, repo) = create_repo_with_conflict();
        let result = merge(&repo, "feature");
        match result {
            MergeResult::Conflict(conflicts) => {
                assert_eq!(conflicts.len(), 1);
                assert!(conflicts[0].ours.is_some());
                assert!(conflicts[0].theirs.is_some());
            }
            _ => panic!("expected conflict"),
        }
    }
}
```

### Rust Performance Tests

```rust
#[cfg(test)]
mod bench {
    #[test]
    fn log_10000_commits_under_300ms() {
        let (_dir, repo) = create_repo_with_commits(10_000);
        let start = std::time::Instant::now();
        let _ = log(&repo, &LogOpts { limit: 10_000, ..Default::default() });
        assert!(start.elapsed() < std::time::Duration::from_millis(300));
    }

    #[test]
    fn graph_layout_1000_commits_under_50ms() {
        let (_dir, repo) = create_repo_with_commits(1_000);
        let start = std::time::Instant::now();
        let _ = compute_graph(&repo, &GraphOpts { limit: 1_000 });
        assert!(start.elapsed() < std::time::Duration::from_millis(50));
    }
}
```

---

## 4. Layer 1: Elixir Domain Unit Tests

### What to Test

Pure Elixir code — types, intent parsing, domain logic.

| Module | Tests | Strategy |
|---|---|---|
| Git.Types | Struct creation, validation | Pure construction |
| AI.Intent | Intent type construction | Value objects |
| AI.IntentParser (regex path) | Pattern matching | Known inputs → expected intents |
| Conversation | Exchange append, confirmation flow | Pure aggregate logic |
| Workspace | Repo registration, config | Pure aggregate logic |
| Review | Lifecycle (building → streaming → complete) | State machine |

### Example Elixir Domain Tests

```elixir
defmodule Valkka.AI.IntentParserTest do
  use ExUnit.Case, async: true

  describe "regex fast path" do
    test "parses 'commit' as generate_commit_msg" do
      assert {:ai_op, :generate_commit_msg, %{}} ==
        IntentParser.parse_fast("commit")
    end

    test "parses 'switch to main' as checkout" do
      assert {:git_op, :checkout, %{ref: "main"}} ==
        IntentParser.parse_fast("switch to main")
    end

    test "parses 'squash last 3 commits' as squash" do
      assert {:git_op, :squash, %{count: 3}} ==
        IntentParser.parse_fast("squash last 3 commits")
    end

    test "returns :unknown for ambiguous input" do
      assert :unknown == IntentParser.parse_fast("make it better")
    end

    test "parses 'what changed today' as changes_since" do
      assert {:query, :changes_since, %{since: _}} =
        IntentParser.parse_fast("what changed today")
    end

    test "parses 'who changed lib/repo.ex' as blame" do
      assert {:query, :blame, %{path: "lib/repo.ex"}} ==
        IntentParser.parse_fast("who changed lib/repo.ex")
    end
  end
end

defmodule Valkka.ConversationTest do
  use ExUnit.Case, async: true

  test "exchanges are append-only" do
    conv = Conversation.new("workspace-1")
    conv = Conversation.add_utterance(conv, "hello", :user)
    conv = Conversation.add_utterance(conv, "hi", :system)
    assert length(conv.exchanges) == 2
  end

  test "destructive operation requires confirmation" do
    conv = Conversation.new("workspace-1")
    intent = {:git_op, :push, %{force: true}}
    assert {:needs_confirmation, _} = Conversation.prepare_operation(conv, intent)
  end

  test "safe query does not require confirmation" do
    conv = Conversation.new("workspace-1")
    intent = {:query, :status, %{}}
    assert {:execute, _} = Conversation.prepare_operation(conv, intent)
  end
end
```

---

## 5. Layer 2: Application Integration Tests

### What to Test

Real GenServers, real NIFs, real temp git repos.

| Module | Tests | Strategy |
|---|---|---|
| Repo.Worker | Start, stop, status, operations | Temp repos, real NIFs |
| AI.StreamManager | Request, stream, complete | Mock AI provider |
| AI.ContextBuilder | Build context from repo state | Real repo, structured output |
| Workspace.Registry | Register, lookup, remove repos | Real registry |
| Watcher.Handler | File change → state refresh | Real file writes |

### Test Helpers

```elixir
defmodule Valkka.TestHelpers do
  @moduledoc "Helpers for creating test git repos with known state."

  def create_test_repo(opts \\ []) do
    dir = System.tmp_dir!() |> Path.join("valkka_test_#{:rand.uniform(999_999)}")
    File.mkdir_p!(dir)

    # Init repo
    System.cmd("git", ["init"], cd: dir)
    System.cmd("git", ["config", "user.email", "test@test.com"], cd: dir)
    System.cmd("git", ["config", "user.name", "Test"], cd: dir)

    # Create initial commit
    File.write!(Path.join(dir, "README.md"), "# Test")
    System.cmd("git", ["add", "."], cd: dir)
    System.cmd("git", ["commit", "-m", "initial"], cd: dir)

    if opts[:branches] do
      for branch <- opts[:branches] do
        System.cmd("git", ["checkout", "-b", branch], cd: dir)
        File.write!(Path.join(dir, "#{branch}.txt"), branch)
        System.cmd("git", ["add", "."], cd: dir)
        System.cmd("git", ["commit", "-m", "add #{branch}"], cd: dir)
      end
      System.cmd("git", ["checkout", "main"], cd: dir)
    end

    if opts[:dirty] do
      File.write!(Path.join(dir, "dirty.txt"), "uncommitted")
    end

    dir
  end

  def cleanup_test_repo(dir) do
    File.rm_rf!(dir)
  end
end
```

### Example Integration Tests

```elixir
defmodule Valkka.Repo.WorkerTest do
  use ExUnit.Case
  import Valkka.TestHelpers

  setup do
    dir = create_test_repo(branches: ["feat/auth", "feat/api"], dirty: true)
    {:ok, pid} = Valkka.Repo.Worker.start_link(path: dir)
    on_exit(fn ->
      GenServer.stop(pid)
      cleanup_test_repo(dir)
    end)
    %{pid: pid, dir: dir}
  end

  test "reports dirty status", %{pid: pid} do
    status = Valkka.Repo.Worker.status(pid)
    assert status.state == :dirty
    assert length(status.untracked) > 0
  end

  test "can switch branches", %{pid: pid} do
    assert :ok = Valkka.Repo.Worker.checkout(pid, "feat/auth")
    status = Valkka.Repo.Worker.status(pid)
    assert status.branch == "feat/auth"
  end

  test "commit creates new commit", %{pid: pid} do
    Valkka.Repo.Worker.stage(pid, ["dirty.txt"])
    {:ok, oid} = Valkka.Repo.Worker.commit(pid, "add dirty file")
    assert String.length(oid) == 40
  end

  test "crashes on invalid repo recover via supervisor" do
    # corrupt .git directory
    # worker should crash and restart
    # status should report error state
  end
end
```

---

## 6. Layer 3: LiveView Integration Tests

### What to Test

| Component | Tests | Strategy |
|---|---|---|
| DashboardLive | Shows repos, real-time updates | LiveViewTest, PubSub broadcasts |
| ChatLive | Send utterance, receive response | LiveViewTest, mock AI |
| RepoLive | Status display, operations | LiveViewTest, real repo |
| GraphComponent | Renders with data | Component testing |

### Example LiveView Test

```elixir
defmodule ValkkaWeb.ChatLiveTest do
  use ValkkaWeb.ConnCase
  import Phoenix.LiveViewTest

  setup do
    dir = Valkka.TestHelpers.create_test_repo()
    {:ok, _} = Valkka.Repo.Worker.start_link(path: dir)
    on_exit(fn -> Valkka.TestHelpers.cleanup_test_repo(dir) end)
    %{dir: dir}
  end

  test "shows workspace status on mount", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    assert html =~ "valkka_test"
    assert html =~ "main"
  end

  test "processes natural language command", %{conn: conn} do
    {:ok, view, _} = live(conn, "/chat")
    view
    |> element("form")
    |> render_submit(%{utterance: "what branch am I on"})

    assert render(view) =~ "main"
  end

  test "shows confirmation for destructive operations", %{conn: conn} do
    {:ok, view, _} = live(conn, "/chat")
    view
    |> element("form")
    |> render_submit(%{utterance: "force push"})

    assert render(view) =~ "confirm"
  end
end
```

---

## 7. AI Testing

### Mock Provider

```elixir
defmodule Valkka.AI.Providers.Mock do
  @behaviour Valkka.AI.Provider

  @impl true
  def stream(prompt, _opts) do
    # Return deterministic responses based on prompt content
    response = cond do
      prompt =~ "commit message" ->
        "feat: add user authentication\n\nImplement JWT-based auth with refresh tokens."
      prompt =~ "review" ->
        "## Summary\nThis PR adds auth. Low risk.\n## Suggestions\nAdd rate limiting."
      true ->
        "I understand your request."
    end

    # Simulate streaming by chunking the response
    chunks = response |> String.graphemes() |> Enum.chunk_every(5) |> Enum.map(&Enum.join/1)
    {:ok, chunks}
  end
end
```

### Config for Test Environment

```elixir
# config/test.exs
config :valkka, :ai_provider, Valkka.AI.Providers.Mock
```

---

## 8. Testing the Semantic Diff

This is Valkka's moat — test it thoroughly.

### Test Matrix

| Language | Scenario | Expected |
|---|---|---|
| Rust | Function added | `type: function_added, name: "new_fn"` |
| Rust | Function signature changed | `type: signature_changed, old_signature, new_signature` |
| Rust | Function body modified | `type: function_modified` |
| Rust | Struct field added | `type: type_modified` |
| Go | Interface method added | `type: type_modified` |
| Go | Function renamed | `type: function_removed + function_added` |
| Elixir | Module function added | `type: function_added` |
| Elixir | Macro changed | `type: function_modified` |
| Python | Class method added | `type: function_added` |
| JS/TS | Export added | `type: function_added` |
| JS/TS | Import changed | `type: import_changed` |
| Any | File renamed | `type: file_renamed, similarity > 0.8` |
| Unknown | Binary file | `unsupported_files` list |

### Golden File Tests

```
native/valkka_git/tests/semantic/golden/
├── rust/
│   ├── add_function.before.rs
│   ├── add_function.after.rs
│   └── add_function.expected.json
├── go/
│   ├── modify_interface.before.go
│   ├── modify_interface.after.go
│   └── modify_interface.expected.json
└── elixir/
    ├── add_module_fn.before.ex
    ├── add_module_fn.after.ex
    └── add_module_fn.expected.json
```

---

## 9. CI Integration (Sykli)

```go
// sykli.go for Valkka
s := sykli.New()

rust := s.Task("rust-tests").
    Run("cd native/valkka_git && cargo test").
    Inputs("native/**/*.rs", "native/**/Cargo.toml")

elixir := s.Task("elixir-tests").
    Run("mix test").
    Inputs("lib/**/*.ex", "test/**/*.exs", "mix.exs").
    After("rust-tests")  // NIFs must compile first

lint := s.Task("lint").
    Run("mix format --check-formatted && mix credo --strict").
    Inputs("lib/**/*.ex")

dialyzer := s.Task("dialyzer").
    Run("mix dialyzer").
    Inputs("lib/**/*.ex").
    After("elixir-tests")

s.Task("clippy").
    Run("cd native/valkka_git && cargo clippy -- -D warnings").
    Inputs("native/**/*.rs")

s.Emit()
```

---

## 10. Test Targets

| Metric | Target |
|---|---|
| Total tests | 270+ at MVP |
| Test run time | < 30 seconds (all layers) |
| Rust test time | < 10 seconds |
| Domain test time | < 2 seconds (pure, async) |
| Integration test time | < 15 seconds |
| LiveView test time | < 5 seconds |
| Coverage (domain) | > 90% |
| Coverage (NIF boundary) | > 80% |
| Coverage (LiveView) | > 60% |
| Flaky tests | 0 (deterministic only) |
