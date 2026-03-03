defmodule Kanni.Git.Log do
  @moduledoc """
  Reusable module for loading commit graph data from a repository.
  Extracts graph loading logic for use across LiveViews.
  """

  alias Kanni.Git.{CLI, Graph}

  @doc "Load and compute graph layout for a repo path."
  @spec load_graph(String.t(), keyword()) ::
          {:ok, Graph.Types.GraphLayout.t(), map()} | {:error, String.t()}
  def load_graph(repo_path, opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)

    with :ok <- validate_repo(repo_path),
         {:ok, commits} <- CLI.log(repo_path, limit: limit),
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

  @doc "Serialize a graph layout to a JSON-safe map for the JS hook."
  def serialize_layout(layout) do
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
