defmodule ValkkaWeb.AgentsComponent do
  @moduledoc """
  Agents view: flat list of active and recent agents.
  """

  use ValkkaWeb, :live_component

  @impl true
  def update(assigns, socket) do
    agents = assigns.agents
    repos = assigns.repos
    activity = Map.get(assigns, :activity, [])
    agent_start_times = Map.get(assigns, :agent_start_times, %{})

    repo_names =
      Map.new(repos, fn r -> {r.path, r.name} end)

    {active, recent} = Enum.split_with(agents, & &1.active)

    # Build per-agent activity timelines
    agent_timelines =
      Map.new(active, fn agent ->
        timeline =
          activity
          |> Enum.filter(fn e ->
            e.repo_path == agent.repo_path &&
              (Map.get(e.detail, :agent_name) == agent.name ||
                 e.type in [:agent_started, :agent_stopped])
          end)
          |> Enum.take(5)

        {agent.pid, timeline}
      end)

    # Detect conflicts: multiple agents in same repo
    repo_agents = Enum.group_by(active, & &1.repo_path)

    conflicts =
      repo_agents
      |> Enum.filter(fn {_path, agents} -> length(agents) > 1 end)
      |> Enum.map(fn {path, agents} ->
        %{
          repo_path: path,
          repo_name: Map.get(repo_names, path, Path.basename(path)),
          agents: agents
        }
      end)

    {:ok,
     assign(socket,
       active_agents: active,
       recent_agents: recent,
       repo_names: repo_names,
       agent_timelines: agent_timelines,
       agent_start_times: agent_start_times,
       conflicts: conflicts
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="valkka-agents-view">
      <div class="valkka-ov-heading">Agents</div>

      <%!-- Conflict warnings --%>
      <div :for={conflict <- @conflicts} class="valkka-agents-conflict">
        <span class="valkka-agents-conflict-icon">⚠</span>
        <span>
          {length(conflict.agents)} agents in <strong>{conflict.repo_name}</strong>: {Enum.map_join(
            conflict.agents,
            ", ",
            & &1.name
          )}
        </span>
      </div>

      <div :if={@active_agents != []} class="valkka-ov-sep">Active</div>

      <div :for={agent <- @active_agents} class="valkka-agents-card">
        <div class="valkka-agents-card-header">
          <span class="valkka-ov-dot agent"></span>
          <span class="valkka-agents-card-name">{agent.name}</span>
          <span class="valkka-agents-card-repo">
            {repo_label(agent, @repo_names)}
          </span>
          <span class="valkka-agents-card-elapsed">
            {agent_elapsed(agent, @agent_start_times)}
          </span>
          <span class="valkka-agents-card-pid">pid {agent.pid}</span>
        </div>

        <%!-- Mini timeline --%>
        <div :if={timeline = Map.get(@agent_timelines, agent.pid, [])} class="valkka-agents-timeline">
          <div :for={entry <- timeline} class={"valkka-agents-timeline-entry type-#{entry.type}"}>
            <span class="valkka-agents-timeline-icon">{type_icon(entry.type)}</span>
            <span class="valkka-agents-timeline-summary">{entry.summary}</span>
            <span class="valkka-agents-timeline-time">{format_time(entry.timestamp)}</span>
          </div>
          <div :if={timeline == []} class="valkka-agents-timeline-empty">
            No recent activity
          </div>
        </div>
      </div>

      <div :if={@recent_agents != []} class="valkka-ov-sep">Recent</div>

      <div :for={agent <- @recent_agents} class="valkka-ov-row">
        <span class="valkka-ov-dot clean"></span>
        <span class="valkka-ov-name" style="color:var(--t2)">{agent.name}</span>
        <span class="valkka-ov-branch">{repo_label(agent, @repo_names)} · pid {agent.pid}</span>
        <span class="valkka-ov-status dirty-s">ended</span>
        <span class="valkka-ov-when"></span>
      </div>

      <div :if={@active_agents == [] && @recent_agents == []} class="valkka-empty">
        No agents detected
      </div>
    </div>
    """
  end

  defp repo_label(agent, repo_names) do
    Map.get(repo_names, agent.repo_path, Path.basename(agent.repo_path || "unknown"))
  end

  defp agent_elapsed(agent, start_times) do
    key = {agent.pid, agent.repo_path}

    case Map.get(start_times, key) do
      nil ->
        ""

      started_at ->
        seconds = DateTime.diff(DateTime.utc_now(), started_at, :second)
        format_duration(seconds)
    end
  end

  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_duration(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"
  defp format_duration(seconds), do: "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"

  defp type_icon(:files_changed), do: "◇"
  defp type_icon(:commit), do: "○"
  defp type_icon(:branch_switched), do: "⎇"
  defp type_icon(:repo_status), do: "◈"
  defp type_icon(:pushed), do: "↑"
  defp type_icon(:pulled), do: "↓"
  defp type_icon(:agent_started), do: "●"
  defp type_icon(:agent_stopped), do: "○"
  defp type_icon(_), do: "·"

  defp format_time(nil), do: ""
  defp format_time(dt), do: Calendar.strftime(dt, "%H:%M")
end
