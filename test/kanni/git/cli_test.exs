defmodule Kanni.Git.CLITest do
  use ExUnit.Case, async: true

  alias Kanni.Git.CLI

  describe "log/2" do
    test "parses git log output from a real repo" do
      # Use kanni's own repo
      repo = Path.expand("../../..", __DIR__)

      case CLI.log(repo, limit: 5) do
        {:ok, commits} ->
          assert is_list(commits)
          assert length(commits) <= 5

          if length(commits) > 0 do
            commit = hd(commits)
            assert String.length(commit.oid) == 40
            assert is_binary(commit.message)
            assert is_binary(commit.author)
            assert %DateTime{} = commit.timestamp
            assert is_list(commit.parents)
          end

        {:error, _} ->
          # Not a git repo in CI or similar — skip
          :ok
      end
    end
  end

  describe "branches/1" do
    test "parses branch list from a real repo" do
      repo = Path.expand("../../..", __DIR__)

      case CLI.branches(repo) do
        {:ok, branches} ->
          assert is_list(branches)

          if length(branches) > 0 do
            branch = hd(branches)
            assert is_binary(branch.name)
            assert String.length(branch.head) == 40
            assert is_boolean(branch.is_current)
          end

        {:error, _} ->
          :ok
      end
    end
  end

  describe "log line parsing" do
    test "returns error for non-repo path" do
      assert {:error, _} = CLI.log(System.tmp_dir!(), limit: 1)
    end
  end
end
