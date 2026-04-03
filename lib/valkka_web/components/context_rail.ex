defmodule ValkkaWeb.Components.ContextRail do
  @moduledoc """
  Right panel: adaptive context rail that changes content
  based on the active view and current selection.
  """

  use Phoenix.Component

  attr :active_view, :string, default: "fleet"
  attr :active_tab, :string, default: "graph"
  attr :activity, :list, default: []
  attr :selected_commit, :map, default: nil
  attr :commit_files, :list, default: []
  attr :selected_repo, :map, default: nil
  attr :agents, :list, default: []
  attr :presence_users, :list, default: []
  attr :user_id, :string, default: nil
  attr :review_summary, :map, default: %{total: 0, reviewed: 0, pending: 0}

  def context_rail(assigns) do
    ~H"""
    <aside class="valkka-context-rail">
      <div class="valkka-cr-header">
        {rail_title(@active_view, @active_tab)}
      </div>

      <div class="valkka-cr-body">
        <%= case {@active_view, @active_tab} do %>
          <% {"fleet", _} -> %>
            <.fleet_rail
              activity={Enum.take(@activity, 12)}
              presence_users={@presence_users}
              agents={@agents}
            />
          <% {"repo", "graph"} -> %>
            <.graph_rail
              selected_commit={@selected_commit}
              commit_files={@commit_files}
              activity={repo_activity(@activity, @selected_repo)}
            />
          <% {"repo", "changes"} -> %>
            <.changes_rail selected_repo={@selected_repo} />
          <% {"repo", "review"} -> %>
            <.review_rail review_summary={@review_summary} />
          <% {"agents", _} -> %>
            <.agents_rail agents={@agents} />
          <% {"activity", _} -> %>
            <.activity_rail />
          <% _ -> %>
            <div class="valkka-empty">No context</div>
        <% end %>
      </div>
    </aside>
    """
  end

  # ── Fleet rail ──

  defp fleet_rail(assigns) do
    active_agents = Enum.filter(assigns.agents, & &1.active)
    assigns = put_assign(assigns, :active_agents, active_agents)

    ~H"""
    <%!-- Active agents section --%>
    <div :if={@active_agents != []} class="valkka-cr-section">
      <div class="valkka-cr-section-title">Active Agents</div>
      <div :for={agent <- @active_agents} class="valkka-cr-agent-row">
        <div class="valkka-cr-agent-row-top">
          <span class="valkka-pulse" style="width:5px;height:5px"></span>
          <span class="valkka-cr-agent-name">{agent.name}</span>
        </div>
        <div class="valkka-cr-agent-row-bottom">
          {Path.basename(agent.repo_path || "")}
        </div>
      </div>
    </div>

    <%!-- Team --%>
    <div :if={@presence_users != []} class="valkka-cr-section">
      <div class="valkka-cr-section-title">Team</div>
      <div :for={user <- @presence_users} class="valkka-cr-presence-user">
        <span class="valkka-presence-dot" style={"background:#{user.color}"} />
        <span class="valkka-cr-presence-name">{user.user_name}</span>
        <span class="valkka-cr-presence-viewing">{viewing_label(user.viewing)}</span>
      </div>
    </div>

    <%!-- Recent activity --%>
    <div class="valkka-cr-section">
      <div class="valkka-cr-section-title">Recent</div>
      <div :if={@activity == []} class="valkka-cr-empty-hint">Waiting for activity...</div>
      <div :for={entry <- @activity} class={"valkka-cr-event #{event_accent(entry.type)}"}>
        <div class="valkka-cr-event-left">
          <span class="valkka-cr-event-dot"></span>
        </div>
        <div class="valkka-cr-event-body">
          <span class="valkka-cr-event-repo">{entry.repo}</span>
          <span class="valkka-cr-event-summary">{entry.summary}</span>
        </div>
        <span class="valkka-cr-event-time">{format_time(entry.timestamp)}</span>
      </div>
    </div>
    """
  end

  # ── Graph rail ──

  defp graph_rail(assigns) do
    ~H"""
    <div :if={@selected_commit} class="valkka-cr-section">
      <div class="valkka-cr-section-title">Commit</div>
      <div class="valkka-cr-commit">
        <div class="valkka-cr-commit-oid">{@selected_commit.short_oid}</div>
        <div class="valkka-cr-commit-msg">{@selected_commit.message}</div>
        <div class="valkka-cr-commit-meta">
          {@selected_commit.author}
        </div>
        <div :if={@selected_commit.branches != []} class="valkka-cr-commit-branches">
          <span :for={b <- @selected_commit.branches} class="valkka-cr-branch-badge">{b}</span>
        </div>
      </div>
      <div :if={@commit_files != []} class="valkka-cr-commit-files-section">
        <div class="valkka-cr-section-title" style="margin-top:12px">
          Files ({length(@commit_files)})
        </div>
        <div :for={file <- @commit_files} class="valkka-cr-commit-file">
          <span class={"valkka-cr-file-status #{file.status}"}>{status_letter(file.status)}</span>
          <span class="valkka-cr-file-path">{file.path}</span>
        </div>
      </div>
    </div>

    <div :if={!@selected_commit} class="valkka-cr-section">
      <div class="valkka-cr-section-title">Repo Activity</div>
      <div :if={@activity == []} class="valkka-cr-empty-hint">No recent activity</div>
      <div
        :for={entry <- Enum.take(@activity, 10)}
        class={"valkka-cr-event #{event_accent(entry.type)}"}
      >
        <div class="valkka-cr-event-left">
          <span class="valkka-cr-event-dot"></span>
        </div>
        <div class="valkka-cr-event-body">
          <span class="valkka-cr-event-summary">{entry.summary}</span>
        </div>
        <span class="valkka-cr-event-time">{format_time(entry.timestamp)}</span>
      </div>
    </div>
    """
  end

  # ── Changes rail ──

  defp changes_rail(assigns) do
    ~H"""
    <div class="valkka-cr-section">
      <div class="valkka-cr-section-title">Working Tree</div>
      <div :if={@selected_repo} class="valkka-cr-stats-grid">
        <div class="valkka-cr-stat-card">
          <span class={"valkka-cr-stat-num #{if Map.get(@selected_repo, :dirty_count, 0) > 0, do: "warn"}"}>
            {Map.get(@selected_repo, :dirty_count, 0)}
          </span>
          <span class="valkka-cr-stat-label">uncommitted</span>
        </div>
        <div class="valkka-cr-stat-card">
          <span class={"valkka-cr-stat-num #{if Map.get(@selected_repo, :ahead, 0) > 0, do: "ahead"}"}>
            {Map.get(@selected_repo, :ahead, 0)}
          </span>
          <span class="valkka-cr-stat-label">ahead</span>
        </div>
        <div class="valkka-cr-stat-card">
          <span class={"valkka-cr-stat-num #{if Map.get(@selected_repo, :behind, 0) > 0, do: "behind"}"}>
            {Map.get(@selected_repo, :behind, 0)}
          </span>
          <span class="valkka-cr-stat-label">behind</span>
        </div>
      </div>
    </div>

    <div class="valkka-cr-section">
      <div class="valkka-cr-section-title">Shortcuts</div>
      <div class="valkka-cr-shortcuts">
        <div class="valkka-cr-shortcut"><kbd>s</kbd> stage</div>
        <div class="valkka-cr-shortcut"><kbd>u</kbd> unstage</div>
        <div class="valkka-cr-shortcut"><kbd>a</kbd> stage all</div>
        <div class="valkka-cr-shortcut"><kbd>c</kbd> commit</div>
        <div class="valkka-cr-shortcut"><kbd>d</kbd> discard</div>
        <div class="valkka-cr-shortcut"><kbd>p</kbd> push</div>
        <div class="valkka-cr-shortcut"><kbd>l</kbd> pull</div>
      </div>
    </div>
    """
  end

  # ── Review rail ──

  defp review_rail(assigns) do
    ~H"""
    <div class="valkka-cr-section">
      <div class="valkka-cr-section-title">Review Progress</div>
      <div class="valkka-cr-stats-grid">
        <div class="valkka-cr-stat-card">
          <span class={"valkka-cr-stat-num #{if @review_summary.pending > 0, do: "warn"}"}>
            {@review_summary.pending}
          </span>
          <span class="valkka-cr-stat-label">pending</span>
        </div>
        <div class="valkka-cr-stat-card">
          <span class="valkka-cr-stat-num">{@review_summary.reviewed}</span>
          <span class="valkka-cr-stat-label">reviewed</span>
        </div>
        <div class="valkka-cr-stat-card">
          <span class="valkka-cr-stat-num dim">{@review_summary.total}</span>
          <span class="valkka-cr-stat-label">total</span>
        </div>
      </div>
    </div>

    <div class="valkka-cr-section">
      <div class="valkka-cr-section-title">Shortcuts</div>
      <div class="valkka-cr-shortcuts">
        <div class="valkka-cr-shortcut"><kbd>j</kbd> next commit</div>
        <div class="valkka-cr-shortcut"><kbd>k</kbd> prev commit</div>
        <div class="valkka-cr-shortcut"><kbd>y</kbd> mark reviewed</div>
        <div class="valkka-cr-shortcut"><kbd>n</kbd> skip</div>
      </div>
    </div>
    """
  end

  # ── Agents rail ──

  defp agents_rail(assigns) do
    ~H"""
    <div class="valkka-cr-section">
      <div class="valkka-cr-section-title">Summary</div>
      <div class="valkka-cr-stats-grid">
        <div class="valkka-cr-stat-card">
          <span class={"valkka-cr-stat-num #{if Enum.any?(@agents, & &1.active), do: "active"}"}>
            {Enum.count(@agents, & &1.active)}
          </span>
          <span class="valkka-cr-stat-label">active</span>
        </div>
        <div class="valkka-cr-stat-card">
          <span class="valkka-cr-stat-num dim">{Enum.count(@agents, &(!&1.active))}</span>
          <span class="valkka-cr-stat-label">idle</span>
        </div>
        <div class="valkka-cr-stat-card">
          <span class="valkka-cr-stat-num dim">{length(@agents)}</span>
          <span class="valkka-cr-stat-label">total</span>
        </div>
      </div>
    </div>
    """
  end

  # ── Activity rail ──

  defp activity_rail(assigns) do
    ~H"""
    <div class="valkka-cr-section">
      <div class="valkka-cr-empty-hint">Click entries to expand details</div>
    </div>
    """
  end

  # ── Helpers ──

  defp rail_title("fleet", _), do: "Overview"
  defp rail_title("repo", "graph"), do: "Graph"
  defp rail_title("repo", "changes"), do: "Changes"
  defp rail_title("repo", "review"), do: "Review"
  defp rail_title("agents", _), do: "Agents"
  defp rail_title("activity", _), do: "Activity"
  defp rail_title(_, _), do: "Context"

  defp format_time(nil), do: ""
  defp format_time(dt), do: Calendar.strftime(dt, "%H:%M")

  defp viewing_label(%{view: "fleet"}), do: "fleet"
  defp viewing_label(%{view: "repo", repo_path: p}) when is_binary(p), do: Path.basename(p)
  defp viewing_label(%{view: "agents"}), do: "agents"
  defp viewing_label(%{view: "activity"}), do: "activity"
  defp viewing_label(_), do: ""

  defp repo_activity(activity, nil), do: activity
  defp repo_activity(activity, repo), do: Enum.filter(activity, &(&1.repo_path == repo.path))

  defp event_accent(:agent_started), do: "accent-agent"
  defp event_accent(:agent_stopped), do: "accent-agent"
  defp event_accent(:commit), do: "accent-blue"
  defp event_accent(:pushed), do: "accent-blue"
  defp event_accent(:pulled), do: "accent-teal"
  defp event_accent(:files_changed), do: ""
  defp event_accent(_), do: ""

  defp status_letter("added"), do: "A"
  defp status_letter("modified"), do: "M"
  defp status_letter("deleted"), do: "D"
  defp status_letter("renamed"), do: "R"
  defp status_letter(_), do: "?"

  defp put_assign(assigns, key, value), do: Map.put(assigns, key, value)
end
