defmodule Valkka.Status do
  @moduledoc """
  Pure query module for system status. No process — just functions
  that aggregate agent state from detector plugins.
  """

  require Logger

  @doc "Returns all detected agents across all detector plugins."
  def agents do
    Valkka.Plugin.Registry.agent_detectors()
    |> Enum.flat_map(fn mod ->
      try do
        mod.detect_agents()
      rescue
        e ->
          Logger.warning("Agent detector #{inspect(mod)} failed: #{Exception.message(e)}")
          []
      end
    end)
    |> Enum.sort_by(&{!&1.active, &1.repo_path})
  end

  @doc "Summary counts from a pre-fetched agents list."
  def agent_summary(agents) do
    active = Enum.count(agents, & &1.active)
    %{total: length(agents), active: active, idle: length(agents) - active}
  end
end
