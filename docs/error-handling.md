# Valkka: Error Handling Strategy

> Inspired by Sykli's rich error formatting and Kerto's fault tolerance.
> Errors are first-class citizens, not afterthoughts.

---

## 1. Error Philosophy

1. **Errors are values, not exceptions.** `{:ok, result} | {:error, reason}` everywhere.
2. **Crash and restart, don't defend.** OTP supervision handles recovery. Don't try to recover from every edge case — let the process die and restart clean.
3. **User-facing errors are structured.** Never show raw stack traces or git stderr. Always provide: what happened, why, and what to do.
4. **NIF errors never crash the BEAM.** This is the one place where defensive coding is mandatory.

---

## 2. Error Categories

### 2.1 Git Operation Errors

| Error | Cause | User Message | Recovery |
|---|---|---|---|
| Dirty workdir | Checkout/merge with uncommitted changes | "You have uncommitted changes in {files}. Commit or stash first?" | Offer to stash |
| Merge conflict | Conflicting changes during merge/rebase | "Conflict in {files}. Resolve or abort?" | Show conflict UI |
| Ref not found | Branch/tag doesn't exist | "Branch '{name}' not found. Did you mean '{suggestion}'?" | Fuzzy match suggestions |
| Auth failed | Push/pull without credentials | "Authentication failed for {remote}. Check your SSH key or token." | Link to setup guide |
| Network error | Remote unreachable | "Can't reach {remote}. Check your connection." | Retry button |
| Detached HEAD | Operations that need a branch | "You're in detached HEAD state. Create a branch first?" | Offer to create branch |
| Lock file | Another git process running | "Another git operation is in progress. Wait or force?" | Wait + retry, or force |
| Corrupt repo | Damaged .git directory | "Repository at {path} appears damaged. Run 'git fsck' to diagnose." | Link to recovery steps |
| Non-fast-forward | Push rejected | "Remote has changes you don't have. Pull first?" | Offer to pull + push |

### 2.2 NIF Errors

| Error | Cause | User Message | Recovery |
|---|---|---|---|
| Handle invalid | ResourceArc dropped or corrupted | (internal) Re-open repo | Auto-reopen |
| Lock poisoned | Mutex poisoned after panic | (internal) Restart repo worker | Supervisor restart |
| NIF panic | Bug in Rust code | "Internal error. This is a bug — please report it." | Log full details, restart worker |
| Parse failed | tree-sitter can't parse file | "Couldn't analyze {file} (unsupported syntax). Falling back to line-level diff." | Graceful degradation |

### 2.3 AI Errors

| Error | Cause | User Message | Recovery |
|---|---|---|---|
| API timeout | LLM provider slow/down | "AI is taking longer than expected. Still trying..." | Show spinner, auto-retry once |
| API error | Rate limit, auth, 500 | "AI service unavailable. Git operations still work." | Degrade gracefully — AI features off, git works |
| Stream interrupted | Connection dropped mid-stream | "Response was interrupted. {partial_response_shown}" | Show what we got, offer retry |
| Context too large | Diff too big for token budget | "This diff is too large for AI analysis ({size}). Showing file-level summary instead." | Truncate intelligently |
| Invalid response | LLM returned unparseable output | "Couldn't understand AI response. Retrying..." | Retry with simpler prompt |

### 2.4 Workspace Errors

| Error | Cause | User Message | Recovery |
|---|---|---|---|
| Path not found | Repo directory deleted/moved | "Repository at {path} no longer exists. Remove from workspace?" | Offer removal |
| Permission denied | Can't read .git | "Can't access {path}. Check permissions." | Show chmod suggestion |
| Not a git repo | Directory has no .git | "{path} is not a git repository. Skip?" | Remove from workspace |

---

## 3. Structured Error Type

```elixir
defmodule Valkka.Error do
  @type t :: %__MODULE__{
    code: atom(),
    message: String.t(),
    detail: String.t() | nil,
    suggestion: String.t() | nil,
    recoverable: boolean(),
    actions: [action()]
  }

  @type action :: %{
    label: String.t(),
    intent: Valkka.AI.Intent.t()
  }

  defstruct [:code, :message, :detail, :suggestion, recoverable: true, actions: []]
end
```

### Example Error Construction

```elixir
# Git dirty workdir error
%Valkka.Error{
  code: :dirty_workdir,
  message: "You have 3 uncommitted changes",
  detail: "Modified: lib/repo.ex, lib/ai.ex\nUntracked: scratch.txt",
  suggestion: "Commit or stash your changes first",
  recoverable: true,
  actions: [
    %{label: "Stash changes", intent: {:git_op, :stash, %{message: "auto-stash"}}},
    %{label: "Commit all", intent: {:ai_op, :generate_commit_msg, %{}}},
    %{label: "Discard changes", intent: {:git_op, :checkout_files, %{paths: ["."]}}}
  ]
}
```

### Rendering in Chat

```
  valkka: Can't switch to main — you have 3 uncommitted changes.

    Modified: lib/repo.ex, lib/ai.ex
    Untracked: scratch.txt

    [Stash changes] [Commit all] [Discard changes]
```

---

## 4. NIF Error Boundary

This is the most critical error handling in the system.

