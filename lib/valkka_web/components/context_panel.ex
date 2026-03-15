defmodule ValkkaWeb.Components.ContextPanel do
  @moduledoc """
  Right panel: Timeline header with filter toggle + activity stream.
  """

  use Phoenix.Component

  attr :timeline_filter, :atom, default: :all
  attr :has_focused_repo, :boolean, default: false
  slot :activity

  def context_panel(assigns) do
    ~H"""
    <aside class="valkka-right-panel">
      <div class="valkka-timeline-header">
        <span class="valkka-timeline-label">Timeline</span>
        <span :if={@has_focused_repo} class="valkka-timeline-filter">
          <span
            class={"valkka-timeline-option #{if @timeline_filter == :all, do: "active"}"}
            phx-click="toggle_timeline_filter"
            phx-value-mode="all"
          >
            All
          </span>
          <span class="valkka-timeline-sep">|</span>
          <span
            class={"valkka-timeline-option #{if @timeline_filter == :focused, do: "active"}"}
            phx-click="toggle_timeline_filter"
            phx-value-mode="focused"
          >
            Focused
          </span>
        </span>
      </div>
      <div class="valkka-rp-body">
        {render_slot(@activity)}
      </div>
    </aside>
    """
  end
end
