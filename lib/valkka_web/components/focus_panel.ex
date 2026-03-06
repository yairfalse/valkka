defmodule ValkkaWeb.Components.FocusPanel do
  @moduledoc """
  Center panel: topbar with breadcrumbs/pills/actions, then tabbed content.
  Tabs: Graph (default), Changes, Diff.
  """

  use Phoenix.Component

  attr :selected_repo, :map, default: nil
  attr :active_tab, :string, default: "graph"
  slot :graph
  slot :changes
  slot :diff

  def focus_panel(assigns) do
    ~H"""
    <div class="valkka-center">
      <div :if={@selected_repo} class="valkka-topbar">
        <span class="valkka-bc">False Systems</span>
        <span class="valkka-bc-sep"> / </span>
        <span class="valkka-bc-current">{@selected_repo.name}</span>

        <span :if={@selected_repo[:branch]} class="valkka-pill branch">
          {"⎇ #{@selected_repo[:branch]}"}
        </span>
        <span :if={Map.get(@selected_repo, :ahead, 0) > 0} class="valkka-pill ahead">
          {"↑ #{@selected_repo.ahead}"}
        </span>
        <span :if={Map.get(@selected_repo, :agent_active, false)} class="valkka-pill agent">
          {"● agent"}
        </span>
        <span :if={Map.get(@selected_repo, :dirty_count, 0) > 0} class="valkka-pill changes">
          {"◇ #{@selected_repo.dirty_count}"}
        </span>

        <span class="valkka-spacer"></span>

        <button class="valkka-btn primary" phx-click="key:focus_commit">Commit</button>
        <button class="valkka-btn default" phx-click="key:push">Push</button>
        <button class="valkka-btn ghost" phx-click="key:toggle_branch">Branch</button>
      </div>

      <div :if={@selected_repo} class="valkka-tab-bar">
        <button
          class={"valkka-tab #{if @active_tab == "graph", do: "active"}"}
          phx-click="switch_tab"
          phx-value-tab="graph"
        >
          Graph
        </button>
        <button
          class={"valkka-tab #{if @active_tab == "changes", do: "active"}"}
          phx-click="switch_tab"
          phx-value-tab="changes"
        >
          Changes
          <span :if={@selected_repo && Map.get(@selected_repo, :dirty_count, 0) > 0} class="valkka-tab-count">
            {@selected_repo.dirty_count}
          </span>
        </button>
        <button
          class={"valkka-tab #{if @active_tab == "diff", do: "active"}"}
          phx-click="switch_tab"
          phx-value-tab="diff"
        >
          Diff
        </button>
      </div>

      <div :if={@selected_repo} style="flex:1;overflow:hidden;display:flex;flex-direction:column">
        <div :if={@active_tab == "graph"} class="valkka-panel active">
          {render_slot(@graph)}
        </div>
        <div :if={@active_tab == "changes"} class="valkka-panel active">
          {render_slot(@changes)}
        </div>
        <div :if={@active_tab == "diff"} class="valkka-panel active">
          {render_slot(@diff)}
        </div>
      </div>

      <div :if={!@selected_repo} style="display:flex;align-items:center;justify-content:center;flex:1">
        <p class="valkka-empty">Select a repo to get started</p>
      </div>
    </div>
    """
  end
end
