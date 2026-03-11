defmodule Valkka.Repo.Worker do
  @moduledoc """
  State machine for a single git repository.

  States:
  - `:initializing` — opening the repo via NIF
  - `:idle` — ready for operations, periodically refreshes state
  - `:operating` — a git operation is in progress
  - `:error` — an unrecoverable error occurred

  Each worker holds a NIF resource handle to a git2::Repository
  and broadcasts state changes via PubSub.
  """

  @behaviour :gen_statem

  require Logger

  @refresh_interval :timer.seconds(5)

  defstruct [
    :path,
    :name,
    :handle,
    branch: nil,
    ahead: 0,
    behind: 0,
    is_detached: false,
    dirty_count: 0,
    head_oid: nil,
    status: :initializing,
    agent_active: false
  ]

  @type t :: %__MODULE__{
          path: String.t(),
          name: String.t(),
          handle: reference() | nil,
          branch: String.t() | nil,
          ahead: non_neg_integer(),
          behind: non_neg_integer(),
          is_detached: boolean(),
          dirty_count: non_neg_integer(),
          head_oid: String.t() | nil,
          status: :initializing | :idle | :operating | :error,
          agent_active: boolean()
        }

  def start_link(path) do
    :gen_statem.start_link({:via, Registry, {Valkka.Repo.Registry, path}}, __MODULE__, path, [])
  end

  def child_spec(path) do
    %{
      id: {__MODULE__, path},
      start: {__MODULE__, :start_link, [path]},
      restart: :transient
    }
  end

  @doc "Get the current state snapshot from a worker."
  def get_state(pid) when is_pid(pid) do
    :gen_statem.call(pid, :get_state)
  end

  def get_state(path) when is_binary(path) do
    case Registry.lookup(Valkka.Repo.Registry, path) do
      [{pid, _}] -> get_state(pid)
      [] -> {:error, :not_found}
    end
  end

  @doc "Get the NIF handle for direct git operations."
  def get_handle(pid) when is_pid(pid) do
    :gen_statem.call(pid, :get_handle)
  end

  def get_handle(path) when is_binary(path) do
    case Registry.lookup(Valkka.Repo.Registry, path) do
      [{pid, _}] -> get_handle(pid)
      [] -> {:error, :not_found}
    end
  end

  @doc "Force an immediate refresh of repo state."
  def refresh(pid) when is_pid(pid) do
    :gen_statem.cast(pid, :refresh)
  end

  @doc "Execute a git operation through the worker's state machine."
  def operate(path_or_pid, op, args \\ %{})

  def operate(pid, op, args) when is_pid(pid) do
    :gen_statem.call(pid, {:operate, op, args}, 15_000)
  end

  def operate(path, op, args) when is_binary(path) do
    case Registry.lookup(Valkka.Repo.Registry, path) do
      [{pid, _}] -> operate(pid, op, args)
      [] -> {:error, :not_found}
    end
  end

  def stage(path, file), do: operate(path, :stage, %{file: file})
  def unstage(path, file), do: operate(path, :unstage, %{file: file})
  def stage_all(path), do: operate(path, :stage_all)
  def commit(path, message), do: operate(path, :commit, %{message: message})
  def push(path), do: operate(path, :push)
  def pull(path), do: operate(path, :pull)
  def discard_file(path, file), do: operate(path, :discard_file, %{file: file})
  def create_branch(path, name), do: operate(path, :create_branch, %{name: name})

  # gen_statem callbacks

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init(path) do
    data = %__MODULE__{path: path, name: Path.basename(path)}
    {:ok, :initializing, data, [{:next_event, :internal, :open}]}
  end

  def initializing(:internal, :open, data) do
    case Valkka.Git.Native.repo_open(data.path) do
      handle when is_reference(handle) ->
        data = %{data | handle: handle, status: :idle}
        Valkka.Watcher.Handler.watch_repo(data.path)
        Phoenix.PubSub.subscribe(Valkka.PubSub, "agents")
        {:next_state, :idle, data, [{:next_event, :internal, :refresh}]}

      {:error, reason} ->
        Logger.error("Failed to open repo #{data.path}: #{inspect(reason)}")
        {:next_state, :error, %{data | status: :error}}
    end
  end

  def initializing({:call, from}, :get_state, data) do
    {:keep_state, data, [{:reply, from, {:ok, snapshot(data)}}]}
  end

  def idle(:internal, :refresh, data) do
    data = do_refresh(data)
    broadcast(data)
    {:keep_state, data, [{{:timeout, :refresh}, @refresh_interval, :tick}]}
  end

  def idle({:timeout, :refresh}, :tick, data) do
    data = do_refresh(data)
    broadcast(data)
    {:keep_state, data, [{{:timeout, :refresh}, @refresh_interval, :tick}]}
  end

  def idle(:cast, :refresh, data) do
    data = do_refresh(data)
    broadcast(data)
    {:keep_state, data, [{{:timeout, :refresh}, @refresh_interval, :tick}]}
  end

  def idle({:call, from}, :get_state, data) do
    {:keep_state, data, [{:reply, from, {:ok, snapshot(data)}}]}
  end

  def idle({:call, from}, :get_handle, data) do
    {:keep_state, data, [{:reply, from, {:ok, data.handle}}]}
  end

  def idle({:call, from}, {:operate, op, args}, data) do
    data = %{data | status: :operating}
    {:next_state, :operating, data, [{:next_event, :internal, {:execute, op, args, from}}]}
  end

  def idle(:info, {:agents_changed, agents}, data) do
    active = Enum.any?(agents, &(&1.repo_path == data.path))

    if active != data.agent_active do
      data = %{data | agent_active: active}
      broadcast(data)
      {:keep_state, data}
    else
      {:keep_state, data}
    end
  end

  def idle(:info, {:agent_started, _agent}, data), do: {:keep_state, data}
  def idle(:info, {:agent_stopped, _agent}, data), do: {:keep_state, data}

  def idle(:info, {:file_changed, file_path, _events}, data) do
    data = do_refresh(data)
    broadcast(data)

    relative = Path.relative_to(file_path, data.path)
    Valkka.Plugin.Events.dispatch(:file_changed, %{repo: data.name, file: relative})

    {:keep_state, data, [{{:timeout, :refresh}, @refresh_interval, :tick}]}
  end

  def idle(:info, _msg, data) do
    {:keep_state, data}
  end

  # -- :operating state --

  def operating(:internal, {:execute, op, args, from}, data) do
    result = execute_operation(op, args, data)

    data =
      data
      |> do_refresh()
      |> Map.put(:status, :idle)

    broadcast(data)

    {:next_state, :idle, data,
     [{:reply, from, result}, {{:timeout, :refresh}, @refresh_interval, :tick}]}
  end

  def operating({:call, from}, :get_state, data) do
    {:keep_state, data, [{:reply, from, {:ok, snapshot(data)}}]}
  end

  def operating({:call, from}, :get_handle, data) do
    {:keep_state, data, [{:reply, from, {:ok, data.handle}}]}
  end

  def operating({:call, _from}, {:operate, _op, _args}, _data) do
    {:keep_state_and_data, [:postpone]}
  end

  def operating(:info, {:agents_changed, agents}, data) do
    active = Enum.any?(agents, &(&1.repo_path == data.path))
    {:keep_state, %{data | agent_active: active}}
  end

  def operating(:info, {:agent_started, _}, _data), do: {:keep_state_and_data, []}
  def operating(:info, {:agent_stopped, _}, _data), do: {:keep_state_and_data, []}

  # Postpone refresh/file_changed during operations
  def operating({:timeout, :refresh}, :tick, _data), do: {:keep_state_and_data, [:postpone]}
  def operating(:cast, :refresh, _data), do: {:keep_state_and_data, [:postpone]}
  def operating(:info, {:file_changed, _, _}, _data), do: {:keep_state_and_data, [:postpone]}

  def operating(:info, _msg, _data), do: {:keep_state_and_data, []}

  # -- :error state --

  def error({:call, from}, :get_state, data) do
    {:keep_state, data, [{:reply, from, {:ok, snapshot(data)}}]}
  end

  def error({:call, from}, :get_handle, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :repo_error}}]}
  end

  def error(:info, _msg, data) do
    {:keep_state, data}
  end

  @impl true
  def terminate(_reason, _state, data) do
    Valkka.Watcher.Handler.unwatch_repo(data.path)
    :ok
  end

  # -- Operation dispatch --

  defp execute_operation(:stage, %{file: file}, data) do
    case Valkka.Git.Native.repo_stage(data.handle, file) do
      :ok -> :ok
      {:error, _} = err -> err
      _ -> :ok
    end
  end

  defp execute_operation(:unstage, %{file: file}, data) do
    case Valkka.Git.Native.repo_unstage(data.handle, file) do
      :ok -> :ok
      {:error, _} = err -> err
      _ -> :ok
    end
  end

  defp execute_operation(:stage_all, _args, data) do
    case Valkka.Git.Native.repo_status(data.handle) do
      json when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, %{"unstaged" => unstaged, "untracked" => untracked}} ->
            for file <- unstaged ++ untracked do
              Valkka.Git.Native.repo_stage(data.handle, file["path"])
            end

            :ok

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp execute_operation(:commit, %{message: message}, data) do
    {name, email} = Valkka.Git.CLI.user_config(data.path)

    case Valkka.Git.Native.repo_commit(data.handle, message, name, email) do
      oid when is_binary(oid) -> {:ok, oid}
      {:error, _} = err -> err
    end
  end

  defp execute_operation(:push, _args, data) do
    Valkka.Git.CLI.push(data.path)
  end

  defp execute_operation(:pull, _args, data) do
    Valkka.Git.CLI.pull(data.path)
  end

  defp execute_operation(:discard_file, %{file: file}, data) do
    Valkka.Git.CLI.run(data.path, ["checkout", "--", file])
  end

  defp execute_operation(:create_branch, %{name: name}, data) do
    Valkka.Git.CLI.run(data.path, ["checkout", "-b", name])
  end

  # Private

  defp do_refresh(data) do
    data
    |> refresh_head_info()
    |> refresh_status()
  end

  defp refresh_head_info(data) do
    case Valkka.Git.Native.repo_head_info(data.handle) do
      json when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, info} ->
            %{
              data
              | branch: info["branch"],
                ahead: info["ahead"] || 0,
                behind: info["behind"] || 0,
                is_detached: info["is_detached"] || false,
                head_oid: info["head_oid"]
            }

          _ ->
            data
        end

      _ ->
        data
    end
  end

  defp refresh_status(data) do
    case Valkka.Git.Native.repo_status(data.handle) do
      json when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, statuses} when is_map(statuses) ->
            staged = length(Map.get(statuses, "staged", []))
            unstaged = length(Map.get(statuses, "unstaged", []))
            untracked = length(Map.get(statuses, "untracked", []))
            %{data | dirty_count: staged + unstaged + untracked}

          {:ok, statuses} when is_list(statuses) ->
            %{data | dirty_count: length(statuses)}

          _ ->
            data
        end

      _ ->
        data
    end
  end

  defp snapshot(data) do
    %{
      path: data.path,
      name: data.name,
      branch: data.branch,
      ahead: data.ahead,
      behind: data.behind,
      is_detached: data.is_detached,
      dirty_count: data.dirty_count,
      head_oid: data.head_oid,
      status: data.status,
      agent_active: data.agent_active
    }
  end

  defp broadcast(data) do
    Phoenix.PubSub.broadcast(
      Valkka.PubSub,
      "repo:#{data.path}",
      {:repo_state_changed, snapshot(data)}
    )

    Phoenix.PubSub.broadcast(
      Valkka.PubSub,
      "repos",
      {:repo_state_changed, snapshot(data)}
    )
  end
end
