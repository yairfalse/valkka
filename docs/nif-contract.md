# Valkka: Rust NIF Contract

> The NIF boundary is the most expensive thing to change. Get it right.

---

## 1. Principles

1. **Narrow surface.** Every NIF function must justify its existence. If Elixir can do it reasonably, don't NIF it.
2. **Dirty schedulers always.** Every NIF runs on `DirtyCpu` or `DirtyIo`. Never block BEAM schedulers.
3. **Data copies across the boundary.** Rust returns Elixir terms (atoms, maps, lists, binaries). No shared mutable state except `ResourceArc` handles.
4. **Errors are values.** NIFs return `{:ok, result}` or `{:error, reason}`. Never panic. Never crash the BEAM.
5. **Handle lifecycle via ResourceArc.** Repository handles are opaque to Elixir. Rust owns the memory. BEAM GC triggers Rust drop.

---

## 2. Crate Structure

```
native/valkka_git/
├── Cargo.toml
└── src/
    ├── lib.rs              # NIF registration, module init
    ├── error.rs            # Error types → Elixir error tuples
    ├── handle.rs           # RepoHandle (ResourceArc)
    ├── types.rs            # Shared type definitions
    │
    ├── repo.rs             # repo_open, repo_info, repo_close
    ├── log.rs              # log, commit_detail
    ├── branch.rs           # branches, checkout, create_branch, delete_branch
    ├── diff.rs             # diff, diff_stats
    ├── operations.rs       # stage, unstage, commit, merge, rebase, cherry_pick, stash
    ├── search.rs           # blame, search_commits, file_history
    ├── graph.rs            # compute_graph, graph_subset
    │
    └── semantic/
        ├── mod.rs          # semantic_diff entry point
        ├── parser.rs       # tree-sitter AST parsing
        └── languages.rs    # per-language change detection
```

### Cargo.toml Dependencies

```toml
[dependencies]
rustler = "0.34"
git2 = "0.19"
tree-sitter = "0.24"
tree-sitter-rust = "0.23"
tree-sitter-go = "0.23"
tree-sitter-javascript = "0.23"
tree-sitter-typescript = "0.23"
tree-sitter-python = "0.23"
tree-sitter-elixir = "0.3"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
```

---

## 3. Handle: RepoHandle

```rust
use rustler::ResourceArc;
use std::sync::Mutex;
use std::path::PathBuf;

pub struct RepoHandle {
    pub repo: Mutex<git2::Repository>,
    pub path: PathBuf,
}

// Safety: git2::Repository is not Send/Sync by default.
// We wrap in Mutex to serialize access. Only one NIF call
// operates on a repo at a time. This is fine because the
// Elixir GenServer already serializes calls per repo.
unsafe impl Send for RepoHandle {}
unsafe impl Sync for RepoHandle {}
```

### Elixir Side

```elixir
defmodule Valkka.Git.Native do
  use Rustler,
    otp_app: :valkka,
    crate: :valkka_git

  # The handle is opaque. Elixir never inspects it.
  # When the Elixir process holding the reference dies,
  # BEAM GC triggers Rust Drop → git2::Repository closes.

  def repo_open(_path), do: :erlang.nif_error(:not_loaded)
  def repo_close(_handle), do: :erlang.nif_error(:not_loaded)
  # ... all other NIFs
end
```

---

## 4. Function Contracts

### 4.1 Repository Management

#### `repo_open(path) → {:ok, handle} | {:error, reason}`

```rust
#[rustler::nif(schedule = "DirtyCpu")]
fn repo_open(path: String) -> Result<ResourceArc<RepoHandle>, String> {
    let repo = git2::Repository::open(&path)
        .map_err(|e| format!("failed to open repo: {}", e))?;
    Ok(ResourceArc::new(RepoHandle {
        repo: Mutex::new(repo),
        path: PathBuf::from(path),
    }))
}
```

| Param | Type | Notes |
|---|---|---|
| path | String | Absolute path to repo root (containing .git) |
| **Returns** | ResourceArc\<RepoHandle\> | Opaque handle |
| **Errors** | String | "failed to open repo: {git2 error}" |

#### `repo_info(handle) → {:ok, map} | {:error, reason}`

Returns current repository status snapshot.

```rust
// Returns:
%{
  head: "abc123def456...",          # OID as hex string
  branch: "main" | nil,            # nil if detached HEAD
  state: "clean" | "merge" | "rebase" | "cherry_pick" | "revert",
  staged: [%{path: String, status: String}],
  unstaged: [%{path: String, status: String}],
  untracked: [String],
  ahead: integer,                   # commits ahead of upstream
  behind: integer                   # commits behind upstream
}
```

