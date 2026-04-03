defmodule ValkkaWeb.FleetComponent do
  @moduledoc """
  Fleet view: Linear-style list of all repos.
  Compact rows, column-aligned, scannable at a glance.
  """

  use ValkkaWeb, :live_component

  @impl true
  def update(assigns, socket) do
    repos = assigns.repos
    agents = assigns.agents
    agent_start_times = assigns.agent_start_times
    activity = Map.get(assigns, :activity, [])

    active_agents = Enum.filter(agents, & &1.active)
    agent_by_repo = Map.new(active_agents, fn a -> {a.repo_path, a} end)

    # Last activity per repo
    last_activity_by_repo =
      activity
      |> Enum.group_by(& &1.repo_path)
      |> Map.new(fn {path, entries} -> {path, List.first(entries)} end)

    sorted =
      Enum.sort_by(repos, fn repo ->
        has_agent = Map.has_key?(agent_by_repo, repo.path)
        dirty = Map.get(repo, :dirty_count, 0)
        {!has_agent, dirty == 0, repo.name}
      end)

    total = length(repos)
    with_changes = Enum.count(repos, &(Map.get(&1, :dirty_count, 0) > 0))
    with_agents = length(active_agents)

    {:ok,
     assign(socket,
       repos: sorted,
       agent_by_repo: agent_by_repo,
       agent_start_times: agent_start_times,
       last_activity_by_repo: last_activity_by_repo,
       total: total,
       with_changes: with_changes,
       with_agents: with_agents
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="valkka-fleet">
      <%!-- Status bar --%>
      <div class="valkka-fleet-bar">
        <span :if={@with_agents > 0} class="valkka-fleet-bar-item active">
          <span class="valkka-pulse"></span>
          {@with_agents} active
        </span>
        <span :if={@with_changes > 0} class="valkka-fleet-bar-item warn">
          {@with_changes} with changes
        </span>
        <span class="valkka-fleet-bar-item muted">
          {@total} repositories
        </span>
      </div>

      <%!-- Column headers --%>
      <div class="valkka-fleet-head">
        <span class="valkka-fleet-col col-status"></span>
        <span class="valkka-fleet-col col-name">Repository</span>
        <span class="valkka-fleet-col col-branch">Branch</span>
        <span class="valkka-fleet-col col-changes">Changes</span>
        <span class="valkka-fleet-col col-sync">Sync</span>
        <span class="valkka-fleet-col col-agent">Agent</span>
        <span class="valkka-fleet-col col-activity">Last Activity</span>
      </div>

      <%!-- Rows --%>
      <div class="valkka-fleet-list">
        <div
          :for={repo <- @repos}
          class={"valkka-fleet-row #{row_class(repo, @agent_by_repo)}"}
          phx-click="select_repo"
          phx-value-path={repo.path}
        >
          <span class="valkka-fleet-col col-status">
            <span class={"valkka-fleet-dot #{dot_class(repo, @agent_by_repo)}"}></span>
          </span>

          <span class="valkka-fleet-col col-name">
            {repo.name}
          </span>

          <span class="valkka-fleet-col col-branch">
            {repo[:branch] || "detached"}
          </span>

          <span class={"valkka-fleet-col col-changes #{if Map.get(repo, :dirty_count, 0) > 0, do: "has-changes"}"}>
            {change_text(repo)}
          </span>

          <span class="valkka-fleet-col col-sync">
            <span :if={Map.get(repo, :ahead, 0) > 0} class="valkka-fleet-sync ahead">
              {"↑#{repo.ahead}"}
            </span>
            <span :if={Map.get(repo, :behind, 0) > 0} class="valkka-fleet-sync behind">
              {"↓#{repo.behind}"}
            </span>
            <span
              :if={Map.get(repo, :ahead, 0) == 0 && Map.get(repo, :behind, 0) == 0}
              class="valkka-fleet-sync even"
            >
              —
            </span>
          </span>

          <span class="valkka-fleet-col col-agent">
            <span :if={agent = Map.get(@agent_by_repo, repo.path)} class="valkka-fleet-agent-tag">
              <span class="valkka-pulse"></span>
              {agent.name}
              <span
                :if={elapsed = agent_elapsed(repo.path, @agent_by_repo, @agent_start_times)}
                class="valkka-fleet-agent-time"
              >
                {elapsed}
              </span>
            </span>
          </span>

          <span class="valkka-fleet-col col-activity">
            {activity_text(@last_activity_by_repo, repo.path)}
          </span>
        </div>
      </div>

      <div :if={@repos == []} class="valkka-empty" style="padding:48px 0">
        Scanning workspace...
      </div>
    </div>
    """
  end

  defp row_class(repo, agent_by_repo) do
    cond do
      Map.has_key?(agent_by_repo, repo.path) -> "row-agent"
      Map.get(repo, :status) == :error -> "row-error"
      Map.get(repo, :dirty_count, 0) > 0 -> "row-dirty"
      true -> "row-clean"
    end
  end

  defp dot_class(repo, agent_by_repo) do
    cond do
      Map.has_key?(agent_by_repo, repo.path) -> "dot-agent"
      Map.get(repo, :status) == :error -> "dot-error"
      Map.get(repo, :dirty_count, 0) > 0 -> "dot-dirty"
      true -> "dot-clean"
    end
  end

  defp change_text(repo) do
    count = Map.get(repo, :dirty_count, 0)
    if count > 0, do: "#{count}", else: "—"
  end

  defp activity_text(last_activity_by_repo, repo_path) do
    case Map.get(last_activity_by_repo, repo_path) do
      nil -> ""
      entry -> entry.summary
    end
  end

  defp agent_elapsed(repo_path, agent_by_repo, start_times) do
    agent = Map.get(agent_by_repo, repo_path)

    if agent do
      key = {agent.pid, agent.repo_path}

      case Map.get(start_times, key) do
        nil ->
          nil

        started_at ->
          seconds = DateTime.diff(DateTime.utc_now(), started_at, :second)
          format_duration(seconds)
      end
    end
  end

  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_duration(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"
  defp format_duration(seconds), do: "#{div(seconds, 3600)}h#{div(rem(seconds, 3600), 60)}m"
end
