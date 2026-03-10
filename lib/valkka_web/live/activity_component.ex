defmodule ValkkaWeb.ActivityComponent do
  @moduledoc """
  Curated activity stream with grouped, typed, actionable entries.
  Every entry is clickable to expand/collapse details.
  """

  use ValkkaWeb, :live_component

  @impl true
  def render(assigns) do
    ~H"""
    <div class="valkka-activity">
      <div :if={@entries == []} class="valkka-empty">
        No activity yet
      </div>
      <div
        :for={entry <- @entries}
        class={"valkka-activity-entry type-#{entry.type} #{if !entry.collapsed, do: "expanded"}"}
        phx-click="toggle_activity_entry"
        phx-value-id={entry.id}
      >
        <div class="valkka-activity-entry-header">
          <span class="valkka-activity-icon">{type_icon(entry.type)}</span>
          <span class="valkka-activity-time">{format_time(entry.timestamp)}</span>
          <span
            class="valkka-activity-repo"
            phx-click="activity_select_repo"
            phx-value-path={entry.repo_path}
          >
            {entry.repo}
          </span>
          <span class="valkka-activity-summary">{entry.summary}</span>
          <span class="valkka-activity-chevron">{if entry.collapsed, do: "▸", else: "▾"}</span>
        </div>

        <div :if={!entry.collapsed} class="valkka-activity-expanded">
          <div class="valkka-activity-detail-row">
            <span class="valkka-activity-detail-label">Type</span>
            <span class="valkka-activity-detail-value">{type_label(entry.type)}</span>
          </div>
          <div class="valkka-activity-detail-row">
            <span class="valkka-activity-detail-label">Time</span>
            <span class="valkka-activity-detail-value">{format_full_time(entry.timestamp)}</span>
          </div>
          <div :if={entry.detail[:branch]} class="valkka-activity-detail-row">
            <span class="valkka-activity-detail-label">Branch</span>
            <span class="valkka-activity-detail-value">{entry.detail[:branch]}</span>
          </div>
          <div :if={entry.detail[:from]} class="valkka-activity-detail-row">
            <span class="valkka-activity-detail-label">From</span>
            <span class="valkka-activity-detail-value">
              {entry.detail[:from]} → {entry.detail[:to]}
            </span>
          </div>
          <div :if={entry.detail[:sha]} class="valkka-activity-detail-row">
            <span class="valkka-activity-detail-label">SHA</span>
            <span class="valkka-activity-detail-value valkka-mono">
              {entry.detail[:sha] |> to_string() |> String.slice(0, 12)}
            </span>
          </div>
          <div :if={entry.detail[:message]} class="valkka-activity-detail-row">
            <span class="valkka-activity-detail-label">Message</span>
            <span class="valkka-activity-detail-value">{entry.detail[:message]}</span>
          </div>
          <div :if={entry.detail[:agent_name]} class="valkka-activity-detail-row">
            <span class="valkka-activity-detail-label">Agent</span>
            <span class="valkka-activity-detail-value">
              {entry.detail[:agent_name]} · PID {entry.detail[:pid]}
            </span>
          </div>
          <div :if={entry.detail[:dirty_count]} class="valkka-activity-detail-row">
            <span class="valkka-activity-detail-label">Changes</span>
            <span class="valkka-activity-detail-value">{entry.detail[:dirty_count]}</span>
          </div>

          <div :if={entry.files != []} class="valkka-activity-files">
            <div
              :for={file <- entry.files}
              class="valkka-activity-file"
              phx-click="activity_select_file"
              phx-value-repo-path={entry.repo_path}
              phx-value-tab="changes"
            >
              {file}
            </div>
          </div>

          <div class="valkka-activity-actions">
            <button
              class="valkka-btn ghost"
              phx-click="activity_select_repo"
              phx-value-path={entry.repo_path}
              style="font-size:11px;height:22px"
            >
              Open repo →
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp format_time(nil), do: ""
  defp format_time(dt), do: Calendar.strftime(dt, "%H:%M:%S")

  defp format_full_time(nil), do: ""
  defp format_full_time(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")

  defp type_icon(:files_changed), do: "◇"
  defp type_icon(:commit), do: "●"
  defp type_icon(:branch_switched), do: "⎇"
  defp type_icon(:repo_status), do: "◈"
  defp type_icon(:pushed), do: "↑"
  defp type_icon(:pulled), do: "↓"
  defp type_icon(:agent_started), do: "▶"
  defp type_icon(:agent_stopped), do: "■"
  defp type_icon(_), do: "·"

  defp type_label(:files_changed), do: "File changes"
  defp type_label(:commit), do: "Commit"
  defp type_label(:branch_switched), do: "Branch switch"
  defp type_label(:repo_status), do: "Status change"
  defp type_label(:pushed), do: "Push"
  defp type_label(:pulled), do: "Pull"
  defp type_label(:agent_started), do: "Agent started"
  defp type_label(:agent_stopped), do: "Agent stopped"
  defp type_label(t), do: t |> Atom.to_string() |> String.replace("_", " ")
end
