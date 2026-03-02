defmodule KanniWeb.DashboardLive do
  @moduledoc """
  Main landing page — the git command center dashboard.

  Enter a local repo path to visualize its commit graph as a Canvas-rendered DAG
  with branch lanes, merge diamonds, and commit labels. The repo path is stored
  in the URL query string so it survives page refresh.
  """

  use KanniWeb, :live_view

  alias Kanni.Git.{CLI, Graph}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Känni",
       repo_path: "",
       error: nil,
       graph: nil
     )}
  end

  @impl true
  def handle_params(%{"repo" => path}, _uri, socket) when path != "" do
    if socket.assigns.repo_path == path and socket.assigns.graph != nil do
      # Already loaded this repo — just re-push the data for the hook
      {:noreply, push_graph(socket)}
    else
      {:noreply, load_and_render(socket, path)}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="kanni-dashboard" style="font-family: ui-monospace, monospace;">
      <div style="padding: 1.5rem 2rem;">
        <h1 style="font-size: 1.5rem; font-weight: 700; color: #00ff88; margin-bottom: 0.25rem;">
          Känni
        </h1>
        <p style="color: #6b6b80; font-size: 0.85rem; margin-bottom: 1.5rem;">
          AI-native git command center
        </p>

        <form phx-submit="open_repo" style="display: flex; gap: 0.5rem; margin-bottom: 1rem;">
          <input
            type="text"
            name="repo_path"
            value={@repo_path}
            placeholder="/path/to/repo"
            class="kanni-input"
            style="flex: 1; max-width: 500px;"
            phx-debounce="200"
          />
          <button type="submit" class="kanni-btn">Open</button>
        </form>

        <p :if={@error} style="color: #ff6b6b; font-size: 0.85rem; margin-bottom: 1rem;">
          {@error}
        </p>

        <div :if={@graph} style="color: #6b6b80; font-size: 0.75rem; margin-bottom: 0.5rem;">
          {to_string(@graph.total_commits)} commits · {to_string(@graph.max_columns)} lanes · {format_branches(@graph.branches)}
        </div>

        <div style="overflow-x: auto;">
          <canvas id="commit-graph" phx-hook="GraphHook" phx-update="ignore"></canvas>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("open_repo", %{"repo_path" => path}, socket) do
    path = String.trim(path)

    if path == "" do
      socket =
        socket
        |> assign(error: "Enter a repository path.", graph: nil)
        |> push_event("graph:clear", %{})

      {:noreply, socket}
    else
      {:noreply, push_patch(socket, to: "/?repo=#{URI.encode(path)}")}
    end
  end

  defp load_and_render(socket, path) do
    case load_graph(path) do
      {:ok, layout, graph_data} ->
        socket
        |> assign(repo_path: path, error: nil, graph: layout, graph_data: graph_data)
        |> push_event("graph:update", graph_data)

      {:error, reason} ->
        socket
        |> assign(repo_path: path, error: reason, graph: nil, graph_data: nil)
        |> push_event("graph:clear", %{})
    end
  end

  defp push_graph(socket) do
    case socket.assigns[:graph_data] do
      nil -> socket
      data -> push_event(socket, "graph:update", data)
    end
  end

  defp load_graph(repo_path) do
    with :ok <- validate_repo(repo_path),
         {:ok, commits} <- CLI.log(repo_path, limit: 200),
         :ok <- check_not_empty(commits) do
      layout = Graph.compute_layout(commits)
      graph_data = serialize_layout(layout)
      {:ok, layout, graph_data}
    else
      {:error, {msg, _code}} -> {:error, msg}
      {:error, msg} -> {:error, msg}
    end
  end

  defp check_not_empty([]), do: {:error, "Repository has no commits yet."}
  defp check_not_empty(_), do: :ok

  defp validate_repo(path) do
    git_dir = Path.join(path, ".git")

    if File.dir?(path) and File.dir?(git_dir) do
      :ok
    else
      {:error, "Not a git repository: #{path}"}
    end
  end

  defp format_branches(branches) do
    # Filter out origin/ duplicates and refs/stash, show local names
    local =
      branches
      |> Enum.reject(&String.starts_with?(&1, "origin/"))
      |> Enum.reject(&String.starts_with?(&1, "refs/"))

    shown = Enum.take(local, 4)
    rest = length(local) - length(shown)

    label = Enum.join(shown, ", ")
    if rest > 0, do: "#{label} +#{rest} more", else: label
  end

  defp serialize_layout(layout) do
    %{
      nodes: Enum.map(layout.nodes, &serialize_node/1),
      edges: layout.edges,
      active_lanes_per_row: Map.get(layout, :active_lanes_per_row, []),
      max_columns: layout.max_columns,
      branches: layout.branches,
      total_commits: layout.total_commits
    }
  end

  defp serialize_node(node) do
    %{
      oid: node.oid,
      short_oid: node.short_oid,
      column: node.column,
      row: node.row,
      message: node.message,
      author: node.author,
      timestamp: DateTime.to_iso8601(node.timestamp),
      branches: node.branches,
      is_merge: node.is_merge,
      parents: node.parents
    }
  end
end
