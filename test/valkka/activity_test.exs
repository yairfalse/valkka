defmodule Valkka.ActivityTest do
  use ExUnit.Case, async: true

  alias Valkka.Activity
  alias Valkka.Activity.Entry

  describe "buffer_file_change/4 and flush_buffer/1" do
    test "groups multiple files in the same repo into one entry" do
      buffer =
        %{}
        |> Activity.buffer_file_change("/repos/app", "app", "/repos/app/lib/foo.ex")
        |> Activity.buffer_file_change("/repos/app", "app", "/repos/app/lib/bar.ex")
        |> Activity.buffer_file_change("/repos/app", "app", "/repos/app/lib/baz.ex")

      {entries, new_buffer} = Activity.flush_buffer(buffer)

      assert new_buffer == %{}
      assert [%Entry{type: :files_changed, repo: "app", files: files, summary: summary}] = entries
      assert length(files) == 3
      assert summary == "3 files changed"
    end

    test "deduplicates the same file changed multiple times" do
      buffer =
        %{}
        |> Activity.buffer_file_change("/repos/app", "app", "/repos/app/lib/foo.ex")
        |> Activity.buffer_file_change("/repos/app", "app", "/repos/app/lib/foo.ex")

      {[entry], _} = Activity.flush_buffer(buffer)

      assert entry.files == ["foo.ex"]
      assert entry.summary == "1 file changed"
    end

    test "keeps separate entries for different repos" do
      buffer =
        %{}
        |> Activity.buffer_file_change("/repos/app", "app", "/repos/app/lib/foo.ex")
        |> Activity.buffer_file_change("/repos/lib", "lib", "/repos/lib/src/bar.ex")

      {entries, _} = Activity.flush_buffer(buffer)

      assert length(entries) == 2
      repos = Enum.map(entries, & &1.repo) |> Enum.sort()
      assert repos == ["app", "lib"]
    end

    test "flush on empty buffer returns no entries" do
      {entries, buffer} = Activity.flush_buffer(%{})
      assert entries == []
      assert buffer == %{}
    end
  end

  describe "detect_state_changes/2" do
    test "returns empty list when old state is nil" do
      assert Activity.detect_state_changes(nil, repo_state()) == []
    end

    test "detects branch switch" do
      old = repo_state(branch: "main")
      new = repo_state(branch: "feature/x")

      entries = Activity.detect_state_changes(old, new)

      assert [%Entry{type: :branch_switched, summary: "switched to feature/x"}] = entries
    end

    test "does not detect branch switch when branch is nil" do
      old = repo_state(branch: nil)
      new = repo_state(branch: "main")

      entries = Activity.detect_state_changes(old, new)

      refute Enum.any?(entries, &(&1.type == :branch_switched))
    end

    test "detects commit when head_oid changes on same branch" do
      old = repo_state(branch: "main", head_oid: "aaa111", dirty_count: 3)
      new = repo_state(branch: "main", head_oid: "bbb222", dirty_count: 0)

      entries = Activity.detect_state_changes(old, new)

      assert [%Entry{type: :commit}] = entries
    end

    test "does not detect commit when head_oid is unchanged" do
      old = repo_state(branch: "main", head_oid: "aaa111", dirty_count: 3)
      new = repo_state(branch: "main", head_oid: "aaa111", dirty_count: 0)

      entries = Activity.detect_state_changes(old, new)

      refute Enum.any?(entries, &(&1.type == :commit))
    end

    test "does not detect commit when branch is nil" do
      old = repo_state(branch: nil, head_oid: "aaa111", dirty_count: 3)
      new = repo_state(branch: nil, head_oid: "bbb222", dirty_count: 0)

      entries = Activity.detect_state_changes(old, new)

      refute Enum.any?(entries, &(&1.type == :commit))
    end

    test "detects clean to dirty status change" do
      old = repo_state(dirty_count: 0)
      new = repo_state(dirty_count: 2)

      entries = Activity.detect_state_changes(old, new)

      assert [%Entry{type: :repo_status, summary: "2 uncommitted changes"}] = entries
    end

    test "uses singular for 1 uncommitted change" do
      old = repo_state(dirty_count: 0)
      new = repo_state(dirty_count: 1)

      [entry] = Activity.detect_state_changes(old, new)

      assert entry.summary == "1 uncommitted change"
    end

    test "does not emit repo_status clean when commit already covers it" do
      old = repo_state(branch: "main", head_oid: "aaa111", dirty_count: 3)
      new = repo_state(branch: "main", head_oid: "bbb222", dirty_count: 0)

      entries = Activity.detect_state_changes(old, new)

      # Should only have the commit entry, not a redundant "clean" status
      assert length(entries) == 1
      assert hd(entries).type == :commit
    end
  end

  describe "prepend/2" do
    test "prepends entries and caps at 30" do
      existing = for i <- 1..28, do: %Entry{id: "old-#{i}", type: :repo_status}
      new = [%Entry{id: "new-1", type: :commit}, %Entry{id: "new-2", type: :commit}]

      result = Activity.prepend(existing, new)

      assert length(result) == 30
      assert hd(result).id == "new-1"
    end
  end

  describe "toggle_entry/2" do
    test "toggles collapsed state of matching entry" do
      entries = [
        %Entry{id: "a", type: :files_changed, collapsed: true},
        %Entry{id: "b", type: :commit, collapsed: true}
      ]

      result = Activity.toggle_entry(entries, "a")

      assert [%Entry{id: "a", collapsed: false}, %Entry{id: "b", collapsed: true}] = result
    end
  end

  describe "fetch_commit_info/4" do
    test "falls back gracefully for invalid repo path" do
      {summary, detail} = Activity.fetch_commit_info("/nonexistent", "abc123def", "main", 2)

      assert summary =~ "committed on main"
      assert detail.branch == "main"
      assert detail.sha == "abc123def"
      assert detail.short_oid == "abc123d"
    end
  end

  defp repo_state(overrides \\ []) do
    %{
      path: "/repos/app",
      name: "app",
      branch: "main",
      dirty_count: 0,
      head_oid: nil,
      ahead: 0,
      behind: 0,
      is_detached: false,
      status: :idle
    }
    |> Map.merge(Map.new(overrides))
  end
end
