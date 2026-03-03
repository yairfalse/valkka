defmodule Kanni.Plugin.PanelProvider do
  @moduledoc """
  Capability for plugins that contribute UI panels to the dashboard.

  The `component` must be a `Phoenix.Component` module with a `render/1` function.
  Dashboard assigns are passed through to the component.
  """

  @type panel :: %{
          id: atom(),
          label: String.t(),
          position: :right | :bottom | :tab,
          component: module()
        }

  @callback panels() :: [panel()]
end
