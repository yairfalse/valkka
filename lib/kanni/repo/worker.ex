defmodule Kanni.Repo.Worker do
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
    status: :initializing
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
          status: :initializing | :idle | :operating | :error
        }

  def start_link(path) do
    :gen_statem.start_link({:via, Registry, {Kanni.Repo.Registry, path}}, __MODULE__, path, [])
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
    case Registry.lookup(Kanni.Repo.Registry, path) do
      [{pid, _}] -> get_state(pid)
      [] -> {:error, :not_found}
    end
  end

  @doc "Get the NIF handle for direct git operations."
  def get_handle(pid) when is_pid(pid) do
    :gen_statem.call(pid, :get_handle)
  end

  def get_handle(path) when is_binary(path) do
    case Registry.lookup(Kanni.Repo.Registry, path) do
      [{pid, _}] -> get_handle(pid)
      [] -> {:error, :not_found}
    end
  end

  @doc "Force an immediate refresh of repo state."
  def refresh(pid) when is_pid(pid) do
    :gen_statem.cast(pid, :refresh)
  end

  # gen_statem callbacks

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init(path) do
    data = %__MODULE__{path: path, name: Path.basename(path)}
    {:ok, :initializing, data, [{:next_event, :internal, :open}]}
  end

  def initializing(:internal, :open, data) do
    case Kanni.Git.Native.repo_open(data.path) do
      {:ok, handle} ->
        data = %{data | handle: handle, status: :idle}
        Kanni.Watcher.Handler.watch_repo(data.path)
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

  def idle(:info, {:file_changed, file_path, _events}, data) do
    data = do_refresh(data)
    broadcast(data)

    relative = Path.relative_to(file_path, data.path)
    Kanni.Plugin.Events.dispatch(:file_changed, %{repo: data.name, file: relative})

    {:keep_state, data, [{{:timeout, :refresh}, @refresh_interval, :tick}]}
  end

  def idle(:info, _msg, data) do
    {:keep_state, data}
  end

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
    Kanni.Watcher.Handler.unwatch_repo(data.path)
    :ok
  end

  # Private

  defp do_refresh(data) do
    data
    |> refresh_head_info()
    |> refresh_status()
  end

  defp refresh_head_info(data) do
    case Kanni.Git.Native.repo_head_info(data.handle) do
      json when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, info} ->
            %{
              data
              | branch: info["branch"],
                ahead: info["ahead"] || 0,
                behind: info["behind"] || 0,
                is_detached: info["is_detached"] || false
            }

          _ ->
            data
        end

      _ ->
        data
    end
  end

  defp refresh_status(data) do
    case Kanni.Git.Native.repo_status(data.handle) do
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
      status: data.status
    }
  end

  defp broadcast(data) do
    Phoenix.PubSub.broadcast(
      Kanni.PubSub,
      "repo:#{data.path}",
      {:repo_state_changed, snapshot(data)}
    )

    Phoenix.PubSub.broadcast(
      Kanni.PubSub,
      "repos",
      {:repo_state_changed, snapshot(data)}
    )
  end
end
