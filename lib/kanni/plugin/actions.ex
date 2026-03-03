defmodule Kanni.Plugin.Actions do
  @moduledoc """
  Collects and executes actions from all action provider plugins.
  """

  @doc "Collect actions from all action providers."
  def all_actions do
    Kanni.Plugin.Registry.action_providers()
    |> Enum.flat_map(fn mod -> mod.list_actions() end)
  end

  @doc "Execute an action by ID, finding the right provider."
  def execute(action_id, params \\ %{}) do
    provider =
      Kanni.Plugin.Registry.action_providers()
      |> Enum.find(fn mod ->
        Enum.any?(mod.list_actions(), &(&1.id == action_id))
      end)

    case provider do
      nil -> {:error, :action_not_found}
      mod -> mod.execute_action(action_id, params)
    end
  end
end