#### `repo_close(handle) → :ok`

Explicitly drops the handle. Optional — BEAM GC handles this.

---

### 4.2 Commit & History

#### `log(handle, opts) → {:ok, [commit]} | {:error, reason}`

```rust
// opts:
%{
  limit: integer,                  # max commits (default 100)
  since: String | nil,             # ISO8601 datetime
  until: String | nil,             # ISO8601 datetime
  author: String | nil,            # filter by author
  path: String | nil,              # filter by file path
  branch: String | nil             # start from branch (default HEAD)
}

// Returns list of:
%{
  oid: String,                     # 40-char hex
  message: String,                 # full commit message
  summary: String,                 # first line
  author_name: String,
  author_email: String,
  timestamp: integer,              # unix timestamp
  parents: [String]                # parent OIDs
}
```

#### `commit_detail(handle, oid) → {:ok, map} | {:error, reason}`

```rust
// Returns:
%{
  oid: String,
  message: String,
  author_name: String,
  author_email: String,
  committer_name: String,
  committer_email: String,
  timestamp: integer,
  parents: [String],
  diff_stats: %{
    files_changed: integer,
    insertions: integer,
    deletions: integer
  },
  files: [%{path: String, status: String, insertions: integer, deletions: integer}]
}
```

---

### 4.3 Branching

#### `branches(handle) → {:ok, [branch]} | {:error, reason}`

```rust
// Returns list of:
%{
  name: String,                    # "main", "feat/auth"
  target: String,                  # OID
  is_head: boolean,
  is_remote: boolean,
  upstream: String | nil,          # "origin/main"
  ahead: integer,
  behind: integer
}
```

#### `checkout(handle, ref) → :ok | {:error, reason}`

| Param | Type | Notes |
|---|---|---|
| ref | String | Branch name, tag, or OID |
| **Errors** | String | "uncommitted changes would be overwritten", "ref not found" |

#### `create_branch(handle, name, target) → {:ok, branch} | {:error, reason}`

| Param | Type | Notes |
|---|---|---|
| name | String | Branch name |
| target | String \| nil | OID or branch to base on. nil = HEAD |

#### `delete_branch(handle, name) → :ok | {:error, reason}`

| **Errors** | String | "cannot delete current branch", "branch not found" |

---

### 4.4 Diffing

#### `diff(handle, from, to) → {:ok, diff} | {:error, reason}`

```rust
// from/to: OID strings, branch names, or special values:
//   "HEAD" — current HEAD
//   "STAGED" — index (staged changes)
//   "WORKDIR" — working directory
//
// Common combos:
//   diff(handle, "STAGED", "WORKDIR") → unstaged changes
//   diff(handle, "HEAD", "STAGED") → staged changes
//   diff(handle, "main", "feat/x") → branch diff

// Returns:
%{
  files: [
    %{
      path: String,
      old_path: String | nil,       # if renamed
      status: "added" | "modified" | "deleted" | "renamed" | "copied",
      insertions: integer,
      deletions: integer,
      hunks: [
        %{
          header: String,            # @@ -1,5 +1,7 @@
          old_start: integer,
          old_lines: integer,
          new_start: integer,
          new_lines: integer,
          lines: [
            %{
              type: "+" | "-" | " ", # add, delete, context
              content: String
            }
          ]
        }
      ]
    }
  ],
  stats: %{
    files_changed: integer,
    insertions: integer,
    deletions: integer
  }
}
```

#### `diff_stats(handle, from, to) → {:ok, stats} | {:error, reason}`

Lightweight version — stats only, no hunks. For dashboard display.

```rust
// Returns:
%{
  files_changed: integer,
  insertions: integer,
  deletions: integer,
  files: [%{path: String, status: String, insertions: integer, deletions: integer}]
}
```

#### `semantic_diff(handle, from, to) → {:ok, semantic_diff} | {:error, reason}`

The differentiator. Uses tree-sitter to parse both sides of each changed file.

