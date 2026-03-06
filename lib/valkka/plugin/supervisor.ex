defmodule Valkka.Plugin.Supervisor do
  @moduledoc """
  DynamicSupervisor for plugin child processes.

  Plugins that return a child_spec/1 get their processes started here,
  crash-isolated from each other and from Valkka's core supervision tree.
  """

  use DynamicSupervisor

  require Logger

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Start child processes for all registered plugins, then call init/1."
  def start_plugins do
    for mod <- Valkka.Plugin.Registry.all() do
      if function_exported?(mod, :child_spec, 1) do
        case mod.child_spec([]) do
          nil ->
            :ok

          spec ->
            case DynamicSupervisor.start_child(__MODULE__, spec) do
              {:ok, _pid} ->
                Logger.info("Started plugin process: #{mod.name()}")

              {:error, reason} ->
                Logger.error("Failed to start plugin #{mod.name()}: #{inspect(reason)}")
            end
        end
      end

      if function_exported?(mod, :init, 1) do
        mod.init([])
      end
    end

    :ok
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
