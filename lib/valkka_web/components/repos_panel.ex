defmodule ValkkaWeb.Components.ReposPanel do
  @moduledoc """
  Left sidebar: workspace header, top-level nav (Fleet/Agents/Activity),
  repo list, team presence footer.
  """

  use Phoenix.Component

  attr :repos, :list, required: true
  attr :selected_path, :string, default: nil
  attr :active_view, :string, default: "fleet"
  attr :agent_count, :integer, default: 0
  attr :presence_users, :list, default: []

  def repos_panel(assigns) do
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

      <div
        class={"valkka-nav #{if @active_view == "fleet", do: "active"}"}
        phx-click="switch_view"
        phx-value-view="fleet"
        title="Fleet — all repos at a glance"
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
        <span class="valkka-nav-label">Fleet</span>
      </div>

      <div
        class={"valkka-nav #{if @active_view == "agents", do: "active"}"}
        phx-click="switch_view"
        phx-value-view="agents"
        title="Active and idle AI agents"
      >
        <span class="valkka-nav-icon">
          <svg width="13" height="13" viewBox="0 0 13 13" fill="none">
            <circle cx="6.5" cy="4.5" r="2.2" stroke="currentColor" stroke-width="1.2" /><path
              d="M1.5 12c0-2.761 2.239-5 5-5s5 2.239 5 5"
              stroke="currentColor"
              stroke-width="1.2"
              stroke-linecap="round"
            />
          </svg>
        </span>
        <span class="valkka-nav-label">Agents</span>
        <span :if={@agent_count > 0} class="valkka-nav-count accent">{@agent_count}</span>
      </div>

      <div
        class={"valkka-nav #{if @active_view == "activity", do: "active"}"}
        phx-click="switch_view"
        phx-value-view="activity"
        title="Activity stream"
      >
        <span class="valkka-nav-icon">
          <svg width="13" height="13" viewBox="0 0 13 13" fill="none">
            <path
              d="M2 3h9M2 6.5h6M2 10h8"
              stroke="currentColor"
              stroke-width="1.2"
              stroke-linecap="round"
            />
          </svg>
        </span>
        <span class="valkka-nav-label">Activity</span>
      </div>

      <div class="valkka-sb-sep"></div>
      <div class="valkka-sb-label">Repos</div>

      <div style="flex: 1; overflow-y: auto;">
        <div
          :for={repo <- @repos}
          class={"valkka-nav #{if @active_view == "repo" && repo.path == @selected_path, do: "active"}"}
          phx-click="select_repo"
          phx-value-path={repo.path}
          title={repo_tooltip(repo)}
        >
          <span class={"valkka-dot #{dot_class(repo)}"} />
          <span class="valkka-nav-label">{repo.name}</span>
          <span :if={Map.get(repo, :agent_active, false)} class="valkka-nav-count accent">
            {Map.get(repo, :dirty_count, 0)}
          </span>
          <span
            :if={!Map.get(repo, :agent_active, false) && Map.get(repo, :dirty_count, 0) > 0}
            class="valkka-nav-count"
          >
            {repo.dirty_count}
          </span>
        </div>
        <div :if={@repos == []} class="valkka-empty">
          Scanning...
        </div>
      </div>

      <div class="valkka-sb-footer">
        <div :if={@presence_users != []} class="valkka-sb-presence">
          <span
            :for={user <- Enum.take(@presence_users, 4)}
            class="valkka-presence-dot"
            style={"background:#{user.color}"}
            title={user.user_name}
          />
          <span class="valkka-sb-presence-label">
            {length(@presence_users)} online
          </span>
        </div>
        <div class="valkka-nav">
          <span class="valkka-nav-icon">
            <svg width="13" height="13" viewBox="0 0 13 13" fill="none">
              <circle cx="6.5" cy="6.5" r="5" stroke="currentColor" /><path
                d="M6.5 3.5v3l2 2"
                stroke="currentColor"
                stroke-width="1.2"
                stroke-linecap="round"
              />
            </svg>
          </span>
          <span class="valkka-nav-label">Settings</span>
        </div>
      </div>
    </aside>
    """
  end

  defp dot_class(%{status: :error}), do: "error"
  defp dot_class(%{agent_active: true}), do: "agent"
  defp dot_class(%{dirty_count: n}) when n > 0, do: "dirty"
  defp dot_class(_), do: "clean"

  defp repo_tooltip(repo) do
    branch = Map.get(repo, :branch) || "detached"
    dirty = Map.get(repo, :dirty_count, 0)
    agent = if Map.get(repo, :agent_active, false), do: " · agent active", else: ""

    status =
      cond do
        Map.get(repo, :status) == :error -> " · error"
        dirty > 0 -> " · #{dirty} change#{if dirty == 1, do: "", else: "s"}"
        true -> " · clean"
      end

    "#{repo.name} (#{branch}#{status}#{agent})\n#{repo.path}"
  end
end
