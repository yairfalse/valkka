defmodule Valkka.Plugin.ActionProvider do
  @moduledoc """
  Capability for plugins that provide executable actions.
  """

  @type action :: %{
          id: atom(),
          label: String.t(),
          icon: String.t() | nil,
          scope: :global | :repo | :file
        }

  @callback list_actions() :: [action()]
  @callback execute_action(atom(), map()) :: {:ok, term()} | {:error, term()}
end
