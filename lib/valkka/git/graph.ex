defmodule Valkka.Git.Graph do
  @moduledoc """
  Computes a visual lane layout for a commit DAG.

  Takes a list of commits in topological order (newest first) and assigns
  each commit to a column (lane) and row, producing a `GraphLayout` suitable
  for Canvas rendering.
  """

  alias Valkka.Git.Types.{Commit, GraphNode, GraphLayout}

  @spec compute_layout([Commit.t()]) :: GraphLayout.t()
  def compute_layout([]), do: %GraphLayout{}

  def compute_layout(commits) do
    {nodes, edges, lane_snapshots, max_col} = assign_lanes(commits)

    # Resolve edge to_col using actual node placements
    node_col = Map.new(nodes, fn n -> {n.oid, n.column} end)

    edges =
      Enum.map(edges, fn edge ->
        Map.put(edge, :to_col, Map.get(node_col, edge.to_oid, edge.to_col))
      end)

    branch_names =
      commits
      |> Enum.flat_map(&Map.get(&1, :__branches__, []))
      |> Enum.uniq()

    layout = %GraphLayout{
      nodes: nodes,
      edges: edges,
      max_columns: max_col + 1,
      branches: branch_names,
      total_commits: length(commits)
    }

    Map.put(layout, :active_lanes_per_row, lane_snapshots)
  end

  defp assign_lanes(commits) do
    state = %{lanes: [], nodes: [], edges: [], lane_snapshots: [], max_col: 0}

    final =
      commits
      |> Enum.with_index()
      |> Enum.reduce(state, fn {commit, row}, acc ->
        place_commit(commit, row, acc)
      end)

    {
      Enum.reverse(final.nodes),
      final.edges,
      Enum.reverse(final.lane_snapshots),
      final.max_col
    }
  end

  defp place_commit(commit, row, state) do
    oid = commit.oid
    parents = commit.parents
    branches = Map.get(commit, :__branches__, [])
    is_merge = length(parents) > 1

    # Find which lane expects this commit
    {col, lanes} = find_or_allocate_lane(oid, state.lanes)

    # Clear ALL lanes expecting this OID (convergence cleanup)
    lanes = clear_all_matching(lanes, oid)

    node = %GraphNode{
      oid: oid,
      short_oid: String.slice(oid, 0, 7),
      column: col,
      row: row,
      message: commit.message,
      author: commit.author,
      timestamp: commit.timestamp,
      branches: branches,
      is_merge: is_merge,
      parents: parents
    }

    # Assign parent lanes
    {lanes, edges} = assign_parent_lanes(parents, col, row, oid, lanes)

    # Snapshot active lanes for continuity line rendering
    active_cols =
      lanes
      |> Enum.with_index()
      |> Enum.reject(fn {val, _} -> is_nil(val) end)
      |> Enum.map(fn {_val, idx} -> idx end)

    max_col = max(state.max_col, max_lane_index(lanes))

    # Compact trailing nil lanes
    lanes = trim_trailing_nils(lanes)

    %{
      state
      | lanes: lanes,
        nodes: [node | state.nodes],
        edges: state.edges ++ edges,
        lane_snapshots: [active_cols | state.lane_snapshots],
        max_col: max_col
    }
  end

  defp find_or_allocate_lane(oid, lanes) do
    case Enum.find_index(lanes, &(&1 == oid)) do
      nil ->
        case Enum.find_index(lanes, &is_nil/1) do
          nil -> {length(lanes), lanes ++ [oid]}
          idx -> {idx, List.replace_at(lanes, idx, oid)}
        end

      idx ->
        {idx, lanes}
    end
  end

  defp clear_all_matching(lanes, oid) do
    Enum.map(lanes, fn
      ^oid -> nil
      other -> other
    end)
  end

  defp trim_trailing_nils(lanes) do
    lanes
    |> Enum.reverse()
    |> Enum.drop_while(&is_nil/1)
    |> Enum.reverse()
  end

  defp assign_parent_lanes([], _child_col, _child_row, _child_oid, lanes) do
    {lanes, []}
  end

  defp assign_parent_lanes([first_parent | rest], child_col, child_row, child_oid, lanes) do
    # First parent continues in the same lane
    lanes = ensure_lane_at(lanes, child_col)
    lanes = List.replace_at(lanes, child_col, first_parent)

    first_edge = %{
      from_oid: child_oid,
      to_oid: first_parent,
      from_col: child_col,
      from_row: child_row,
      to_col: child_col
    }

    # Additional parents get their own lanes
    {lanes, extra_edges} =
      Enum.reduce(rest, {lanes, []}, fn parent_oid, {lanes_acc, edges_acc} ->
        {parent_col, lanes_acc} = find_or_allocate_lane(parent_oid, lanes_acc)

        edge = %{
          from_oid: child_oid,
          to_oid: parent_oid,
          from_col: child_col,
          from_row: child_row,
          to_col: parent_col
        }

        {lanes_acc, [edge | edges_acc]}
      end)

    {lanes, [first_edge | Enum.reverse(extra_edges)]}
  end

  # Ensure lanes list is at least `col + 1` long
  defp ensure_lane_at(lanes, col) when length(lanes) > col, do: lanes

  defp ensure_lane_at(lanes, col) do
    lanes ++ List.duplicate(nil, col + 1 - length(lanes))
  end

  defp max_lane_index([]), do: 0
  defp max_lane_index(lanes), do: length(lanes) - 1
end
