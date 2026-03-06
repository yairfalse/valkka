defmodule ValkkaWeb.StatusComponent do
  @moduledoc """
  Cross-repo command center: repo grid + agent overview.
  """

  use ValkkaWeb, :live_component

  @impl true
  def update(assigns, socket) do
    agents = assigns.agents
    repos = Map.get(assigns, :repos, [])

    # Build agent lookup by repo path
    agent_by_repo =
      agents
      |> Enum.group_by(& &1.repo_path)

    # Sort repos: agent-active first, then by name
    sorted_repos =
      Enum.sort_by(repos, fn r ->
        has_agent = Map.has_key?(agent_by_repo, r.path)
        {!has_agent, r.name}
      end)

    {active_agents, idle_agents} = Enum.split_with(agents, & &1.active)
    dirty_count = Enum.count(repos, &(Map.get(&1, :dirty_count, 0) > 0))

    {:ok,
     socket
     |> assign(assigns)
     |> assign(
       sorted_repos: sorted_repos,
       agent_by_repo: agent_by_repo,
       active_count: length(active_agents),
       idle_count: length(idle_agents),
       dirty_count: dirty_count,
       total_repos: length(repos)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="valkka-status">
      <div class="valkka-status-header">
        <span :if={@active_count > 0} class="valkka-status-badge active">
          {@active_count} active
        </span>
        <span :if={@idle_count > 0} class="valkka-status-badge idle">
          {@idle_count} idle
        </span>
        <span :if={@active_count == 0 and @idle_count == 0} class="valkka-status-badge dim">
          no agents
        </span>
        <span class="valkka-status-sep">·</span>
        <span class={"valkka-status-badge #{if @dirty_count > 0, do: "dirty", else: "dim"}"}>
          {@dirty_count}/{@total_repos} dirty
        </span>
      </div>

      <div class="valkka-status-grid">
        <div
          :for={repo <- @sorted_repos}
          class="valkka-status-repo clickable"
          phx-click="select_repo"
          phx-value-path={repo.path}
        >
          <span class={"valkka-status-dot #{repo_status_class(repo)}"} />
          <span class="valkka-status-repo-name">{repo.name}</span>
          <span class="valkka-status-repo-branch">{repo[:branch] || "—"}</span>
          <span :if={Map.get(repo, :dirty_count, 0) > 0} class="valkka-dirty-count">
            {repo.dirty_count}
          </span>
          <span :if={agent_info = Map.get(@agent_by_repo, repo.path)} class="valkka-status-agent">
            {agent_label(agent_info)}
          </span>
        </div>
      </div>

      <div :if={@sorted_repos == []} class="valkka-empty">
        No repos monitored
      </div>
    </div>
    """
  end

  defp repo_status_class(%{status: :error}), do: "error"
  defp repo_status_class(%{agent_active: true}), do: "clean"
  defp repo_status_class(%{dirty_count: n}) when n > 0, do: "dirty"
  defp repo_status_class(_), do: "dim"

  defp agent_label(agents) do
    active = Enum.count(agents, & &1.active)

    if active > 0 do
      "▶ #{active} active"
    else
      "#{length(agents)} idle"
    end
  end
end