```rust
// Returns:
%{
  changes: [
    %{
      type: "function_added" | "function_modified" | "function_removed" |
            "type_added" | "type_modified" | "type_removed" |
            "import_changed" | "file_renamed" | "signature_changed" |
            "constant_changed" | "unknown",
      name: String,                  # entity name (function, type, etc.)
      file: String,                  # file path
      language: String,              # "rust", "go", "elixir", etc.
      summary: String,               # human-readable: "Added timeout parameter"
      lines_added: integer,
      lines_removed: integer,
      old_signature: String | nil,   # for signature_changed
      new_signature: String | nil
    }
  ],
  stats: %{
    files: integer,
    insertions: integer,
    deletions: integer,
    functions_added: integer,
    functions_modified: integer,
    functions_removed: integer,
    types_added: integer,
    types_modified: integer,
    types_removed: integer
  },
  languages: [String],               # languages detected
  unsupported_files: [String]         # files tree-sitter couldn't parse
}
```

**Supported languages (MVP):**
- Rust, Go, Elixir, Python, JavaScript, TypeScript

**Unsupported files** get `type: "unknown"` with line-level stats only.

---

### 4.5 Operations

All mutating operations. Elixir side must confirm before calling.

#### `stage(handle, paths) → :ok | {:error, reason}`

| Param | Type | Notes |
|---|---|---|
| paths | [String] | Relative paths from repo root. Empty list = stage all |

#### `unstage(handle, paths) → :ok | {:error, reason}`

Same as stage but reverses.

#### `commit(handle, message, opts) → {:ok, oid} | {:error, reason}`

```rust
// opts:
%{
  author_name: String | nil,       # nil = use git config
  author_email: String | nil,
  amend: boolean                   # default false
}
// Returns: OID of new commit as hex string
```

#### `merge(handle, source) → {:ok, result} | {:error, reason}`

```rust
// source: branch name or OID

// Returns on success:
%{type: "fast_forward", oid: String}
# or
%{type: "merge_commit", oid: String}

// Returns on conflict:
%{type: "conflict", conflicts: [
  %{
    path: String,
    ancestor: String | nil,         # common ancestor content
    ours: String,                   # our side
    theirs: String                  # their side
  }
]}
```

#### `rebase(handle, opts) → {:ok, result} | {:error, reason}`

```rust
// opts:
%{
  onto: String,                    # branch or OID to rebase onto
  interactive: boolean             # if true, returns plan before executing
}

// Returns:
%{
  type: "completed" | "conflict" | "plan",
  commits_replayed: integer,
  new_head: String | nil,          # OID after rebase
  # if type == "plan":
  steps: [%{oid: String, message: String, action: "pick"}],
  # if type == "conflict":
  conflict: %{path: String, ancestor: String, ours: String, theirs: String}
}
```

#### `squash(handle, count, message) → {:ok, oid} | {:error, reason}`

Squash last N commits into one with given message.

| Param | Type | Notes |
|---|---|---|
| count | integer | Number of commits to squash (from HEAD) |
| message | String | New commit message |

#### `cherry_pick(handle, oid) → {:ok, result} | {:error, reason}`

Same result shape as merge (can succeed or conflict).

#### `stash(handle, message) → :ok | {:error, reason}`

#### `stash_pop(handle) → :ok | {:error, reason}`

#### `push(handle, remote, branch, opts) → :ok | {:error, reason}`

```rust
// opts:
%{
  force: boolean,                  # default false — DANGEROUS
  set_upstream: boolean            # default false
}

// Errors: "authentication failed", "rejected (non-fast-forward)", etc.
```

#### `pull(handle, remote, branch) → {:ok, result} | {:error, reason}`

Returns merge result (same shape as merge).

---

### 4.6 Search

#### `blame(handle, path) → {:ok, [blame_line]} | {:error, reason}`

```rust
// Returns list of:
%{
  line_number: integer,
  oid: String,                     # commit that last changed this line
  author_name: String,
  author_email: String,
  timestamp: integer,
  line_content: String
}
```

#### `file_history(handle, path, opts) → {:ok, [commit]} | {:error, reason}`

Same return shape as `log` but filtered to commits that touched this file.

#### `search_commits(handle, query, opts) → {:ok, [commit]} | {:error, reason}`

Searches commit messages for query string. Same return shape as `log`.

---

### 4.7 Graph Computation

#### `compute_graph(handle, opts) → {:ok, graph_layout} | {:error, reason}`

Computes visual positions for the commit graph.

