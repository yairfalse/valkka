defmodule KanniWeb.Components.FocusPanel do
  @moduledoc """
  Center panel: tabbed view of the selected repo's state.
  Tabs: Changes (default), Graph, Activity.
  """

  use Phoenix.Component

  attr :selected_repo, :map, default: nil
  attr :active_tab, :string, default: "changes"
  slot :changes
  slot :graph
  slot :activity

  def focus_panel(assigns) do
    ~H"""
    <div class="kanni-focus-panel">
      <div :if={@selected_repo} class="kanni-focus-content">
        <div class="kanni-tab-bar">
          <button
            :for={tab <- ~w(changes graph activity)}
            class={"kanni-tab #{if @active_tab == tab, do: "active", else: ""}"}
            phx-click="switch_tab"
            phx-value-tab={tab}
          >
            {String.capitalize(tab)}
          </button>
        </div>
        <div class="kanni-tab-content">
          <div :if={@active_tab == "changes"}>
            {render_slot(@changes)}
          </div>
          <div :if={@active_tab == "graph"}>
            {render_slot(@graph)}
          </div>
          <div :if={@active_tab == "activity"}>
            {render_slot(@activity)}
          </div>
        </div>
      </div>
      <div :if={!@selected_repo} class="kanni-focus-empty">
        <p class="kanni-empty-message">Select a repo to get started</p>
      </div>
    </div>
    """
  end
end
