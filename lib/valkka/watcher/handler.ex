defmodule Valkka.Watcher.Handler do
  @moduledoc """
  GenServer that manages filesystem watchers for repos and broadcasts
  changes via PubSub. Debounces rapid events to avoid flooding.
  """

  use GenServer

  require Logger

  @debounce_ms 200

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Start watching a repository path for file changes."
  def watch_repo(path) do
    GenServer.call(__MODULE__, {:watch, path})
  end

  @doc "Stop watching a repository path."
  def unwatch_repo(path) do
    GenServer.call(__MODULE__, {:unwatch, path})
  end

  @doc "List all active watchers as a `%{path => pid}` map."
  def list_watchers do
    GenServer.call(__MODULE__, :list_watchers)
  end

  @impl true
  def init(_opts) do
    {:ok, %{watchers: %{}, debounce_timers: %{}}}
  end

  @impl true
  def handle_call({:watch, path}, _from, state) do
    if Map.has_key?(state.watchers, path) do
      {:reply, :ok, state}
    else
      case FileSystem.start_link(dirs: [path], name: :"watcher_#{:erlang.phash2(path)}") do
        {:ok, pid} ->
          FileSystem.subscribe(pid)
          watchers = Map.put(state.watchers, path, pid)
          Logger.debug("Started watching #{path}")
          {:reply, :ok, %{state | watchers: watchers}}

        {:error, reason} ->
          Logger.warning("Failed to watch #{path}: #{inspect(reason)}")
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call(:list_watchers, _from, state) do
    {:reply, {:ok, state.watchers}, state}
  end

  def handle_call({:unwatch, path}, _from, state) do
    case Map.pop(state.watchers, path) do
      {nil, _} ->
        {:reply, :ok, state}

      {pid, watchers} ->
        # Cancel pending debounce timers for files under this repo
        debounce_timers =
          Enum.reduce(state.debounce_timers, %{}, fn {file_path, ref}, acc ->
            if String.starts_with?(file_path, path) do
              Process.cancel_timer(ref)
              acc
            else
              Map.put(acc, file_path, ref)
            end
          end)

        GenServer.stop(pid)
        {:reply, :ok, %{state | watchers: watchers, debounce_timers: debounce_timers}}
    end
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {path, events}}, state) do
    # Skip .git internal changes and common noise
    if should_broadcast?(path) do
      # Debounce: cancel existing timer for this path, set new one
      state = debounce_event(state, path, events)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:file_event, _watcher_pid, :stop}, state) do
    Logger.warning("File watcher stopped")
    {:noreply, state}
  end

  def handle_info({:debounced_event, path, events}, state) do
    Phoenix.PubSub.broadcast(Valkka.PubSub, "file_events", {:file_changed, path, events})

    # Also notify the specific repo worker
    notify_worker(path, state.watchers)

    timers = Map.delete(state.debounce_timers, path)
    {:noreply, %{state | debounce_timers: timers}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp should_broadcast?(path) do
    basename = Path.basename(path)
    # Skip .git internals, editor temp files, OS files
    ".git" not in Path.split(path) and
      basename != ".DS_Store" and
      not String.ends_with?(basename, "~") and
      not String.ends_with?(basename, ".swp") and
      not String.starts_with?(basename, ".#")
  end

  defp debounce_event(state, path, events) do
    # Cancel existing timer
    case Map.get(state.debounce_timers, path) do
      nil -> :ok
      ref -> Process.cancel_timer(ref)
    end

    ref = Process.send_after(self(), {:debounced_event, path, events}, @debounce_ms)
    timers = Map.put(state.debounce_timers, path, ref)
    %{state | debounce_timers: timers}
  end

  defp notify_worker(file_path, watchers) do
    # Find which watched repo this file belongs to
    Enum.each(watchers, fn {repo_path, _pid} ->
      if String.starts_with?(file_path, repo_path) do
        case Registry.lookup(Valkka.Repo.Registry, repo_path) do
          [{worker_pid, _}] ->
            send(worker_pid, {:file_changed, file_path, []})

          [] ->
            :ok
        end
      end
    end)
  end
end
