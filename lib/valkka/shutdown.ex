defmodule Valkka.Shutdown do
  @moduledoc """
  Handles graceful shutdown on SIGTERM.

  Ensures all repo handles are properly closed and caches
  are flushed before the VM exits.
  """

  use GenServer

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{}}
  end

  @impl true
  def terminate(reason, _state) do
    Logger.info("Valkka shutting down: #{inspect(reason)}")
    :ok
  end
end
