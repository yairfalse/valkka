defmodule Valkka.Git.GraphTest do
  use ExUnit.Case, async: true

  alias Valkka.Git.Graph
  alias Valkka.Git.Types.{Commit, GraphLayout}

  defp make_commit(oid, parents, opts \\ []) do
    %Commit{
      oid: oid,
      message: Keyword.get(opts, :message, "commit #{oid}"),
      author: Keyword.get(opts, :author, "dev"),
      timestamp: DateTime.utc_now(),
      parents: parents
    }
    |> then(fn c ->
      branches = Keyword.get(opts, :branches, [])
      if branches != [], do: Map.put(c, :__branches__, branches), else: c
    end)
  end

  describe "compute_layout/1" do
    test "empty list" do
      assert %GraphLayout{nodes: [], total_commits: 0} = Graph.compute_layout([])
    end

    test "linear history" do
      # a -> b -> c (topo order: newest first)
      commits = [
        make_commit("aaa", ["bbb"]),
        make_commit("bbb", ["ccc"]),
        make_commit("ccc", [])
      ]

      layout = Graph.compute_layout(commits)

      assert layout.total_commits == 3
      assert layout.max_columns == 1

      # All nodes should be in column 0
      for node <- layout.nodes do
        assert node.column == 0
      end

      # Rows should be sequential
      rows = Enum.map(layout.nodes, & &1.row) |> Enum.sort()
      assert rows == [0, 1, 2]
    end

    test "simple branch and merge" do
      # Topology (topo order, newest first):
      #   merge (parents: b1, b2)
      #   b1 (parent: root)
      #   b2 (parent: root)
      #   root (no parents)
      commits = [
        make_commit("merge", ["b1", "b2"]),
        make_commit("b1", ["root"]),
        make_commit("b2", ["root"]),
        make_commit("root", [])
      ]

      layout = Graph.compute_layout(commits)

      assert layout.total_commits == 4
      assert layout.max_columns >= 2

      # Merge commit should be flagged
      merge_node = Enum.find(layout.nodes, &(&1.oid == "merge"))
      assert merge_node.is_merge

      # b1 and b2 should be in different columns
      b1 = Enum.find(layout.nodes, &(&1.oid == "b1"))
      b2 = Enum.find(layout.nodes, &(&1.oid == "b2"))
      assert b1.column != b2.column
    end

    test "parallel branches" do
      # Two branches diverging from root, not yet merged
      #   a1 -> root
      #   a2 -> root
      commits = [
        make_commit("a1", ["root"]),
        make_commit("a2", ["root"]),
        make_commit("root", [])
      ]

      layout = Graph.compute_layout(commits)

      a1 = Enum.find(layout.nodes, &(&1.oid == "a1"))
      a2 = Enum.find(layout.nodes, &(&1.oid == "a2"))

      # They should get different columns since they both expect "root"
      # but the first one takes the lane
      assert a1 != nil
      assert a2 != nil
    end

    test "branch labels are preserved" do
      commits = [
        make_commit("head", ["parent"], branches: ["main", "feature"]),
        make_commit("parent", [])
      ]

      layout = Graph.compute_layout(commits)

      head = Enum.find(layout.nodes, &(&1.oid == "head"))
      assert "main" in head.branches
      assert "feature" in head.branches
      assert "main" in layout.branches
    end

    test "edges are generated" do
      commits = [
        make_commit("child", ["parent"]),
        make_commit("parent", [])
      ]

      layout = Graph.compute_layout(commits)

      assert length(layout.edges) == 1
      edge = hd(layout.edges)
      assert edge.from_oid == "child"
      assert edge.to_oid == "parent"
    end

    test "merge generates multiple edges" do
      commits = [
        make_commit("merge", ["p1", "p2"]),
        make_commit("p1", []),
        make_commit("p2", [])
      ]

      layout = Graph.compute_layout(commits)

      assert length(layout.edges) == 2
      from_oids = Enum.map(layout.edges, & &1.from_oid) |> Enum.uniq()
      assert from_oids == ["merge"]
      to_oids = Enum.map(layout.edges, & &1.to_oid) |> MapSet.new()
      assert MapSet.member?(to_oids, "p1")
      assert MapSet.member?(to_oids, "p2")
    end

    test "short_oid is 7 characters" do
      long_oid = String.duplicate("a", 40)
      commits = [make_commit(long_oid, [])]

      layout = Graph.compute_layout(commits)
      node = hd(layout.nodes)
      assert node.short_oid == "aaaaaaa"
    end
  end
end
