defmodule KanniWeb.ActivityComponent do
  @moduledoc """
  Curated activity stream with grouped, typed, actionable entries.
  """

  use KanniWeb, :live_component

  @impl true
  def render(assigns) do
    ~H"""
    <div class="kanni-activity">
      <div :if={@entries == []} class="kanni-empty">
        No activity yet. Changes will appear here as files are modified.
      </div>
      <div :for={entry <- @entries} class={"kanni-activity-entry type-#{entry.type}"}>
        <div class="kanni-activity-entry-header">
          <span class="kanni-activity-icon">{type_icon(entry.type)}</span>
          <span class="kanni-activity-time">{format_time(entry.timestamp)}</span>
          <span
            class="kanni-activity-repo"
            phx-click="activity_select_repo"
            phx-value-path={entry.repo_path}
          >
            {entry.repo}
          </span>
          <span class="kanni-activity-summary">{entry.summary}</span>
          <button
            :if={entry.type == :files_changed and length(entry.files) > 0}
            class="kanni-activity-toggle"
            phx-click="toggle_activity_entry"
            phx-value-id={entry.id}
          >
            {if entry.collapsed, do: "▸", else: "▾"}
          </button>
        </div>

        <div
          :if={entry.type == :files_changed and not entry.collapsed}
          class="kanni-activity-files"
        >
          <div
            :for={file <- entry.files}
            class="kanni-activity-file"
            phx-click="activity_select_file"
            phx-value-repo-path={entry.repo_path}
            phx-value-tab="changes"
          >
            {file}
          </div>
        </div>

        <div :if={entry.type == :commit} class="kanni-activity-detail">
          {commit_detail(entry.detail)}
        </div>

        <div :if={entry.type == :branch_switched} class="kanni-activity-detail">
          {entry.detail[:from]} → {entry.detail[:to]}
        </div>
      </div>
    </div>
    """
  end

  defp format_time(nil), do: ""

  defp format_time(dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp type_icon(:files_changed), do: "◇"
  defp type_icon(:commit), do: "●"
  defp type_icon(:branch_switched), do: "⎇"
  defp type_icon(:repo_status), do: "◈"
  defp type_icon(_), do: "?"

  defp commit_detail(%{files_committed: n, branch: branch}) do
    "#{n} file#{if n == 1, do: "", else: "s"} on #{branch}"
  end

  defp commit_detail(_), do: ""
end