### Rust Side: Catch Everything

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
            // Log to file for debugging
            eprintln!("[VALKKA NIF ERROR] {}", msg);
            Err(msg)
        }
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn repo_open(path: String) -> Result<ResourceArc<RepoHandle>, String> {
    safe_nif(|| {
        let repo = git2::Repository::open(&path)
            .map_err(|e| format!("failed to open: {}", e))?;
        Ok(ResourceArc::new(RepoHandle {
            repo: Mutex::new(repo),
            path: PathBuf::from(path),
        }))
    })
}
```

### Elixir Side: Translate NIF Errors

```elixir
defmodule Valkka.Git.Commands do
  @moduledoc "High-level git commands. Translates NIF results to domain errors."

  alias Valkka.Git.Native
  alias Valkka.Error

  def checkout(handle, ref) do
    case Native.checkout(handle, ref) do
      :ok ->
        :ok

      {:error, reason} when is_binary(reason) ->
        cond do
          reason =~ "uncommitted changes" ->
            {:error, %Error{
              code: :dirty_workdir,
              message: "Can't switch branches with uncommitted changes",
              suggestion: "Commit or stash first",
              actions: [
                %{label: "Stash", intent: {:git_op, :stash, %{}}},
                %{label: "Force", intent: {:git_op, :checkout, %{ref: ref, force: true}}}
              ]
            }}

          reason =~ "not found" ->
            {:error, %Error{
              code: :ref_not_found,
              message: "Branch '#{ref}' not found",
              suggestion: suggest_similar_branch(handle, ref)
            }}

          true ->
            {:error, %Error{
              code: :git_error,
              message: reason,
              recoverable: false
            }}
        end
    end
  end
end
```

---

## 5. Supervision & Recovery

### Repo Worker Crash Recovery

```elixir
defmodule Valkka.Repo.Worker do
  use GenServer, restart: :transient

  def init(opts) do
    path = Keyword.fetch!(opts, :path)

    case Valkka.Git.Native.repo_open(path) do
      {:ok, handle} ->
        # Subscribe to file watcher
        Phoenix.PubSub.subscribe(Valkka.PubSub, "watcher:#{path}")
        {:ok, %{handle: handle, path: path, status: nil, error_count: 0}}

      {:error, reason} ->
        # Don't crash on init — report error state
        {:ok, %{handle: nil, path: path, status: :error, error: reason, error_count: 1},
         {:continue, :retry_open}}
    end
  end

  def handle_continue(:retry_open, %{error_count: count} = state) when count < 3 do
    Process.sleep(1000 * count)  # backoff
    case Valkka.Git.Native.repo_open(state.path) do
      {:ok, handle} ->
        {:noreply, %{state | handle: handle, status: nil, error_count: 0}}
      {:error, _} ->
        {:noreply, %{state | error_count: count + 1}, {:continue, :retry_open}}
    end
  end

  def handle_continue(:retry_open, state) do
    # Give up after 3 retries — broadcast error to UI
    Phoenix.PubSub.broadcast(Valkka.PubSub, "repo:#{state.path}", {:repo_error, state.error})
    {:noreply, state}
  end
end
```

### AI Stream Recovery

```elixir
defmodule Valkka.AI.StreamManager do
  def handle_cast({:request, repo_id, intent, opts}, state) do
    task = Task.async(fn ->
      case do_stream(repo_id, intent, opts) do
        {:ok, response} ->
          {:completed, response}

        {:error, :timeout} ->
          # Retry once with shorter context
          case do_stream(repo_id, intent, Keyword.put(opts, :max_context, :short)) do
            {:ok, response} -> {:completed, response}
            {:error, reason} -> {:failed, reason}
          end

        {:error, :stream_interrupted} ->
          # Publish what we have
          {:partial, state.partial_response}

        {:error, reason} ->
          {:failed, reason}
      end
    end)

    {:noreply, Map.put(state, :current_task, task)}
  end
end
```

---

## 6. Graceful Degradation

When subsystems fail, Valkka continues working with reduced functionality.

| Failed Subsystem | What Still Works | User Notification |
|---|---|---|
| AI provider down | All git operations, graph, status | "AI features temporarily unavailable. Git works normally." |
| File watcher crashed | Git operations (manual refresh) | "File watching paused. Use 'refresh' to update." |
| One repo worker crashed | All other repos | "Repository '{name}' encountered an error. Restarting..." |
| NIF library missing | Nothing (can't do git ops) | "Rust NIF not found. Run 'mix compile' to build." |
| Network down | All local operations | "Offline mode. Push/pull unavailable." |

### Implementation

```elixir
defmodule Valkka.HealthCheck do
  def status do
    %{
      nif: check_nif(),
      ai: check_ai_provider(),
      repos: check_repos(),
      watcher: check_watcher()
    }
  end

  defp check_nif do
    case Valkka.Git.Native.repo_open("/dev/null") do
      {:error, _} -> :ok  # Error is expected, but NIF loaded
    end
  rescue
    UndefinedFunctionError -> :unavailable
  end
end
```

---

## 7. Error Logging

### What to Log

| Level | What | Example |
|---|---|---|
| `:error` | NIF panics, supervision crashes | "NIF panic in repo_open: null pointer" |
| `:warning` | Recoverable errors, degradation | "AI provider timeout, retrying" |
| `:info` | User operations, state changes | "Repo opened: /path/to/repo" |
| `:debug` | NIF calls, PubSub messages | "NIF log called with limit=100" |

### What NOT to Log

- File contents or diffs (could contain secrets)
- AI API keys or tokens
- Full commit messages (might have sensitive info)
- User conversation content

### Structured Logging

```elixir
# Use Logger metadata for structured fields
Logger.error("NIF panic",
  module: :repo,
  function: :repo_open,
  path: path,
  error: sanitize(reason)
)
```
