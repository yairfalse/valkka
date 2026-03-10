defmodule ValkkaWeb.CommitDetailComponent do
  @moduledoc """
  Shows details of a selected commit from the graph.
  Displays message, author, timestamp, branches, and changed files.
  """

  use ValkkaWeb, :live_component

  @impl true
  def render(assigns) do
    ~H"""
    <div class="valkka-commit-detail">
      <div class="valkka-commit-detail-header">
        <div class="valkka-commit-detail-row">
          <span class="valkka-commit-detail-oid">{@commit.short_oid}</span>
          <span :for={branch <- @commit.branches} class="valkka-commit-detail-branch">{branch}</span>
          <span :if={@commit.is_merge} class="valkka-commit-detail-merge">merge</span>
          <span class="valkka-spacer"></span>
          <button
            class="valkka-btn ghost"
            phx-click="graph:deselect_commit"
            style="font-size:11px;height:22px"
          >
            Close
          </button>
        </div>
        <div class="valkka-commit-detail-message">{@commit.message}</div>
        <div class="valkka-commit-detail-meta">
          <span>{@commit.author}</span>
          <span class="valkka-commit-detail-time">{format_timestamp(@commit.timestamp)}</span>
          <span :if={length(@commit.parents) > 0} class="valkka-commit-detail-parents">
            {"parents: #{@commit.parents |> Enum.map(&String.slice(&1, 0, 7)) |> Enum.join(", ")}"}
          </span>
        </div>
      </div>
      <div class="valkka-commit-detail-files">
        <div class="valkka-section" style="border-top:1px solid var(--b)">
          <div class="valkka-section-label">
            Files changed <span class="valkka-section-count">{length(@files)}</span>
          </div>
        </div>
        <div class="valkka-commit-detail-file-list">
          <div :for={file <- @files} class="valkka-file-row" style="height:28px">
            <span class={"valkka-file-status #{file.status}"}>{status_letter(file.status)}</span>
            <span class="valkka-file-name">{split_path(file.path)}</span>
          </div>
          <div :if={@files == []} class="valkka-empty" style="padding:8px 16px;font-size:12px">
            No files (initial commit or empty)
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp format_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M")
      _ -> ts
    end
  end

  defp format_timestamp(_), do: ""

  defp status_letter("added"), do: "A"
  defp status_letter("modified"), do: "M"
  defp status_letter("deleted"), do: "D"
  defp status_letter("renamed"), do: "R"
  defp status_letter(_), do: "?"

  defp split_path(path) when is_binary(path) do
    case Path.split(path) do
      [name] ->
        assigns = %{name: name}
        ~H"{@name}"

      parts ->
        dir = Enum.slice(parts, 0..-2//1) |> Path.join()
        name = List.last(parts)
        assigns = %{dir: dir <> "/", name: name}
        ~H|<span class="dir">{@dir}</span>{@name}|
    end
  end

  defp split_path(_), do: ""
end