```rust
// opts:
%{
  limit: integer,                  # max commits (default 500)
  branch: String | nil,            # start from branch (default all)
  since: String | nil              # ISO8601 datetime
}

// Returns:
%{
  nodes: [
    %{
      oid: String,
      column: integer,             # x position (lane)
      row: integer,                # y position (order)
      message: String,             # summary
      author: String,
      timestamp: integer,
      branch: String | nil,        # branch name if head
      is_merge: boolean,
      parents: [%{oid: String, column: integer}]  # for drawing edges
    }
  ],
  max_columns: integer,            # total lanes needed
  branches: [%{name: String, column: integer, color_index: integer}],
  total_commits: integer           # total available (before limit)
}
```

#### `graph_subset(handle, from_row, count) → {:ok, graph_layout} | {:error, reason}`

For virtualized scrolling. Returns a window of the graph.

---

## 5. Error Handling

### Error Types (Rust Side)

```rust
#[derive(Debug)]
pub enum ValkkaError {
    // Git errors
    RepoNotFound(String),
    RefNotFound(String),
    MergeConflict(Vec<ConflictFile>),
    DirtyWorkdir,
    DetachedHead,
    AuthFailed,
    NetworkError(String),

    // NIF errors
    HandleInvalid,
    LockPoisoned,

    // Semantic diff errors
    UnsupportedLanguage(String),
    ParseFailed(String),
}

impl Into<rustler::Error> for ValkkaError {
    fn into(self) -> rustler::Error {
        // Always return {:error, reason_string}
        // Never panic, never crash the BEAM
    }
}
```

### Elixir Side Error Handling

```elixir
defmodule Valkka.Git.Native do
  # Every NIF call is wrapped to normalize errors
  def safe_call(fun) do
    case fun.() do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, normalize_error(reason)}
      :ok -> :ok
    end
  rescue
    ArgumentError -> {:error, :invalid_handle}
    ErlangError -> {:error, :nif_crashed}
  end
end
```

### Critical Rule: NIF Must Never Panic

If a NIF panics, it crashes the entire BEAM VM. Every NIF function must:
1. Catch all Rust panics via `std::panic::catch_unwind`
2. Convert panics to `{:error, "internal error: ..."}`
3. Never unwrap Options or Results without handling the None/Err case
4. Log panics to a Rust-side log file for debugging

```rust
#[rustler::nif(schedule = "DirtyCpu")]
fn safe_nif_wrapper(handle: ResourceArc<RepoHandle>) -> Result<Term, String> {
    std::panic::catch_unwind(|| {
        // actual NIF logic here
    })
    .map_err(|_| "internal error: NIF panicked".to_string())?
}
```

---

## 6. Performance Contracts

| NIF Function | Target Latency | Notes |
|---|---|---|
| repo_open | < 50ms | Includes reading .git/HEAD |
| repo_info | < 20ms | Reads index + HEAD + upstream |
| log (100 commits) | < 30ms | Walk commit graph |
| log (10,000 commits) | < 300ms | Bounded by I/O |
| branches | < 10ms | Read refs |
| diff (small, < 100 lines) | < 10ms | In-memory |
| diff (large, > 10,000 lines) | < 200ms | Streaming not needed |
| semantic_diff (small) | < 100ms | tree-sitter parse + compare |
| semantic_diff (large) | < 500ms | Multiple files |
| compute_graph (500 commits) | < 50ms | Layout algorithm |
| compute_graph (50,000 commits) | < 500ms | Virtualized |
| stage/unstage | < 20ms | Index update |
| commit | < 50ms | Write object + update ref |
| blame (1 file) | < 100ms | Full history walk |

---

## 7. Testing the NIF

### Rust Unit Tests

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn setup_test_repo() -> (TempDir, git2::Repository) {
        let dir = TempDir::new().unwrap();
        let repo = git2::Repository::init(dir.path()).unwrap();
        // create initial commit
        (dir, repo)
    }

    #[test]
    fn test_log_returns_commits() {
        let (_dir, repo) = setup_test_repo();
        // test directly against git2, not through NIF
    }
}
```

### Elixir Integration Tests

```elixir
defmodule Valkka.Git.NativeTest do
  use ExUnit.Case

  setup do
    # Create temp git repo with known state
    {:ok, path} = create_test_repo()
    {:ok, handle} = Valkka.Git.Native.repo_open(path)
    on_exit(fn -> File.rm_rf!(path) end)
    %{handle: handle, path: path}
  end

  test "log returns commits in order", %{handle: handle} do
    {:ok, commits} = Valkka.Git.Native.log(handle, %{limit: 10})
    assert length(commits) > 0
    assert hd(commits).oid |> String.length() == 40
  end
end
```
