defmodule ValkkaWeb.ActivityComponent do
  @moduledoc """
  Curated activity stream with grouped, typed, actionable entries.
  Supports filtering to a focused repo. Shows first 3 files inline
  without requiring expand click.
  """

  use ValkkaWeb, :live_component

  @impl true
  def update(assigns, socket) do
    entries = assigns.entries
    filter_mode = Map.get(assigns, :filter_mode, :all)
    focused_repo_path = Map.get(assigns, :focused_repo_path)

    filtered =
      if filter_mode == :focused && focused_repo_path do
        Enum.filter(entries, &(&1.repo_path == focused_repo_path))
      else
        entries
      end

    {:ok,
     assign(socket,
       entries: entries,
       filtered: filtered,
       filter_mode: filter_mode,
       focused_repo_path: focused_repo_path
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="valkka-activity">
      <div :if={@filtered == []} class="valkka-empty">
        No activity yet
      </div>
      <div
        :for={entry <- @filtered}
        class={"valkka-activity-entry type-#{entry.type} #{agent_class(entry)} #{if !entry.collapsed, do: "expanded"}"}
      >
        <div
          class="valkka-activity-entry-header"
          phx-click="toggle_activity_entry"
          phx-value-id={entry.id}
        >
          <span class="valkka-activity-icon">{type_icon(entry.type)}</span>
          <span class="valkka-activity-repo">{entry.repo}</span>
          <span class="valkka-activity-summary">{entry.summary}</span>
          <span class="valkka-activity-time">{format_time(entry.timestamp)}</span>
        </div>

        <div :if={entry_subtitle(entry)} class="valkka-activity-subtitle">
          {entry_subtitle(entry)}
        </div>

        <%!-- Show first 3 files inline (always visible) --%>
        <div :if={entry.files != []} class="valkka-activity-files-inline">
          <div
            :for={file <- Enum.take(entry.files, 3)}
            class="valkka-activity-file"
            phx-click="activity_select_file"
            phx-value-repo-path={entry.repo_path}
            phx-value-file={file}
            phx-value-tab="changes"
          >
            {file}
          </div>
        </div>

        <%!-- Remaining files behind expand --%>
        <div :if={!entry.collapsed && length(entry.files) > 3} class="valkka-activity-expanded">
          <div class="valkka-activity-files">
            <div
              :for={file <- Enum.drop(entry.files, 3)}
              class="valkka-activity-file"
              phx-click="activity_select_file"
              phx-value-repo-path={entry.repo_path}
              phx-value-file={file}
              phx-value-tab="changes"
            >
              {file}
            </div>
          </div>
        </div>

        <%!-- Expand indicator for entries with > 3 files --%>
        <div
          :if={entry.collapsed && length(entry.files) > 3}
          class="valkka-activity-more"
          phx-click="toggle_activity_entry"
          phx-value-id={entry.id}
        >
          +{length(entry.files) - 3} more
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

  defp entry_subtitle(%{type: :branch_switched, detail: %{from: from, to: to}})
       when is_binary(from) and is_binary(to) do
    "#{from} → #{to}"
  end

  defp entry_subtitle(%{type: :branch_switched, detail: %{to: to}}) when is_binary(to) do
    "→ #{to}"
  end

  defp entry_subtitle(%{type: type, detail: detail}) when type in [:pushed, :pulled] do
    detail[:branch]
  end

  defp entry_subtitle(_), do: nil

  defp agent_class(%{type: :files_changed, detail: %{agent_name: _}}), do: "agent-attributed"
  defp agent_class(_), do: ""
end
