defmodule ValkkaWeb.Components.ContextPanel do
  @moduledoc """
  Right panel: Activity stream + Agents tabs.
  Replaces the old context-provider panel.
  """

  use Phoenix.Component

  attr :active_rp_tab, :string, default: "activity"
  slot :activity
  slot :agents

  def context_panel(assigns) do
    ~H"""
    <aside class="valkka-right-panel">
      <div class="valkka-rp-tabs">
        <button
          class={"valkka-rp-tab #{if @active_rp_tab == "activity", do: "active"}"}
          phx-click="switch_rp_tab"
          phx-value-tab="activity"
        >
          Activity
        </button>
        <button
          class={"valkka-rp-tab #{if @active_rp_tab == "agents", do: "active"}"}
          phx-click="switch_rp_tab"
          phx-value-tab="agents"
        >
          Agents
        </button>
      </div>
      <div class="valkka-rp-body">
        <div :if={@active_rp_tab == "activity"}>
          {render_slot(@activity)}
        </div>
        <div :if={@active_rp_tab == "agents"} style="padding:8px 0">
          {render_slot(@agents)}
        </div>
      </div>
    </aside>
    """
  end
end
