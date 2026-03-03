defmodule KanniWeb.Components.ReposPanel do
  @moduledoc """
  Left panel: live list of all monitored repositories.
  Shows name, branch, status indicator, and ahead/behind counts.
  """

  use Phoenix.Component

  attr :repos, :list, required: true
  attr :selected_path, :string, default: nil

  def repos_panel(assigns) do
    ~H"""
    <div class="kanni-repos-panel">
      <div class="kanni-panel-header">
        <span class="kanni-panel-title">Repos</span>
        <span class="kanni-panel-count">{length(@repos)}</span>
      </div>
      <div class="kanni-repo-list">
        <div
          :for={repo <- @repos}
          class={"kanni-repo-item #{if repo.path == @selected_path, do: "selected", else: ""}"}
          phx-click="select_repo"
          phx-value-path={repo.path}
        >
          <span class={"kanni-status-dot #{status_class(repo)}"} />
          <div class="kanni-repo-info">
            <span class="kanni-repo-name">{repo.name}</span>
            <span class="kanni-repo-branch">{repo[:branch] || "—"}</span>
          </div>
          <div class="kanni-repo-meta">
            <span :if={Map.get(repo, :dirty_count, 0) > 0} class="kanni-dirty-count">
              {repo.dirty_count}
            </span>
            <span :if={Map.get(repo, :ahead, 0) > 0} class="kanni-ahead">↑{repo.ahead}</span>
            <span :if={Map.get(repo, :behind, 0) > 0} class="kanni-behind">↓{repo.behind}</span>
          </div>
        </div>
        <div :if={@repos == []} class="kanni-empty">
          Scanning...
        </div>
      </div>
    </div>
    """
  end

  defp status_class(%{status: :error}), do: "error"
  defp status_class(%{dirty_count: n}) when n > 0, do: "dirty"
  defp status_class(_), do: "clean"
end
