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
        class={"valkka-activity-entry type-#{entry.type} #{agent_class(entry)} #{if !entry.collapsed, do: "expanded"}"}
        phx-click="toggle_activity_entry"
        phx-value-id={entry.id}
      >
        <div class="valkka-activity-entry-header">
          <span class="valkka-activity-icon">{type_icon(entry.type)}</span>
          <span
            class="valkka-activity-repo"
            phx-click="activity_select_repo"
            phx-value-path={entry.repo_path}
          >
            {entry.repo}
          </span>
          <span class="valkka-activity-summary">{entry.summary}</span>
          <span class="valkka-activity-time">{format_time(entry.timestamp)}</span>
        </div>

        <div :if={entry_subtitle(entry)} class="valkka-activity-subtitle">
          {entry_subtitle(entry)}
        </div>

        <div :if={!entry.collapsed && entry.files != []} class="valkka-activity-expanded">
          <div class="valkka-activity-files">
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
        </div>
      </div>
    </div>
    """
  end

  defp format_time(nil), do: ""
  defp format_time(dt), do: Calendar.strftime(dt, "%H:%M")

  defp type_icon(:files_changed), do: "◇"
  defp type_icon(:commit), do: "○"
  defp type_icon(:branch_switched), do: "⎇"
  defp type_icon(:repo_status), do: "◈"
  defp type_icon(:pushed), do: "↑"
  defp type_icon(:pulled), do: "↓"
  defp type_icon(:agent_started), do: "●"
  defp type_icon(:agent_stopped), do: "○"
  defp type_icon(_), do: "·"

  defp entry_subtitle(%{type: :files_changed, files: files}) when files != [] do
    names = Enum.join(files, ", ")
    if String.length(names) > 55, do: String.slice(names, 0, 52) <> "…", else: names
  end

  defp entry_subtitle(%{type: :agent_started, detail: detail}) do
    "pid #{detail[:pid]} · #{detail[:agent_name]}"
  end

  defp entry_subtitle(%{type: :agent_stopped, detail: detail}) do
    [detail[:duration]]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> case do
      "" -> nil
      s -> s
    end
  end

  defp entry_subtitle(%{type: :commit, detail: detail}) do
    short =
      if detail[:short_oid],
        do: detail[:short_oid],
        else: detail[:sha] && String.slice(to_string(detail[:sha]), 0, 7)

    author = detail[:author]

    [short, author]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> case do
      "" -> nil
      s -> s
    end
  end

  defp entry_subtitle(%{type: :branch_switched, detail: detail}) do
    "#{detail[:from]} → #{detail[:to]}"
  end

  defp entry_subtitle(%{type: type, detail: detail}) when type in [:pushed, :pulled] do
    detail[:branch]
  end

  defp entry_subtitle(_), do: nil

  defp agent_class(%{type: :files_changed, detail: %{agent_name: _}}), do: "agent-attributed"
  defp agent_class(_), do: ""
end
