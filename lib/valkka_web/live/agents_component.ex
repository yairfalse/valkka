defmodule ValkkaWeb.AgentsComponent do
  @moduledoc """
  Agents view: flat list of active and recent agents.
  """

  use ValkkaWeb, :live_component

  @impl true
  def update(assigns, socket) do
    agents = assigns.agents
    repos = assigns.repos

    repo_names =
      Map.new(repos, fn r -> {r.path, r.name} end)

    {active, recent} = Enum.split_with(agents, & &1.active)

    {:ok,
     assign(socket,
       active_agents: active,
       recent_agents: recent,
       repo_names: repo_names
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="valkka-overview">
      <div class="valkka-ov-heading">Agents</div>

      <div :if={@active_agents != []} class="valkka-ov-sep">Active</div>

      <div :for={agent <- @active_agents} class="valkka-ov-row agent-active">
        <span class="valkka-ov-dot agent"></span>
        <span class="valkka-ov-name">{agent.name}</span>
        <span class="valkka-ov-branch">{repo_label(agent, @repo_names)} · pid {agent.pid}</span>
        <span class="valkka-ov-status agent-s">active</span>
        <span class="valkka-ov-when"></span>
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
end
