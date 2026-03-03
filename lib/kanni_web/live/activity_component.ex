defmodule KanniWeb.ActivityComponent do
  @moduledoc """
  Activity stream showing live file events across all repos.
  Ring buffer of last 50 events, newest first.
  """

  use KanniWeb, :live_component

  @impl true
  def render(assigns) do
    ~H"""
    <div class="kanni-activity">
      <div :if={@events == []} class="kanni-empty">
        No activity yet. Changes will appear here as files are modified.
      </div>
      <div :for={event <- @events} class="kanni-activity-event">
        <span class="kanni-activity-time">{format_time(event.time)}</span>
        <span class="kanni-activity-repo">{event.repo}</span>
        <span class="kanni-activity-path">{relative_path(event.path, event.repo)}</span>
        <span class="kanni-activity-events">{format_events(event.events)}</span>
      </div>
    </div>
    """
  end

  defp format_time(dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  defp relative_path(path, _repo) do
    path
    |> Path.basename()
  end

  defp format_events(events) when is_list(events) do
    events
    |> Enum.map(&to_string/1)
    |> Enum.join(", ")
  end

  defp format_events(_), do: ""
end
