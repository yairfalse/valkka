# Valkka: OTP Architecture

> Production-grade supervision, state machines, caching, and distribution.
> Every process justified. Every restart strategy explained.

---

## 1. Complete Supervision Tree

```
Valkka.Application (Application)
│
├── Valkka.PubSub (Phoenix.PubSub)
│   strategy: N/A (standalone worker)
│
├── Valkka.CacheSupervisor (Supervisor, one_for_one)
│   ├── Valkka.Cache.GraphCache      — ETS owner for :valkka_graph_cache
│   ├── Valkka.Cache.CommitCache     — ETS owner for :valkka_commit_cache
│   └── Valkka.Cache.StatusCache     — ETS owner for :valkka_status_cache
│
├── Valkka.NifTasks (Task.Supervisor)
│   max_children: 20
│
├── Valkka.Repo.Supervisor (DynamicSupervisor)
│   max_children: 50
│   ├── Valkka.Repo.WorkerSupervisor (Supervisor, rest_for_one) [per repo]
│   │   ├── Valkka.Repo.Worker (gen_statem)
│   │   └── Valkka.Watcher.Handler (GenServer)
│   ├── ... (repo 2)
│   └── ... (repo N)
│
├── Valkka.AI.Supervisor (Supervisor, one_for_one)
│   ├── Valkka.AI.StreamManager (GenServer)
│   ├── Valkka.AI.ContextBuilder (GenServer)
│   └── Valkka.AI.StreamTasks (Task.Supervisor)
│
├── Valkka.Workspace.Registry (Registry, keys: :unique)
│
├── Valkka.Sykli.StatusMonitor (GenServer)
│
├── Valkka.Kerto.Hooks (GenServer)
│
├── ValkkaWeb.Endpoint (Phoenix)
│
└── Valkka.Shutdown (GenServer, trap_exit)
    Handles SIGTERM graceful shutdown
```

### Restart Strategy Justification

