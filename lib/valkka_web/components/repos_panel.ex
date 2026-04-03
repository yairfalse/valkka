defmodule ValkkaWeb.Components.ReposPanel do
  @moduledoc """
  Left sidebar: workspace header, priority-sorted repo sections.

  Sections:
  1. Workstreams — repos with active agents (pulse dot)
  2. Attention — dirty/ahead/error repos without agents (amber/blue/red dots)
  3. Quiet — everything else, collapsed to a count with expand toggle
  """

  use Phoenix.Component

  attr :repos, :list, required: true
  attr :selected_path, :string, default: nil
  attr :active_view, :string, default: "repo"
  attr :agents, :list, default: []
  attr :agent_start_times, :map, default: %{}
  attr :sidebar_quiet_expanded, :boolean, default: false

  def repos_panel(assigns) do
    agent_paths =
      assigns.agents
      |> Enum.filter(& &1.active)
      |> Enum.map(& &1.repo_path)
      |> MapSet.new()

    {workstream_repos, rest} =
      Enum.split_with(assigns.repos, &MapSet.member?(agent_paths, &1.path))

    {attention_repos, quiet_repos} =
      Enum.split_with(rest, fn repo ->
        Map.get(repo, :status) == :error ||
          Map.get(repo, :dirty_count, 0) > 0 ||
          Map.get(repo, :ahead, 0) > 0
      end)

    agent_count = MapSet.size(agent_paths)

    assigns =
      assigns
      |> assign(:workstream_repos, Enum.sort_by(workstream_repos, & &1.name))
      |> assign(:attention_repos, Enum.sort_by(attention_repos, & &1.name))
      |> assign(:quiet_repos, Enum.sort_by(quiet_repos, & &1.name))
      |> assign(:quiet_count, length(quiet_repos))
      |> assign(:agent_count, agent_count)

    ~H"""
    <aside class="valkka-sidebar">
      <div class="valkka-ws">
        <div class="valkka-ws-icon">
          <svg viewBox="0 0 200 200" width="22" height="22" xmlns="http://www.w3.org/2000/svg">
            <rect x="-1.62" y="-0.04" width="203.24" height="202.25" fill="#0d0d10" />
            <path
              fill="white"
              d="M100,19.81c-44.29,0-80.19,35.9-80.19,80.19s35.9,80.19,80.19,80.19,80.19-35.9,80.19-80.19S144.29,19.81,100,19.81ZM145.96,141.17H54.04V57.8l30.95,4.8v-13.14l60.96,11.03v80.68Z"
            />
          </svg>
        </div>
        <span class="valkka-ws-name">False Systems</span>
        <span :if={@agent_count > 0} class="valkka-ws-live">
          <span class="valkka-pulse"></span>
          {@agent_count}
        </span>
      </div>

      <.link
        navigate={"/"}
        class={"valkka-nav #{if @active_view == "overview", do: "active"}"}
        title="All repos at a glance"
      >
        <span class="valkka-nav-icon">
          <svg width="13" height="13" viewBox="0 0 13 13" fill="none">
            <rect x=".5" y=".5" width="5" height="5" rx="1.2" fill="currentColor" /><rect
              x="7.5"
              y=".5"
              width="5"
              height="5"
              rx="1.2"
              fill="currentColor"
            /><rect x=".5" y="7.5" width="5" height="5" rx="1.2" fill="currentColor" /><rect
              x="7.5"
              y="7.5"
              width="5"
              height="5"
              rx="1.2"
              fill="currentColor"
              />
          </svg>
        </span>
        <span class="valkka-nav-label">Command</span>
      </.link>

      <div class="valkka-sb-sep"></div>

      <div style="flex: 1; overflow-y: auto;">
        <%!-- Workstreams section --%>
        <div :if={@workstream_repos != []} class="valkka-sidebar-section">
          <span class="valkka-sb-label">Workstreams</span>
        </div>

        <div
          :for={repo <- @workstream_repos}
          class={"valkka-nav #{if @active_view == "repo" && repo.path == @selected_path, do: "active"}"}
          phx-click="select_repo"
          phx-value-path={repo.path}
          title={repo_tooltip(repo, @agents)}
        >
          <span class="valkka-dot agent" />
          <span class="valkka-nav-label">{repo.name}</span>
          <span class="valkka-nav-count accent">
            {agent_duration(@agent_start_times, @agents, repo.path)}
          </span>
          <span :if={Map.get(repo, :dirty_count, 0) > 0} class="valkka-nav-count">
            {repo.dirty_count}
          </span>
        </div>

        <%!-- Attention section --%>
        <div :if={@attention_repos != []} class="valkka-sidebar-section">
          <span class="valkka-sb-label">Attention</span>
        </div>

        <div
          :for={repo <- @attention_repos}
          class={"valkka-nav #{if @active_view == "repo" && repo.path == @selected_path, do: "active"}"}
          phx-click="select_repo"
          phx-value-path={repo.path}
          title={repo_tooltip(repo, @agents)}
        >
          <span class={"valkka-dot #{attention_dot_class(repo)}"} />
          <span class="valkka-nav-label">{repo.name}</span>
          <span :if={Map.get(repo, :dirty_count, 0) > 0} class="valkka-nav-count">
            {repo.dirty_count}
          </span>
        </div>

        <%!-- Quiet section --%>
        <div :if={@quiet_count > 0} class="valkka-sidebar-section">
          <span
            class="valkka-quiet-toggle"
            phx-click="toggle_sidebar_quiet"
          >
            <span class="valkka-quiet-chevron">{if @sidebar_quiet_expanded, do: "▾", else: "▸"}</span>
            {@quiet_count} quiet
          </span>
        </div>

        <div :if={@sidebar_quiet_expanded}>
          <div
            :for={repo <- @quiet_repos}
            class={"valkka-nav #{if @active_view == "repo" && repo.path == @selected_path, do: "active"}"}
            phx-click="select_repo"
            phx-value-path={repo.path}
            title={repo_tooltip(repo, @agents)}
          >
            <span class="valkka-dot clean" />
            <span class="valkka-nav-label">{repo.name}</span>
          </div>
        </div>

        <div :if={@repos == []} class="valkka-empty">
          Scanning...
        </div>
      </div>
    </aside>
    """
  end

  defp attention_dot_class(%{status: :error}), do: "error"
  defp attention_dot_class(%{ahead: n}) when is_integer(n) and n > 0, do: "ahead"
  defp attention_dot_class(%{dirty_count: n}) when n > 0, do: "dirty"
  defp attention_dot_class(_), do: "dirty"

  defp agent_duration(start_times, agents, path) do
    agent = Enum.find(agents, fn a -> a.active && a.repo_path == path end)

    if agent do
      key = {agent.pid, agent.repo_path}

      case Map.get(start_times, key) do
        nil -> ""
        started_at -> format_duration(DateTime.diff(DateTime.utc_now(), started_at, :second))
      end
    else
      ""
    end
  end

  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_duration(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"
  defp format_duration(seconds), do: "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"

  defp repo_tooltip(repo, agents) do
    branch = Map.get(repo, :branch) || "detached"
    dirty = Map.get(repo, :dirty_count, 0)
    agent = Enum.find(agents, fn a -> a.active && a.repo_path == repo.path end)
    agent_text = if agent, do: " · #{agent.name}", else: ""

    status =
      cond do
        Map.get(repo, :status) == :error -> " · error"
        dirty > 0 -> " · #{dirty} change#{if dirty == 1, do: "", else: "s"}"
        true -> " · clean"
      end

    "#{repo.name} (#{branch}#{status}#{agent_text})\n#{repo.path}"
  end
end
