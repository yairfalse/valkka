defmodule ValkkaWeb.Components.FocusPanel do
  @moduledoc """
  Center panel: topbar with breadcrumbs/pills/actions, then tabbed content.
  Tabs: Graph, Changes (with inline diff).
  """

  use Phoenix.Component

  attr :selected_repo, :map, default: nil
  attr :active_tab, :string, default: "graph"
  attr :active_agent, :map, default: nil
  attr :agent_elapsed, :string, default: nil
  slot :graph
  slot :changes

  def focus_panel(assigns) do
    ~H"""
    <div class="valkka-center">
      <div :if={@selected_repo} class="valkka-topbar">
        <span class="valkka-bc">False Systems</span>
        <span class="valkka-bc-sep">/</span>
        <span class="valkka-bc-current">{@selected_repo.name}</span>

        <span
          :if={@selected_repo[:branch]}
          class="valkka-pill branch"
          title={"Branch: #{@selected_repo[:branch]}"}
        >
          {"⎇ #{@selected_repo[:branch]}"}
        </span>
        <span
          :if={Map.get(@selected_repo, :ahead, 0) > 0}
          class="valkka-pill ahead"
          title={"#{@selected_repo.ahead} commit(s) ahead — push (p)"}
        >
          {"↑ #{@selected_repo.ahead}"}
        </span>
        <span
          :if={Map.get(@selected_repo, :behind, 0) > 0}
          class="valkka-pill behind"
          title={"#{@selected_repo.behind} commit(s) behind — pull (l)"}
        >
          {"↓ #{@selected_repo.behind}"}
        </span>
        <span
          :if={@active_agent}
          class="valkka-pill agent"
          title={"#{@active_agent.name} · PID #{@active_agent.pid}"}
        >
          <span class="valkka-pulse" style="width:5px;height:5px"></span>
          {@active_agent.name}
          <span :if={@agent_elapsed} class="valkka-agent-timer">{@agent_elapsed}</span>
        </span>
        <span
          :if={Map.get(@selected_repo, :dirty_count, 0) > 0}
          class="valkka-pill changes"
          title={"#{@selected_repo.dirty_count} uncommitted change(s)"}
        >
          {"◇ #{@selected_repo.dirty_count}"}
        </span>

        <span class="valkka-spacer"></span>

        <button
          class="valkka-btn primary"
          phx-click="key:focus_commit"
          title="Focus commit message (c)"
        >
          Commit
        </button>
        <button class="valkka-btn default" phx-click="key:push" title="Push to origin (p)">
          Push
        </button>
        <button class="valkka-btn default" phx-click="key:pull" title="Pull ff-only (l)">Pull</button>
        <button class="valkka-btn ghost" phx-click="key:toggle_branch" title="New branch (b)">
          Branch
        </button>
      </div>

      <div :if={@selected_repo} class="valkka-tab-bar">
        <button
          class={"valkka-tab #{if @active_tab == "graph", do: "active"}"}
          phx-click="switch_tab"
          phx-value-tab="graph"
          title="Commit graph (1)"
        >
          Graph
        </button>
        <button
          class={"valkka-tab #{if @active_tab == "changes", do: "active"}"}
          phx-click="switch_tab"
          phx-value-tab="changes"
          title="Files & diff (2)"
        >
          Changes
          <span
            :if={@selected_repo && Map.get(@selected_repo, :dirty_count, 0) > 0}
            class="valkka-tab-count"
          >
            {@selected_repo.dirty_count}
          </span>
        </button>
      </div>

      <div :if={@selected_repo} style="flex:1;overflow:hidden;display:flex;flex-direction:column">
        <div :if={@active_tab == "graph"} class="valkka-panel active">
          {render_slot(@graph)}
        </div>
        <div :if={@active_tab == "changes"} class="valkka-panel active">
          {render_slot(@changes)}
        </div>
      </div>

      <div :if={!@selected_repo} style="display:flex;align-items:center;justify-content:center;flex:1">
        <p class="valkka-empty">Select a repo to get started</p>
      </div>
    </div>
    """
  end
end
