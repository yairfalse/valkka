defmodule KanniWeb.Components.DiffViewer do
  @moduledoc """
  Server-rendered diff viewer component.
  Shows hunks with colored lines, line numbers, and hunk headers.
  """

  use Phoenix.Component

  attr :diff, :map, required: true

  def diff_viewer(assigns) do
    ~H"""
    <div class="kanni-diff">
      <div class="kanni-diff-header">
        {@diff["path"]}
      </div>
      <div :for={hunk <- @diff["hunks"] || []} class="kanni-hunk">
        <div class="kanni-hunk-header">{hunk["header"]}</div>
        <div class="kanni-hunk-lines">
          <div
            :for={line <- hunk["lines"] || []}
            class={"kanni-diff-line #{line_class(line["origin"])}"}
          >
            <span class="kanni-lineno old">{format_lineno(line["old_lineno"])}</span>
            <span class="kanni-lineno new">{format_lineno(line["new_lineno"])}</span>
            <span class="kanni-line-origin">{line["origin"]}</span>
            <span class="kanni-line-content">{line["content"]}</span>
          </div>
        </div>
      </div>
      <div :if={(@diff["hunks"] || []) == []} class="kanni-empty">
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