| Supervisor | Strategy | Why |
|---|---|---|
| `Application` (top) | `one_for_one` | Children are independent subsystems. AI crashing does not affect repos. PubSub crashing does not affect caches. Isolate failures. |
| `CacheSupervisor` | `one_for_one` | Each ETS table owner is independent. Losing the graph cache does not invalidate the commit cache. They rebuild independently on restart. |
| `Repo.Supervisor` | DynamicSupervisor | Repos come and go at runtime. Each repo is started/stopped independently. One repo crash does not affect others. |
| `Repo.WorkerSupervisor` (per repo) | `rest_for_one` | Start order: Worker then Watcher. If the Worker dies, the Watcher must restart too (it depends on the Worker's handle). If the Watcher dies, the Worker survives (it just loses file events until the Watcher restarts). |
| `AI.Supervisor` | `one_for_one` | StreamManager and ContextBuilder are independent. StreamManager crashing drops in-flight AI requests (acceptable -- user retries). ContextBuilder crashing loses nothing (stateless between calls). |

### Child Spec Details

```elixir
defmodule Valkka.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Valkka.PubSub},
      Valkka.CacheSupervisor,
      {Task.Supervisor, name: Valkka.NifTasks, max_children: 20},
      {DynamicSupervisor, name: Valkka.Repo.Supervisor, strategy: :one_for_one, max_children: 50},
      Valkka.AI.Supervisor,
      {Registry, keys: :unique, name: Valkka.Workspace.Registry},
      Valkka.Sykli.StatusMonitor,
      Valkka.Kerto.Hooks,
      ValkkaWeb.Endpoint,
      Valkka.Shutdown
    ]

    opts = [strategy: :one_for_one, name: Valkka.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

```elixir
defmodule Valkka.CacheSupervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Valkka.Cache.GraphCache, []},
      {Valkka.Cache.CommitCache, []},
      {Valkka.Cache.StatusCache, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

---

## 2. Repo.Worker as gen_statem

### State Diagram

```
                  repo_open OK
  :initializing ──────────────→ :idle
       │                          │
       │ repo_open FAIL           │ {:execute, op}
       ▼                          ▼
    :error ←──── timeout ─── :operating
       │                      │       │
       │ :retry               │       │ merge conflict
       ▼                      │       ▼
  :initializing               │   :merging
                              │       │
                              │       │ rebase conflict
                              │       ▼
                              │   :rebasing
                              │       │
                              ├───────┘  (op complete / abort)
                              ▼
                           :idle
```

### State Definitions

| State | Meaning | Allowed Events |
|---|---|---|
| `:initializing` | Opening repo handle, reading initial status | Internal timeout, NIF result |
| `:idle` | Ready. No operation in flight. | `{:execute, op}`, `{:refresh, :file_change}`, `{:query, ...}` |
| `:operating` | Executing a single git command via NIF Task | Task result (`{ref, result}`), `:cancel` |
| `:merging` | In the middle of a merge with unresolved conflicts | `{:resolve, path, content}`, `:abort_merge`, `{:query, ...}` |
| `:rebasing` | In the middle of a rebase with unresolved conflicts | `{:rebase_continue}`, `{:rebase_skip}`, `:abort_rebase`, `{:query, ...}` |
| `:error` | Repo handle invalid or repo corrupted | `:retry`, `{:reopen, path}` |

### Data Structure

```elixir
defmodule Valkka.Repo.Worker do
  @behaviour :gen_statem

  defmodule Data do
    @enforce_keys [:repo_id, :path]
    defstruct [
      :repo_id,
      :path,
      :handle,
      :status,
      :current_task,
      :pending_op,
      :conflict_files,
      error_count: 0,
      last_error: nil
    ]
  end

  # --- Public API ---

  def start_link(opts) do
    repo_id = Keyword.fetch!(opts, :repo_id)
    path = Keyword.fetch!(opts, :path)
    :gen_statem.start_link({:via, Registry, {Valkka.Workspace.Registry, repo_id}},
      __MODULE__, opts, [])
  end

  @spec execute(GenServer.server(), term()) :: {:ok, term()} | {:error, term()}
  def execute(worker, operation) do
    :gen_statem.call(worker, {:execute, operation})
  end

  @spec query(GenServer.server(), term()) :: {:ok, term()} | {:error, term()}
  def query(worker, query) do
    :gen_statem.call(worker, {:query, query})
  end

  @spec status(GenServer.server()) :: map()
  def status(worker) do
    :gen_statem.call(worker, :status)
  end

  @spec abort(GenServer.server()) :: :ok | {:error, term()}
  def abort(worker) do
    :gen_statem.call(worker, :abort)
  end

  @spec cancel(GenServer.server()) :: :ok
  def cancel(worker) do
    :gen_statem.cast(worker, :cancel)
  end

  # --- Callbacks ---

  @impl true
  def callback_mode, do: [:state_functions, :state_enter]

  @impl true
  def init(opts) do
    repo_id = Keyword.fetch!(opts, :repo_id)
    path = Keyword.fetch!(opts, :path)
    Process.flag(:trap_exit, true)

    data = %Data{repo_id: repo_id, path: path}
    {:ok, :initializing, data, [{:state_timeout, 0, :open_repo}]}
  end

  # ------------------------------------------------------------------
  # STATE: :initializing
  # ------------------------------------------------------------------

  def initializing(:enter, _old_state, data) do
    :keep_state_and_data
  end

  def initializing(:state_timeout, :open_repo, data) do
    task = Task.Supervisor.async_nolink(Valkka.NifTasks, fn ->
      with {:ok, handle} <- Valkka.Git.Native.repo_open(data.path),
           {:ok, status} <- Valkka.Git.Native.repo_info(handle) do
        {:ok, handle, status}
      end
    end)

    {:keep_state, %{data | current_task: task}}
  end

  def initializing(:info, {ref, {:ok, handle, status}}, %{current_task: %{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    new_data = %{data |
      handle: handle,
      status: translate_status(status),
      current_task: nil,
      error_count: 0,
      last_error: nil
    }

    # Register in :pg for distributed discovery
    :pg.join(Valkka.PG, {:repo, data.repo_id}, self())

    broadcast(data.repo_id, {:repo_opened, new_data.status})
    {:next_state, :idle, new_data}
  end

  def initializing(:info, {ref, {:error, reason}}, %{current_task: %{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    new_data = %{data |
      current_task: nil,
      error_count: data.error_count + 1,
      last_error: reason
    }

    {:next_state, :error, new_data}
  end

  # Task crashed
  def initializing(:info, {:DOWN, ref, :process, _pid, reason}, %{current_task: %{ref: ref}} = data) do
    new_data = %{data |
      current_task: nil,
      error_count: data.error_count + 1,
      last_error: {:task_crash, reason}
    }

    {:next_state, :error, new_data}
  end

  # Reject operations while initializing
  def initializing({:call, from}, {:execute, _op}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :initializing}}]}
  end

  def initializing({:call, from}, {:query, _q}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :initializing}}]}
  end

  def initializing({:call, from}, :status, data) do
    {:keep_state_and_data, [{:reply, from, %{state: :initializing, path: data.path}}]}
  end

  # ------------------------------------------------------------------
  # STATE: :idle
  # ------------------------------------------------------------------

  def idle(:enter, _old_state, data) do
    # Refresh status on every transition to idle
    broadcast(data.repo_id, {:repo_status, data.status})
    :keep_state_and_data
  end

  def idle({:call, from}, {:execute, operation}, data) when data.handle != nil do
    handle = data.handle
    task = Task.Supervisor.async_nolink(Valkka.NifTasks, fn ->
      execute_operation(handle, operation)
    end)

    new_data = %{data | current_task: task, pending_op: {from, operation}}
    {:next_state, :operating, new_data}
  end

  def idle({:call, from}, {:execute, _operation}, %{handle: nil}) do
    {:keep_state_and_data, [{:reply, from, {:error, :no_handle}}]}
  end

  def idle({:call, from}, {:query, query}, data) do
    # Queries run synchronously via Task to avoid blocking the statem
    result = Task.Supervisor.async_nolink(Valkka.NifTasks, fn ->
      execute_query(data.handle, query)
    end)
    |> Task.await(30_000)

    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def idle({:call, from}, :status, data) do
    reply = %{state: :idle, path: data.path, status: data.status}
    {:keep_state_and_data, [{:reply, from, reply}]}
  end

  def idle(:info, {:file_changed, _paths}, data) do
    # Debounced file change event from Watcher.Handler
    # Refresh status without blocking
    handle = data.handle
    Task.Supervisor.async_nolink(Valkka.NifTasks, fn ->
      {:refresh_result, Valkka.Git.Native.repo_info(handle)}
    end)

    :keep_state_and_data
  end

  def idle(:info, {ref, {:refresh_result, {:ok, status}}}, data) do
    Process.demonitor(ref, [:flush])
    new_status = translate_status(status)

    # Invalidate caches
    Valkka.Cache.StatusCache.invalidate(data.repo_id)

    # Only broadcast if status actually changed
    if new_status != data.status do
      broadcast(data.repo_id, {:repo_status, new_status})
    end

    {:keep_state, %{data | status: new_status}}
  end

  def idle(:info, {ref, {:refresh_result, {:error, _reason}}}, _data) do
    Process.demonitor(ref, [:flush])
    :keep_state_and_data
  end

  def idle(:info, {:DOWN, _ref, :process, _pid, _reason}, _data) do
    # Background refresh task crashed -- ignore
    :keep_state_and_data
  end

  # ------------------------------------------------------------------
  # STATE: :operating
  # ------------------------------------------------------------------

  def operating(:enter, _old_state, data) do
    broadcast(data.repo_id, {:repo_operating, data.pending_op |> elem(1)})
    # Timeout: if a NIF task takes > 60s, something is wrong
    {:keep_state_and_data, [{:state_timeout, 60_000, :operation_timeout}]}
  end

  def operating(:info, {ref, result}, %{current_task: %{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    {from, operation} = data.pending_op

    case classify_result(result, operation) do
      {:ok, value} ->
        # Operation succeeded -- refresh status and return to idle
        new_data = %{data | current_task: nil, pending_op: nil}
        new_data = refresh_status_sync(new_data)
        invalidate_caches(data.repo_id, operation)
        broadcast(data.repo_id, {:operation_complete, operation, value})
        {:next_state, :idle, new_data, [{:reply, from, {:ok, value}}]}

      {:conflict, :merge, conflict_files} ->
        new_data = %{data |
          current_task: nil,
          pending_op: nil,
          conflict_files: conflict_files
        }
        broadcast(data.repo_id, {:merge_conflict, conflict_files})
        {:next_state, :merging, new_data, [{:reply, from, {:conflict, conflict_files}}]}

      {:conflict, :rebase, conflict_info} ->
        new_data = %{data |
          current_task: nil,
          pending_op: nil,
          conflict_files: conflict_info.files
        }
        broadcast(data.repo_id, {:rebase_conflict, conflict_info})
        {:next_state, :rebasing, new_data, [{:reply, from, {:conflict, conflict_info}}]}

      {:error, reason} ->
        new_data = %{data | current_task: nil, pending_op: nil}
        broadcast(data.repo_id, {:operation_failed, operation, reason})
        {:next_state, :idle, new_data, [{:reply, from, {:error, reason}}]}
    end
  end

  # Task crashed
  def operating(:info, {:DOWN, ref, :process, _pid, reason}, %{current_task: %{ref: ref}} = data) do
    {from, _operation} = data.pending_op
    new_data = %{data | current_task: nil, pending_op: nil}
    {:next_state, :idle, new_data, [{:reply, from, {:error, {:task_crash, reason}}}]}
  end

  def operating(:state_timeout, :operation_timeout, data) do
    # Kill the task
    if data.current_task, do: Task.shutdown(data.current_task, :brutal_kill)
    {from, _operation} = data.pending_op
    new_data = %{data | current_task: nil, pending_op: nil}
    {:next_state, :idle, new_data, [{:reply, from, {:error, :timeout}}]}
  end

  def operating(:cast, :cancel, data) do
    if data.current_task, do: Task.shutdown(data.current_task, :brutal_kill)
    {from, _operation} = data.pending_op
    new_data = %{data | current_task: nil, pending_op: nil}
    {:next_state, :idle, new_data, [{:reply, from, {:error, :cancelled}}]}
  end

  # Reject new operations while operating
  def operating({:call, from}, {:execute, _op}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :busy}}]}
  end

  # Queries are still allowed while operating (reads don't conflict)
  def operating({:call, from}, {:query, query}, data) do
    result = Task.Supervisor.async_nolink(Valkka.NifTasks, fn ->
      execute_query(data.handle, query)
    end)
    |> Task.await(30_000)

    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def operating({:call, from}, :status, data) do
    {_, op} = data.pending_op
    {:keep_state_and_data, [{:reply, from, %{state: :operating, operation: op}}]}
  end

  # ------------------------------------------------------------------
  # STATE: :merging
  # ------------------------------------------------------------------

  def merging(:enter, _old_state, _data) do
    :keep_state_and_data
  end

  def merging({:call, from}, {:execute, {:resolve_conflict, path, content}}, data) do
    handle = data.handle
    task = Task.Supervisor.async_nolink(Valkka.NifTasks, fn ->
      Valkka.Git.Native.resolve_conflict(handle, path, content)
    end)

    new_data = %{data | current_task: task, pending_op: {from, {:resolve_conflict, path}}}
    {:next_state, :operating, new_data}
  end

  def merging({:call, from}, {:execute, :finalize_merge}, data) do
    handle = data.handle
    task = Task.Supervisor.async_nolink(Valkka.NifTasks, fn ->
      Valkka.Git.Native.finalize_merge(handle)
    end)

    new_data = %{data | current_task: task, pending_op: {from, :finalize_merge}}
    {:next_state, :operating, new_data}
  end

  def merging({:call, from}, :abort, data) do
    handle = data.handle
    task = Task.Supervisor.async_nolink(Valkka.NifTasks, fn ->
      Valkka.Git.Native.abort_merge(handle)
    end)

    new_data = %{data |
      current_task: task,
      pending_op: {from, :abort_merge},
      conflict_files: nil
    }

    {:next_state, :operating, new_data}
  end

  def merging({:call, from}, {:query, query}, data) do
    result = Task.Supervisor.async_nolink(Valkka.NifTasks, fn ->
      execute_query(data.handle, query)
    end)
    |> Task.await(30_000)

    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def merging({:call, from}, {:execute, _other}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :merge_in_progress}}]}
  end

  def merging({:call, from}, :status, data) do
    reply = %{state: :merging, conflict_files: data.conflict_files, path: data.path}
    {:keep_state_and_data, [{:reply, from, reply}]}
  end

  # ------------------------------------------------------------------
  # STATE: :rebasing
  # ------------------------------------------------------------------

  def rebasing(:enter, _old_state, _data) do
    :keep_state_and_data
  end

  def rebasing({:call, from}, {:execute, :rebase_continue}, data) do
    handle = data.handle
    task = Task.Supervisor.async_nolink(Valkka.NifTasks, fn ->
      Valkka.Git.Native.rebase_continue(handle)
    end)

    new_data = %{data | current_task: task, pending_op: {from, :rebase_continue}}
    {:next_state, :operating, new_data}
  end

  def rebasing({:call, from}, {:execute, :rebase_skip}, data) do
    handle = data.handle
    task = Task.Supervisor.async_nolink(Valkka.NifTasks, fn ->
      Valkka.Git.Native.rebase_skip(handle)
    end)

    new_data = %{data | current_task: task, pending_op: {from, :rebase_skip}}
    {:next_state, :operating, new_data}
  end

  def rebasing({:call, from}, :abort, data) do
    handle = data.handle
    task = Task.Supervisor.async_nolink(Valkka.NifTasks, fn ->
      Valkka.Git.Native.abort_rebase(handle)
    end)

    new_data = %{data |
      current_task: task,
      pending_op: {from, :abort_rebase},
      conflict_files: nil
    }

    {:next_state, :operating, new_data}
  end

  def rebasing({:call, from}, {:query, query}, data) do
    result = Task.Supervisor.async_nolink(Valkka.NifTasks, fn ->
      execute_query(data.handle, query)
    end)
    |> Task.await(30_000)

    {:keep_state_and_data, [{:reply, from, result}]}
  end

  def rebasing({:call, from}, {:execute, _other}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :rebase_in_progress}}]}
  end

  def rebasing({:call, from}, :status, data) do
    reply = %{state: :rebasing, conflict_files: data.conflict_files, path: data.path}
    {:keep_state_and_data, [{:reply, from, reply}]}
  end

  # ------------------------------------------------------------------
  # STATE: :error
  # ------------------------------------------------------------------

  def error(:enter, _old_state, data) do
    broadcast(data.repo_id, {:repo_error, data.last_error})

    # Auto-retry with exponential backoff, max 3 attempts
    if data.error_count <= 3 do
      delay = :timer.seconds(data.error_count * 2)
      {:keep_state_and_data, [{:state_timeout, delay, :retry}]}
    else
      :keep_state_and_data
    end
  end

  def error(:state_timeout, :retry, data) do
    {:next_state, :initializing, %{data | current_task: nil},
     [{:state_timeout, 0, :open_repo}]}
  end

  def error({:call, from}, :retry, data) do
    {:next_state, :initializing, %{data | error_count: 0, current_task: nil},
     [{:reply, from, :ok}, {:state_timeout, 0, :open_repo}]}
  end

  def error({:call, from}, {:execute, _op}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :repo_error}}]}
  end

  def error({:call, from}, {:query, _q}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :repo_error}}]}
  end

  def error({:call, from}, :status, data) do
    reply = %{state: :error, path: data.path, error: data.last_error,
              error_count: data.error_count}
    {:keep_state_and_data, [{:reply, from, reply}]}
  end

  # ------------------------------------------------------------------
  # Terminate (graceful shutdown)
  # ------------------------------------------------------------------

  @impl true
  def terminate(reason, _state, data) do
    if data.current_task do
      Task.shutdown(data.current_task, 5_000)
    end

    if data.handle do
      Valkka.Git.Native.repo_close(data.handle)
    end

    :pg.leave(Valkka.PG, {:repo, data.repo_id}, self())

    Logger.info("Repo.Worker terminated",
      repo_id: data.repo_id, reason: inspect(reason))

    :ok
  end

  # ------------------------------------------------------------------
  # Private helpers
  # ------------------------------------------------------------------

  defp execute_operation(handle, {:commit, message, opts}) do
    Valkka.Git.Native.commit(handle, message, opts)
  end

  defp execute_operation(handle, {:stage, paths}) do
    Valkka.Git.Native.stage(handle, paths)
  end

  defp execute_operation(handle, {:unstage, paths}) do
    Valkka.Git.Native.unstage(handle, paths)
  end

  defp execute_operation(handle, {:checkout, ref}) do
    Valkka.Git.Native.checkout(handle, ref)
  end

  defp execute_operation(handle, {:merge, source}) do
    Valkka.Git.Native.merge(handle, source)
  end

  defp execute_operation(handle, {:rebase, opts}) do
    Valkka.Git.Native.rebase(handle, opts)
  end

  defp execute_operation(handle, {:diff, from, to}) do
    Valkka.Git.Native.diff(handle, from, to)
  end

  defp execute_operation(handle, {:semantic_diff, from, to}) do
    Valkka.Git.Native.semantic_diff(handle, from, to)
  end

  defp execute_operation(handle, {:push, remote, branch, opts}) do
    Valkka.Git.Native.push(handle, remote, branch, opts)
  end

  defp execute_operation(handle, {:cherry_pick, oid}) do
    Valkka.Git.Native.cherry_pick(handle, oid)
  end

  defp execute_operation(handle, {:squash, count, message}) do
    Valkka.Git.Native.squash(handle, count, message)
  end

  defp execute_operation(handle, {:stash, message}) do
    Valkka.Git.Native.stash(handle, message)
  end

  defp execute_operation(handle, :stash_pop) do
    Valkka.Git.Native.stash_pop(handle)
  end

  defp execute_operation(_handle, op) do
    {:error, {:unknown_operation, op}}
  end

  defp execute_query(handle, {:log, opts}), do: Valkka.Git.Native.log(handle, opts)
  defp execute_query(handle, :branches), do: Valkka.Git.Native.branches(handle)
  defp execute_query(handle, {:blame, path}), do: Valkka.Git.Native.blame(handle, path)
  defp execute_query(handle, {:file_history, path, opts}), do: Valkka.Git.Native.file_history(handle, path, opts)
  defp execute_query(handle, {:commit_detail, oid}), do: Valkka.Git.Native.commit_detail(handle, oid)
  defp execute_query(handle, {:compute_graph, opts}), do: Valkka.Git.Native.compute_graph(handle, opts)
  defp execute_query(handle, {:search_commits, query, opts}), do: Valkka.Git.Native.search_commits(handle, query, opts)
  defp execute_query(handle, :info), do: Valkka.Git.Native.repo_info(handle)
  defp execute_query(_handle, query), do: {:error, {:unknown_query, query}}

  defp classify_result({:ok, %{type: "conflict", conflicts: files}}, {:merge, _}) do
    {:conflict, :merge, files}
  end

  defp classify_result({:ok, %{type: "conflict"} = info}, {:rebase, _}) do
    {:conflict, :rebase, info}
  end

  defp classify_result({:ok, value}, _op), do: {:ok, value}
  defp classify_result(:ok, _op), do: {:ok, :ok}
  defp classify_result({:error, reason}, _op), do: {:error, reason}

  defp refresh_status_sync(data) do
    case Valkka.Git.Native.repo_info(data.handle) do
      {:ok, status} -> %{data | status: translate_status(status)}
      {:error, _} -> data
    end
  end

  defp translate_status(raw) do
    %{
      head: raw.head,
      branch: raw.branch,
      state: String.to_existing_atom(raw.state),
      staged: raw.staged,
      unstaged: raw.unstaged,
      untracked: raw.untracked,
      ahead: raw.ahead,
      behind: raw.behind
    }
  end

  defp invalidate_caches(repo_id, _operation) do
    Valkka.Cache.StatusCache.invalidate(repo_id)
    Valkka.Cache.GraphCache.invalidate(repo_id)
    # Commit cache entries are immutable by OID, no invalidation needed
  end

  defp broadcast(repo_id, message) do
    Phoenix.PubSub.broadcast(Valkka.PubSub, "repo:#{repo_id}:status", message)
  end
end
```

### State Transition Summary

| From | Event | Guard | To | Side Effects |
|---|---|---|---|---|
| `:initializing` | NIF result OK | -- | `:idle` | Join :pg, broadcast |
| `:initializing` | NIF result error | -- | `:error` | Increment error_count |
| `:idle` | `{:execute, op}` | `handle != nil` | `:operating` | Spawn NIF Task |
| `:idle` | `{:file_changed, _}` | -- | `:idle` | Refresh status in background |
| `:operating` | Task result OK | -- | `:idle` | Reply to caller, invalidate caches |
| `:operating` | Task result merge conflict | -- | `:merging` | Reply with conflict info |
| `:operating` | Task result rebase conflict | -- | `:rebasing` | Reply with conflict info |
| `:operating` | Task result error | -- | `:idle` | Reply with error |
| `:operating` | `:cancel` | -- | `:idle` | Kill task, reply cancelled |
| `:operating` | state_timeout (60s) | -- | `:idle` | Kill task, reply timeout |
| `:merging` | `{:execute, {:resolve_conflict, ...}}` | -- | `:operating` | Spawn resolve Task |
| `:merging` | `:abort` | -- | `:operating` | Spawn abort_merge Task |
| `:rebasing` | `{:execute, :rebase_continue}` | -- | `:operating` | Spawn continue Task |
| `:rebasing` | `{:execute, :rebase_skip}` | -- | `:operating` | Spawn skip Task |
| `:rebasing` | `:abort` | -- | `:operating` | Spawn abort_rebase Task |
| `:error` | state_timeout (backoff) | `error_count <= 3` | `:initializing` | Auto-retry |
| `:error` | `:retry` (manual) | -- | `:initializing` | Reset error_count |

---

## 3. NIF Call Pattern

NIFs must never execute in the gen_statem process. A blocking NIF would freeze the entire state machine, preventing it from handling cancellation, timeouts, or status queries. Every NIF call goes through `Task.Supervisor`.

### The Pattern

```elixir
# WRONG -- blocks the statem process:
def idle({:call, from}, {:execute, {:diff, from_ref, to_ref}}, data) do
  result = Valkka.Git.Native.diff(data.handle, from_ref, to_ref)  # BLOCKS
  {:keep_state_and_data, [{:reply, from, result}]}
end

# RIGHT -- delegates to Task.Supervisor:
def idle({:call, from}, {:execute, {:diff, from_ref, to_ref}}, data) do
  handle = data.handle
  task = Task.Supervisor.async_nolink(Valkka.NifTasks, fn ->
    Valkka.Git.Native.diff(handle, from_ref, to_ref)
  end)

  new_data = %{data | current_task: task, pending_op: {from, {:diff, from_ref, to_ref}}}
  {:next_state, :operating, new_data}
end
```

### Why `async_nolink`

- `async` links the task to the caller. If the task crashes, the statem crashes.
- `async_nolink` monitors the task. If the task crashes, we get a `{:DOWN, ...}` message instead of dying. The statem handles it gracefully and transitions to a safe state.

### Task.Supervisor Configuration

```elixir
# In Application children:
{Task.Supervisor,
  name: Valkka.NifTasks,
  max_children: 20       # Prevent runaway task creation
}
```

The `max_children: 20` limit prevents pathological scenarios where many repos attempt simultaneous NIF operations. If the limit is hit, `Task.Supervisor.async_nolink/2` raises, which the statem should catch and return `{:error, :overloaded}`.

### Read Queries in :operating State

While a mutating operation is in flight, read queries are still served. They spawn separate tasks and await inline (the Mutex in the Rust RepoHandle serializes access at the NIF level):

```elixir
def operating({:call, from}, {:query, query}, data) do
  # This is safe: the Mutex in RepoHandle serializes NIF access.
  # The query will block until the in-flight operation finishes its
  # NIF call, then execute. But the statem process itself is not blocked.
  result = Task.Supervisor.async_nolink(Valkka.NifTasks, fn ->
    execute_query(data.handle, query)
  end)
  |> Task.await(30_000)

  {:keep_state_and_data, [{:reply, from, result}]}
end
```

---

## 4. ETS Caching Strategy

### Table Definitions

```elixir
defmodule Valkka.Cache.GraphCache do
  use GenServer

  @table :valkka_graph_cache

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [
      :named_table,
      :set,
      :public,                    # Any process can read
      read_concurrency: true,     # Optimized for concurrent reads
      write_concurrency: false    # Writes are rare (invalidation + refill)
    ])

    {:ok, %{table: table}}
  end

  @spec get(String.t(), map()) :: {:ok, term()} | :miss
  def get(repo_id, opts) do
    key = {repo_id, :erlang.phash2(opts)}
    case :ets.lookup(@table, key) do
      [{^key, value, inserted_at}] ->
        if System.monotonic_time(:millisecond) - inserted_at < ttl() do
          {:ok, value}
        else
          :ets.delete(@table, key)
          :miss
        end

      [] ->
        :miss
    end
  end

  @spec put(String.t(), map(), term()) :: :ok
  def put(repo_id, opts, value) do
    key = {repo_id, :erlang.phash2(opts)}
    :ets.insert(@table, {key, value, System.monotonic_time(:millisecond)})
    :ok
  end

  @spec invalidate(String.t()) :: :ok
  def invalidate(repo_id) do
    # Delete all entries for this repo using match_delete
    :ets.match_delete(@table, {{repo_id, :_}, :_, :_})
    :ok
  end

  @spec invalidate_all() :: :ok
  def invalidate_all do
    :ets.delete_all_objects(@table)
    :ok
  end

  defp ttl, do: :timer.minutes(5)
end
```

```elixir
defmodule Valkka.Cache.CommitCache do
  use GenServer

  @table :valkka_commit_cache

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :set,
      :public,
      read_concurrency: true,
      write_concurrency: true    # Commits are immutable, safe to write concurrently
    ])

    {:ok, %{}}
  end

  @doc """
  Commit data keyed by OID. Commits are immutable -- once stored, never invalidated.
  This cache only grows. Periodically prune entries older than 1 hour to bound memory.
  """
  @spec get(String.t()) :: {:ok, map()} | :miss
  def get(oid) do
    case :ets.lookup(@table, oid) do
      [{^oid, value}] -> {:ok, value}
      [] -> :miss
    end
  end

  @spec put(String.t(), map()) :: :ok
  def put(oid, commit_data) do
    :ets.insert(@table, {oid, commit_data})
    :ok
  end

  @spec size() :: non_neg_integer()
  def size, do: :ets.info(@table, :size)
end
```

```elixir
defmodule Valkka.Cache.StatusCache do
  use GenServer

  @table :valkka_status_cache

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [
      :named_table,
      :set,
      :public,
      read_concurrency: true,
      write_concurrency: false
    ])

    {:ok, %{}}
  end

  @spec get(String.t()) :: {:ok, map()} | :miss
  def get(repo_id) do
    case :ets.lookup(@table, repo_id) do
      [{^repo_id, status, ts}] ->
        # Status is valid for 1 second max (file watcher invalidates sooner)
        if System.monotonic_time(:millisecond) - ts < 1_000 do
          {:ok, status}
        else
          :ets.delete(@table, repo_id)
          :miss
        end

      [] ->
        :miss
    end
  end

  @spec put(String.t(), map()) :: :ok
  def put(repo_id, status) do
    :ets.insert(@table, {repo_id, status, System.monotonic_time(:millisecond)})
    :ok
  end

  @spec invalidate(String.t()) :: :ok
  def invalidate(repo_id) do
    :ets.delete(@table, repo_id)
    :ok
  end

  @spec flush_to_disk(Path.t()) :: :ok
  def flush_to_disk(path) do
    data = :ets.tab2list(@table)
    binary = :erlang.term_to_binary(data)
    File.write!(path, binary)
    :ok
  end
end
```

### Cache Invalidation Flow

```
File change on disk
  → Watcher.Handler receives FSEvents
    → Debounce (100ms, see section 6)
      → Broadcast {:file_changed, paths} to Repo.Worker
        → Worker calls:
           StatusCache.invalidate(repo_id)     # always
           GraphCache.invalidate(repo_id)      # always (graph may have changed)
           # CommitCache is NOT invalidated (commits are immutable by OID)
        → Worker refreshes status via NIF
          → Stores new status in StatusCache
```

### Why `read_concurrency: true` Everywhere

All three tables are read-heavy. LiveView processes read status and graph data on every render. NIF tasks read commit data to check cache before calling into Rust. Writes happen only on file change events or operation completion. The `read_concurrency` flag uses per-scheduler read locks that eliminate contention for concurrent reads.

---

## 5. AI Streaming with Backpressure

### Architecture

```
AI Provider API
  │
  │ HTTP stream (SSE / chunked)
  │
  ▼
Valkka.AI.StreamSession (GenServer, one per active stream)
  │
  │ GenStage demand-driven
  │
  ▼
Valkka.AI.StreamBuffer (GenStage producer)
  │
  │ PubSub broadcast (filtered by subscription)
  │
  ▼
LiveView consumer (handle_info)
```

### StreamSession (Producer)

```elixir
defmodule Valkka.AI.StreamSession do
  use GenServer

  @max_buffer 500          # Max chunks buffered before applying backpressure
  @flush_interval 50       # ms between flushes to PubSub

  defstruct [
    :session_id,
    :repo_id,
    :topic,
    :provider,
    :http_ref,
    buffer: :queue.new(),
    buffer_size: 0,
    consumers: MapSet.new(),
    status: :streaming
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    repo_id = Keyword.fetch!(opts, :repo_id)
    prompt = Keyword.fetch!(opts, :prompt)
    provider = Keyword.get(opts, :provider, Valkka.AI.Providers.Anthropic)

    topic = "repo:#{repo_id}:ai:#{session_id}"

    # Track LiveView consumers via PubSub presence
    Phoenix.PubSub.subscribe(Valkka.PubSub, "#{topic}:control")

    # Start the HTTP stream to the AI provider
    {:ok, http_ref} = provider.stream_start(prompt)

    # Schedule periodic buffer flush
    schedule_flush()

    state = %__MODULE__{
      session_id: session_id,
      repo_id: repo_id,
      topic: topic,
      provider: provider,
      http_ref: http_ref
    }

    {:ok, state}
  end

  # Incoming chunk from AI provider
  @impl true
  def handle_info({:ai_chunk, chunk}, state) do
    if state.buffer_size >= @max_buffer do
      # Backpressure: pause the HTTP stream
      state.provider.stream_pause(state.http_ref)
      # Buffer the chunk anyway (we are at capacity, will resume on flush)
      new_buffer = :queue.in(chunk, state.buffer)
      {:noreply, %{state | buffer: new_buffer, buffer_size: state.buffer_size + 1}}
    else
      new_buffer = :queue.in(chunk, state.buffer)
      {:noreply, %{state | buffer: new_buffer, buffer_size: state.buffer_size + 1}}
    end
  end

  # AI stream completed
  def handle_info({:ai_done, final_response}, state) do
    # Flush remaining buffer
    flush_buffer(state)

    Phoenix.PubSub.broadcast(Valkka.PubSub, state.topic, {:ai_complete, final_response})
    {:stop, :normal, state}
  end

  # AI stream error
  def handle_info({:ai_error, reason}, state) do
    Phoenix.PubSub.broadcast(Valkka.PubSub, state.topic, {:ai_error, reason})
    {:stop, :normal, state}
  end

  # Periodic flush
  def handle_info(:flush, state) do
    state = flush_buffer(state)

    # Resume HTTP stream if we drained the buffer below threshold
    if state.buffer_size < @max_buffer / 2 do
      state.provider.stream_resume(state.http_ref)
    end

    schedule_flush()
    {:noreply, state}
  end

  # LiveView disconnected -- check if any consumers remain
  def handle_info({:consumer_down, _pid}, state) do
    new_consumers = MapSet.delete(state.consumers, _pid)

    if MapSet.size(new_consumers) == 0 do
      # No consumers left -- cancel the AI stream, discard buffer
      state.provider.stream_cancel(state.http_ref)
      {:stop, :normal, %{state | consumers: new_consumers}}
    else
      {:noreply, %{state | consumers: new_consumers}}
    end
  end

  defp flush_buffer(state) do
    {chunks, new_buffer} = drain_queue(state.buffer, [])

    if chunks != [] do
      # Batch broadcast -- single PubSub message with all chunks
      Phoenix.PubSub.broadcast(Valkka.PubSub, state.topic, {:ai_chunks, chunks})
    end

    %{state | buffer: new_buffer, buffer_size: 0}
  end

  defp drain_queue(queue, acc) do
    case :queue.out(queue) do
      {{:value, item}, rest} -> drain_queue(rest, [item | acc])
      {:empty, queue} -> {Enum.reverse(acc), queue}
    end
  end

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval)
  end
end
```

### LiveView Consumer

```elixir
defmodule ValkkaWeb.AIComponent do
  use ValkkaWeb, :live_component

  def mount(socket) do
    {:ok, assign(socket, ai_text: "", streaming: false)}
  end

  def handle_event("ask_ai", %{"prompt" => prompt}, socket) do
    session_id = Ecto.UUID.generate()
    repo_id = socket.assigns.repo_id
    topic = "repo:#{repo_id}:ai:#{session_id}"

    # Subscribe to AI stream
    Phoenix.PubSub.subscribe(Valkka.PubSub, topic)

    # Start the stream
    {:ok, _pid} = Valkka.AI.StreamManager.start_stream(
      session_id: session_id,
      repo_id: repo_id,
      prompt: prompt
    )

    {:noreply, assign(socket, streaming: true, ai_text: "", session_id: session_id)}
  end

  def handle_info({:ai_chunks, chunks}, socket) do
    new_text = socket.assigns.ai_text <> Enum.join(chunks)
    {:noreply, assign(socket, ai_text: new_text)}
  end

  def handle_info({:ai_complete, _response}, socket) do
    {:noreply, assign(socket, streaming: false)}
  end

  def handle_info({:ai_error, reason}, socket) do
    {:noreply, assign(socket, streaming: false, ai_error: reason)}
  end
end
```

### Backpressure Summary

| Condition | Action |
|---|---|
| AI streams faster than consumers read | Buffer fills up, HTTP stream paused |
| Buffer drains below 50% capacity | HTTP stream resumed |
| All LiveView consumers disconnect | AI stream cancelled, buffer discarded |
| AI provider errors | Error broadcast, session stops |
| AI provider hangs | Session GenServer has a timeout (configurable, default 120s) |

---

## 6. File Watcher Debouncing

### The Problem

A single `Cmd+S` in an editor can generate 3-5 FSEvents (write, chmod, rename-swap). A `git checkout` can generate hundreds. Without debouncing, every event triggers a NIF call to refresh status -- wasting CPU and flooding PubSub.

### Implementation

```elixir
defmodule Valkka.Watcher.Handler do
  use GenServer

  @debounce_ms 100

  defstruct [
    :repo_id,
    :path,
    :watcher_pid,
    :debounce_timer,
    pending_paths: MapSet.new()
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    repo_id = Keyword.fetch!(opts, :repo_id)
    path = Keyword.fetch!(opts, :path)

    {:ok, watcher_pid} = FileSystem.start_link(dirs: [path])
    FileSystem.subscribe(watcher_pid)

    state = %__MODULE__{
      repo_id: repo_id,
      path: path,
      watcher_pid: watcher_pid
    }

    {:ok, state}
  end

  @impl true
  def handle_info({:file_event, _watcher, {file_path, _events}}, state) do
    # Skip .git internal churn (pack files, loose objects, etc.)
    if skip_path?(file_path, state.path) do
      {:noreply, state}
    else
      new_pending = MapSet.put(state.pending_paths, file_path)

      # Cancel existing timer, start a new one
      if state.debounce_timer do
        Process.cancel_timer(state.debounce_timer)
      end

      timer = Process.send_after(self(), :flush_changes, @debounce_ms)

      {:noreply, %{state | pending_paths: new_pending, debounce_timer: timer}}
    end
  end

  def handle_info(:flush_changes, state) do
    paths = MapSet.to_list(state.pending_paths)

    if paths != [] do
      # Notify the Repo.Worker about the batch of changes
      case Registry.lookup(Valkka.Workspace.Registry, state.repo_id) do
        [{pid, _}] ->
          send(pid, {:file_changed, paths})
        [] ->
          :ok
      end

      # Broadcast for any other subscribers (LiveView, Sykli monitor)
      Phoenix.PubSub.broadcast(
        Valkka.PubSub,
        "repo:#{state.repo_id}:status",
        {:files_changed, paths}
      )
    end

    {:noreply, %{state | pending_paths: MapSet.new(), debounce_timer: nil}}
  end

  def handle_info({:file_event, _watcher, :stop}, state) do
    # Watcher stopped -- restart it
    {:ok, watcher_pid} = FileSystem.start_link(dirs: [state.path])
    FileSystem.subscribe(watcher_pid)
    {:noreply, %{state | watcher_pid: watcher_pid}}
  end

  @impl true
  def terminate(_reason, state) do
    if state.watcher_pid && Process.alive?(state.watcher_pid) do
      GenServer.stop(state.watcher_pid)
    end
    :ok
  end

  # Skip internal .git files that change constantly during operations
  defp skip_path?(file_path, repo_path) do
    relative = Path.relative_to(file_path, repo_path)

    cond do
      # Allow .git/HEAD, .git/refs -- these indicate real state changes
      relative == ".git/HEAD" -> false
      String.starts_with?(relative, ".git/refs/") -> false
      String.starts_with?(relative, ".git/index") -> false
      # Skip everything else in .git/
      String.starts_with?(relative, ".git/") -> true
      # Skip common editor temp files
      String.ends_with?(relative, "~") -> true
      String.ends_with?(relative, ".swp") -> true
      String.starts_with?(Path.basename(relative), ".#") -> true
      true -> false
    end
  end
end
```

### Debounce Timeline

```
t=0ms    FSEvent: write file_a.ex
t=5ms    FSEvent: chmod file_a.ex
t=10ms   FSEvent: write file_b.ex
         (timer reset each time, 100ms from last event)
t=110ms  flush_changes → batch: [file_a.ex, file_b.ex]
         → single Repo.Worker refresh
```

---

## 7. PubSub Topic Design

### Topic Hierarchy

```
"repo:{id}:status"    — status changes (branch, dirty/clean, ahead/behind)
"repo:{id}:graph"     — graph layout updates (after commits, merges, rebases)
"repo:{id}:ai"        — AI stream root (session topics are children)
"repo:{id}:ai:{sid}"  — AI stream for specific session
"repo:{id}:ci"        — CI status from Sykli
"workspace:status"    — cross-repo summary (aggregated status)
"system:health"       — health check events (NIF status, AI provider, etc.)
```

### Subscription Matrix

| Subscriber | Topics | Why |
|---|---|---|
| `DashboardLive` | `workspace:status`, `repo:*:status` | Shows all repos, needs status updates |
| `RepoLive` | `repo:{id}:status`, `repo:{id}:graph`, `repo:{id}:ci` | Full repo view |
| `ChatLive` | `repo:{id}:ai:{sid}`, `repo:{id}:status` | Chat needs AI stream + status context |
| `Kerto.Hooks` | `repo:*:status` | Emits occurrences on git events |
| `Sykli.StatusMonitor` | `repo:*:ci` | Bridges Sykli occurrence files to PubSub |

### Broadcasting Pattern

```elixir
defmodule Valkka.Events do
  @moduledoc "Centralized event broadcasting. All PubSub messages go through here."

  def repo_status_changed(repo_id, status) do
    Phoenix.PubSub.broadcast(Valkka.PubSub, "repo:#{repo_id}:status",
      {:repo_status, repo_id, status})

    # Also broadcast to workspace-level topic for dashboard
    Phoenix.PubSub.broadcast(Valkka.PubSub, "workspace:status",
      {:repo_status, repo_id, status})
  end

  def graph_updated(repo_id) do
    Phoenix.PubSub.broadcast(Valkka.PubSub, "repo:#{repo_id}:graph",
      {:graph_updated, repo_id})
  end

  def ci_status_updated(repo_id, ci_status) do
    Phoenix.PubSub.broadcast(Valkka.PubSub, "repo:#{repo_id}:ci",
      {:ci_status, repo_id, ci_status})
  end

  def system_health(component, status) do
    Phoenix.PubSub.broadcast(Valkka.PubSub, "system:health",
      {:health, component, status})
  end
end
```

### Message Format Convention

All PubSub messages are tagged tuples. The first element is the event type atom. This allows pattern matching in `handle_info`:

```elixir
# In LiveView:
def handle_info({:repo_status, repo_id, status}, socket) do
  # ...
end

def handle_info({:ai_chunks, chunks}, socket) do
  # ...
end
```

---

## 8. Distribution Readiness

### Process Groups with :pg

```elixir
defmodule Valkka.Distribution do
  @moduledoc """
  Distribution primitives. Uses :pg (OTP 23+) for process group management.
  :pg works across connected BEAM nodes automatically.
  """

  @doc "Find the Repo.Worker process for a given repo_id, anywhere in the cluster."
  @spec find_repo_worker(String.t()) :: {:ok, pid()} | {:error, :not_found}
  def find_repo_worker(repo_id) do
    case :pg.get_members(Valkka.PG, {:repo, repo_id}) do
      [pid | _] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc "List all repo workers across the cluster."
  @spec all_repo_workers() :: [{String.t(), pid(), node()}]
  def all_repo_workers do
    :pg.which_groups(Valkka.PG)
    |> Enum.filter(fn
      {:repo, _id} -> true
      _ -> false
    end)
    |> Enum.flat_map(fn {:repo, id} = group ->
      :pg.get_members(Valkka.PG, group)
      |> Enum.map(fn pid -> {id, pid, node(pid)} end)
    end)
  end
end
```

### Start :pg in Application

```elixir
# Add to Valkka.Application.start/2 children, before Repo.Supervisor:
:pg.start_link(Valkka.PG)
```

### State Classification

| State | Local Only | Distributable | Why |
|---|---|---|---|
| Repo handles (`ResourceArc`) | Yes | No | NIF handles are process-local pointers. Cannot cross node boundaries. |
| File watchers | Yes | No | FSEvents/inotify is OS-local. Each node watches its own filesystem. |
| ETS caches | Yes | No | ETS is node-local. Each node maintains its own cache. Cache misses trigger NIF calls locally. |
| Workspace config | No | Yes | JSON/ETF. Small, infrequently changing. Can replicate via `:pg` + broadcast. |
| Conversation history | No | Yes | Append-only log. Can replicate via CRDTs or simple broadcast. |
| AI session state | Yes | No | HTTP stream is tied to the process that opened it. |
| PubSub messages | Partially | Via Phoenix.PubSub adapter | Use `Phoenix.PubSub.PG2` adapter for cross-node PubSub. |

### Cross-Node PubSub

```elixir
# config/prod.exs
config :valkka, Valkka.PubSub,
  adapter: Phoenix.PubSub.PG2  # Automatically distributes across connected nodes
```

With `PG2` adapter, a `Phoenix.PubSub.broadcast` on node A is received by subscribers on node B. No code changes needed -- LiveView processes on any node receive repo events.

### Network Partition Handling

```elixir
defmodule Valkka.Distribution.PartitionHandler do
  use GenServer

  @impl true
  def init(_opts) do
    :net_kernel.monitor_nodes(true)
    {:ok, %{connected_nodes: Node.list()}}
  end

  @impl true
  def handle_info({:nodedown, node}, state) do
    Logger.warning("Node disconnected: #{node}. Switching to local-only mode for remote repos.")

    # Repos on the disconnected node become unavailable
    remote_repos = Valkka.Distribution.all_repo_workers()
    |> Enum.filter(fn {_id, _pid, n} -> n == node end)

    for {repo_id, _pid, _node} <- remote_repos do
      Valkka.Events.repo_status_changed(repo_id, %{state: :unreachable, node: node})
    end

    new_nodes = List.delete(state.connected_nodes, node)
    {:noreply, %{state | connected_nodes: new_nodes}}
  end

  @impl true
  def handle_info({:nodeup, node}, state) do
    Logger.info("Node reconnected: #{node}. Refreshing remote repo state.")

    # Re-discover repos on the reconnected node
    # :pg membership is automatically restored by OTP
    new_nodes = [node | state.connected_nodes]
    {:noreply, %{state | connected_nodes: new_nodes}}
  end
end
```

### Local-Only Mode

When Valkka starts and no other nodes are connected, it operates in local-only mode. No code path changes. Distribution is additive:

- `:pg` works with a single node (groups are local).
- `Phoenix.PubSub.PG2` works with a single node (no cross-node broadcast needed).
- When nodes connect, `:pg` memberships merge automatically.

---

## 9. Graceful Shutdown

### The Shutdown Module

```elixir
defmodule Valkka.Shutdown do
  @moduledoc """
  Handles graceful shutdown on SIGTERM.

  Registered as the last child in the supervision tree. On terminate:
  1. Flush ETS caches to disk
  2. Close all NIF handles
  3. Complete in-flight operations (5s timeout)
  4. Clean up :pg memberships

  Total shutdown budget: 10 seconds.
  """

  use GenServer

  @shutdown_timeout 10_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{}}
  end

  @impl true
  def terminate(_reason, _state) do
    Logger.info("Valkka shutting down gracefully...")
    start = System.monotonic_time(:millisecond)

    # Phase 1: Flush ETS caches to disk (fast, ~10ms)
    flush_caches()

    # Phase 2: Signal all repo workers to complete in-flight operations
    # The DynamicSupervisor shutdown will propagate to workers,
    # which trap_exit and handle cleanup in their terminate/3.
    # We give them 5 seconds.
    signal_workers_shutdown()

    elapsed = System.monotonic_time(:millisecond) - start
    remaining = max(0, @shutdown_timeout - elapsed)

    if remaining > 0 do
      Logger.info("Shutdown complete in #{elapsed}ms")
    else
      Logger.warning("Shutdown exceeded budget, force killing remaining processes")
    end

    :ok
  end

  defp flush_caches do
    cache_dir = Application.get_env(:valkka, :cache_dir, "/tmp/valkka_cache")
    File.mkdir_p!(cache_dir)

    try do
      Valkka.Cache.StatusCache.flush_to_disk(Path.join(cache_dir, "status.etf"))
      Logger.debug("ETS caches flushed to #{cache_dir}")
    rescue
      e -> Logger.warning("Failed to flush caches: #{inspect(e)}")
    end

    # Graph cache and commit cache are not flushed -- they rebuild on next startup.
    # Status cache is flushed because it avoids a NIF call on restart.
  end

  defp signal_workers_shutdown do
    # Each Repo.Worker traps exits and handles cleanup in terminate/3:
    # - Shuts down in-flight Task (5s timeout)
    # - Calls repo_close on the NIF handle
    # - Leaves :pg groups
    #
    # The Supervisor shutdown order ensures workers terminate before
    # Task.Supervisor (Valkka.NifTasks), so in-flight tasks can complete.
    :ok
  end
end
```

### Supervision Tree Shutdown Order

OTP shuts down children in reverse start order. Our tree shuts down as:

```
1. Valkka.Shutdown.terminate/3 runs    — flushes caches
2. ValkkaWeb.Endpoint stops            — no new HTTP connections
3. Valkka.Kerto.Hooks stops            — no more occurrence emission
4. Valkka.Sykli.StatusMonitor stops    — no more CI polling
5. Valkka.Workspace.Registry stops     — registry cleaned up
6. Valkka.AI.Supervisor stops          — AI streams cancelled
7. Valkka.Repo.Supervisor stops        — each WorkerSupervisor stops:
   a. Watcher.Handler stops           — file watching stops
   b. Repo.Worker.terminate/3 runs    — closes NIF handles, kills tasks
8. Valkka.NifTasks stops               — any orphan tasks killed
9. Valkka.CacheSupervisor stops        — ETS tables destroyed
10. Valkka.PubSub stops                — PubSub cleaned up
```

### Release Configuration

```elixir
# rel/vm.args.eex

## Graceful shutdown timeout (matches our 10s budget)
-heart
+zdbbl 2097152

## SIGTERM handling
# OTP 26+ handles SIGTERM natively when heart is disabled.
# With heart enabled, configure via:
-env HEART_COMMAND ""
```

```elixir
# config/runtime.exs
config :valkka, :shutdown_timeout, 10_000

# In mix.exs release config:
releases: [
  valkka: [
    applications: [valkka: :permanent],
    steps: [:assemble, :tar],
    # 10 second shutdown timeout for the application
    shutdown: [
      valkka: 10_000
    ]
  ]
]
```

### Per-Repo Worker Shutdown Flow

```
SIGTERM received
  → Application supervisor begins shutdown (reverse order)
    → DynamicSupervisor sends :shutdown to each WorkerSupervisor
      → WorkerSupervisor (rest_for_one) shuts down Watcher first, then Worker
        → Repo.Worker.terminate/3:
           1. If current_task exists:
              Task.shutdown(current_task, 5_000)  # wait up to 5s
           2. If handle exists:
              Valkka.Git.Native.repo_close(handle)  # release Mutex, drop repo
           3. :pg.leave(Valkka.PG, {:repo, repo_id}, self())
           4. Log shutdown
```

---

## 10. Bringing It Together: Repo Lifecycle

A complete example of a repo being opened, used, and shut down:

```
1. User adds ~/projects/my-app to workspace

2. Valkka.Repo.Manager.open("my-app", "~/projects/my-app")
   → DynamicSupervisor starts a WorkerSupervisor for this repo
   → WorkerSupervisor starts:
     a. Repo.Worker (gen_statem) in :initializing state
     b. Watcher.Handler watching ~/projects/my-app

3. Repo.Worker :initializing
   → Spawns Task: Valkka.Git.Native.repo_open + repo_info
   → Task succeeds → transition to :idle
   → Joins :pg group {:repo, "my-app"}
   → Broadcasts {:repo_opened, status}

4. LiveView subscribes to "repo:my-app:status"
   → Receives status, renders dashboard card

5. User types "commit all with a good message"
   → Intent parsed → {:ai_op, :generate_commit_msg, %{}}
   → ContextBuilder reads staged diff via Worker.query({:diff, "HEAD", "STAGED"})
   → AI generates message, user confirms
   → Worker.execute({:stage, ["."]}) → :idle → :operating → :idle
   → Worker.execute({:commit, message, %{}}) → :idle → :operating → :idle
   → Caches invalidated, status broadcast, graph updated

6. File changes on disk (agent editing files)
   → Watcher.Handler receives FSEvents
   → Debounces 100ms
   → Sends {:file_changed, paths} to Worker
   → Worker refreshes status (in :idle, via background Task)
   → StatusCache invalidated
   → New status broadcast to LiveView

7. SIGTERM
   → Watcher.Handler stops
   → Worker.terminate: no in-flight task, calls repo_close
   → ETS flushed
   → Done
```
