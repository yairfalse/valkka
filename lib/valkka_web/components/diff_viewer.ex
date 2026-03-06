defmodule ValkkaWeb.Components.DiffViewer do
  @moduledoc """
  Server-rendered diff viewer component.
  Shows hunks with colored lines, line numbers, and hunk headers.
  """

  use Phoenix.Component

  attr :diff, :map, required: true

  def diff_viewer(assigns) do
    ~H"""
    <div class="valkka-diff">
      <div class="valkka-diff-header">
        {@diff["path"]}
      </div>
      <div :for={hunk <- @diff["hunks"] || []} class="valkka-hunk">
        <div class="valkka-hunk-header">{hunk["header"]}</div>
        <div class="valkka-hunk-lines">
          <div
            :for={line <- hunk["lines"] || []}
            class={"valkka-diff-line #{line_class(line["origin"])}"}
          >
            <span class="valkka-lineno old">{format_lineno(line["old_lineno"])}</span>
            <span class="valkka-lineno new">{format_lineno(line["new_lineno"])}</span>
            <span class="valkka-line-origin">{line["origin"]}</span>
            <span class="valkka-line-content">{line["content"]}</span>
          </div>
        </div>
      </div>
      <div :if={(@diff["hunks"] || []) == []} class="valkka-empty">
        No changes
      </div>
    </div>
    """
  end

  defp line_class("+"), do: "addition"
  defp line_class("-"), do: "deletion"
  defp line_class(_), do: "context"

  defp format_lineno(nil), do: ""
  defp format_lineno(n), do: to_string(n)
end
