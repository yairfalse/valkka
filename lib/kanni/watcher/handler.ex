defmodule Kanni.Watcher.Handler do
  @moduledoc """
  GenServer that listens to filesystem events and broadcasts
  changes via PubSub.

  Watches the repository working directory for file changes,
  debounces rapid events, and notifies the repo worker to
  refresh its status.
  """

  use GenServer

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # File watching will be started when a repo is opened.
    # For now, just hold state.
    {:ok, %{watchers: %{}}}
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {path, events}}, state) do
    Logger.debug("File event: #{path} #{inspect(events)}")
    Phoenix.PubSub.broadcast(Kanni.PubSub, "file_events", {:file_changed, path, events})
    {:noreply, state}
  end

  def handle_info({:file_event, _watcher_pid, :stop}, state) do
    Logger.warning("File watcher stopped")
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
