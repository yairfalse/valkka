defmodule ValkkaWeb.OverviewComponent do
  @moduledoc """
  Overview / command center: agents are the headline,
  dirty repos are visible, clean repos collapse to a count.
  """

  use ValkkaWeb, :live_component

  @impl true
  def update(assigns, socket) do
    repos = assigns.repos
    agents = assigns.agents

    active_agents = Enum.filter(agents, & &1.active)

    agent_paths =
      active_agents
      |> Enum.map(& &1.repo_path)
      |> MapSet.new()

    agent_by_repo = Map.new(active_agents, fn a -> {a.repo_path, a} end)

    {agent_repos, rest} = Enum.split_with(repos, &MapSet.member?(agent_paths, &1.path))
    {dirty_repos, clean_repos} = Enum.split_with(rest, &(Map.get(&1, :dirty_count, 0) > 0))

    {:ok,
     assign(socket,
       active_agents: active_agents,
       agent_by_repo: agent_by_repo,
       agent_repos: Enum.sort_by(agent_repos, & &1.name),
       dirty_repos: Enum.sort_by(dirty_repos, & &1.name),
       clean_count: length(clean_repos)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="valkka-overview">
      <%!-- Agent banner when agents are active --%>
      <div :if={@active_agents != []} class="valkka-agent-banner">
        <div class="valkka-agent-banner-icon">
          <span class="valkka-pulse"></span>
        </div>
        <div class="valkka-agent-banner-text">
          <span class="valkka-agent-banner-count">
            {length(@active_agents)} {if length(@active_agents) == 1, do: "agent", else: "agents"} working
          </span>
          <span class="valkka-agent-banner-repos">
            {Enum.map_join(@active_agents, " · ", fn a ->
              "#{a.name} on #{repo_name(a, @agent_repos)}"
            end)}
          </span>
        </div>
      </div>

      <%!-- Agent-active repos — prominent --%>
      <div
        :for={repo <- @agent_repos}
        class="valkka-ov-row agent-active"
        phx-click="select_repo"
        phx-value-path={repo.path}
      >
        <span class="valkka-ov-dot agent"></span>
        <span class="valkka-ov-name">{repo.name}</span>
        <span class="valkka-ov-branch">{"⎇ #{repo[:branch] || "—"}"}</span>
        <span class="valkka-ov-status agent-s">
          {agent_status_text(repo, @agent_by_repo)}
        </span>
        <span class="valkka-ov-when">now</span>
      </div>

      <%!-- Dirty repos — visible but quieter --%>
      <div :if={@dirty_repos != []} class="valkka-ov-sep">Changes</div>

      <div
        :for={repo <- @dirty_repos}
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

      <%!-- Clean repos collapsed to a single summary --%>
      <div :if={@clean_count > 0} class="valkka-ov-sep">
        {@clean_count} clean
      </div>

      <div
        :if={@active_agents == [] && @dirty_repos == [] && @clean_count == 0}
        class="valkka-empty"
      >
        No repos monitored
      </div>
    </div>
    """
  end

  defp agent_status_text(repo, agent_by_repo) do
    agent = Map.get(agent_by_repo, repo.path)
    name = if agent, do: agent.name, else: "agent"
    dirty = Map.get(repo, :dirty_count, 0)

    if dirty > 0 do
      "#{name} · #{dirty} changes"
    else
      "#{name} working"
    end
  end

  defp repo_name(agent, repos) do
    repo = Enum.find(repos, &(&1.path == agent.repo_path))
    if repo, do: repo.name, else: Path.basename(agent.repo_path || "unknown")
  end
end
