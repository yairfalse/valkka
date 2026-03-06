defmodule ValkkaWeb.OverviewComponent do
  @moduledoc """
  Overview view: flat list of all repos grouped by status.
  Agent-active repos first, then changed, then clean.
  """

  use ValkkaWeb, :live_component

  @impl true
  def update(assigns, socket) do
    repos = assigns.repos
    agents = assigns.agents

    agent_paths =
      agents
      |> Enum.filter(& &1.active)
      |> Enum.map(& &1.repo_path)
      |> MapSet.new()

    {agent_repos, rest} = Enum.split_with(repos, &MapSet.member?(agent_paths, &1.path))
    {dirty_repos, clean_repos} = Enum.split_with(rest, &(Map.get(&1, :dirty_count, 0) > 0))

    {:ok,
     assign(socket,
       agent_repos: Enum.sort_by(agent_repos, & &1.name),
       dirty_repos: Enum.sort_by(dirty_repos, & &1.name),
       clean_repos: Enum.sort_by(clean_repos, & &1.name),
       total: length(repos)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="valkka-overview">
      <div class="valkka-ov-heading">All repos · False Systems</div>

      <div :for={repo <- @agent_repos}
        class="valkka-ov-row agent-active"
        phx-click="select_repo"
        phx-value-path={repo.path}
      >
        <span class="valkka-ov-dot agent"></span>
        <span class="valkka-ov-name">{repo.name}</span>
        <span class="valkka-ov-branch">{"⎇ #{repo[:branch] || "—"}"}</span>
        <span class="valkka-ov-status agent-s">{"agent · #{Map.get(repo, :dirty_count, 0)} changes"}</span>
        <span class="valkka-ov-when">now</span>
      </div>

      <div :if={@dirty_repos != []} class="valkka-ov-sep">Changes</div>

      <div :for={repo <- @dirty_repos}
        class="valkka-ov-row"
        phx-click="select_repo"
        phx-value-path={repo.path}
      >
        <span class="valkka-ov-dot dirty"></span>
        <span class="valkka-ov-name">{repo.name}</span>
        <span class="valkka-ov-branch">{"⎇ #{repo[:branch] || "—"}"}</span>
        <span class="valkka-ov-status dirty-s">{"#{Map.get(repo, :dirty_count, 0)} changes"}</span>
        <span class="valkka-ov-when"></span>
      </div>

      <div :if={@clean_repos != []} class="valkka-ov-sep">Clean</div>

      <div :for={repo <- @clean_repos}
        class="valkka-ov-row"
        phx-click="select_repo"
        phx-value-path={repo.path}
      >
        <span class="valkka-ov-dot clean"></span>
        <span class="valkka-ov-name">{repo.name}</span>
        <span class="valkka-ov-branch">{"⎇ #{repo[:branch] || "—"}"}</span>
        <span class="valkka-ov-status">clean</span>
        <span class="valkka-ov-when"></span>
      </div>

      <div :if={@total == 0} class="valkka-empty">No repos monitored</div>
    </div>
    """
  end
end
