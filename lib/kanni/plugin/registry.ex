defmodule Kanni.Plugin.Registry do
  @moduledoc """
  Discovers and indexes plugins from application config.

  Owns an ETS table for fast, concurrent read access.
  Plugins are registered at boot and indexed by capability.
  """

  use GenServer

  require Logger

  @table :kanni_plugin_registry

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Public read API — goes directly to ETS, no GenServer call

  def all do
    case :ets.lookup(@table, :plugins) do
      [{:plugins, list}] -> list
      [] -> []
    end
  end

  def context_providers, do: providers_for(:context_provider)
  def event_consumers, do: providers_for(:event_consumer)
  def action_providers, do: providers_for(:action_provider)
  def panel_providers, do: providers_for(:panel_provider)

  defp providers_for(capability) do
    case :ets.lookup(@table, {:capability, capability}) do
      [{_, list}] -> list
      [] -> []
    end
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    plugins = discover_plugins()
    index_plugins(plugins)
    {:ok, %{table: table}}
  end

  defp discover_plugins do
    Application.get_env(:kanni, :plugins, [])
    |> Enum.filter(fn mod ->
      case Code.ensure_loaded(mod) do
        {:module, ^mod} ->
          if function_exported?(mod, :capabilities, 0) do
            true
          else
            Logger.warning("Plugin #{inspect(mod)} does not export capabilities/0, skipping")
            false
          end

        {:error, reason} ->
          Logger.warning("Plugin #{inspect(mod)} could not be loaded: #{inspect(reason)}")
          false
      end
    end)
  end

  defp index_plugins(plugins) do
    :ets.insert(@table, {:plugins, plugins})

    for capability <- [:context_provider, :event_consumer, :action_provider, :panel_provider] do
      matching = Enum.filter(plugins, fn mod -> capability in mod.capabilities() end)
      :ets.insert(@table, {{:capability, capability}, matching})
    end
  end
end
