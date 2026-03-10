defmodule Valkka.Activity do
  @moduledoc """
  Curates raw file/repo events into grouped, actionable activity entries.

  Pure-function module — no process. DashboardLive holds the buffer state
  and calls these functions to aggregate events and detect state changes.
  """

  defmodule Entry do
    @moduledoc "A single curated activity entry."

    @type entry_type ::
            :files_changed
            | :commit
            | :branch_switched
            | :repo_status
            | :pushed
            | :pulled
            | :agent_started
            | :agent_stopped

    @type t :: %__MODULE__{
            id: String.t(),
            type: entry_type(),
            repo: String.t(),
            repo_path: String.t(),
            summary: String.t(),
            files: [String.t()],
            detail: map(),
            timestamp: DateTime.t(),
            collapsed: boolean()
          }

    defstruct [
      :id,
      :type,
      :repo,
      :repo_path,
      :summary,
      files: [],
      detail: %{},
      timestamp: nil,
      collapsed: true
    ]
  end

  @window_ms 2_000
  @max_entries 30

  @doc "Returns the grouping window in milliseconds."
  def window_ms, do: @window_ms

  @doc """
  Record a file change into the pending buffer. Returns updated buffer.

  Buffer shape: %{repo_path => %{repo: name, files: MapSet, first_seen: DateTime}}
  """
  def buffer_file_change(buffer, repo_path, repo_name, file_path) do
    entry =
      Map.get(buffer, repo_path, %{
        repo: repo_name,
        files: MapSet.new(),
        first_seen: DateTime.utc_now()
      })

    basename = Path.basename(file_path)
    entry = %{entry | files: MapSet.put(entry.files, basename)}
    Map.put(buffer, repo_path, entry)
  end

  @doc """
  Flush the buffer, converting pending file changes into Entry structs.
  Checks active agents to attribute changes. Returns {new_entries, empty_buffer}.
  """
  def flush_buffer(buffer, agents \\ []) do
    active_agent_map =
      agents
      |> Enum.filter(& &1.active)
      |> Map.new(fn a -> {a.repo_path, a} end)

    entries =
      buffer
      |> Enum.map(fn {repo_path, %{repo: repo, files: files, first_seen: ts}} ->
        file_list = files |> MapSet.to_list() |> Enum.sort()
        count = length(file_list)
        agent = Map.get(active_agent_map, repo_path)

        {summary, detail} =
          if agent do
            {"#{agent.name} modified #{count} #{pluralize(count, "file")}",
             %{agent_name: agent.name, pid: agent.pid}}
          else
            {file_change_summary(count), %{}}
          end

        %Entry{
          id: generate_id(),
          type: :files_changed,
          repo: repo,
          repo_path: repo_path,
          summary: summary,
          files: file_list,
          detail: detail,
          timestamp: ts
        }
      end)
      |> Enum.sort_by(& &1.timestamp, {:desc, DateTime})

    {entries, %{}}
  end

  @doc """
  Detect state changes between old and new repo states.
  Returns a list of Entry structs for any detected changes.
  """
  def detect_state_changes(nil, _new_state), do: []

  def detect_state_changes(old_state, new_state) do
    []
    |> maybe_detect_branch_switch(old_state, new_state)
    |> maybe_detect_commit(old_state, new_state)
    |> maybe_detect_status_change(old_state, new_state)
  end

  @doc "Prepend new entries to the activity list, keeping at most @max_entries."
  def prepend(activity, new_entries) do
    (new_entries ++ activity)
    |> Enum.take(@max_entries)
  end

  @doc "Toggle the collapsed state of an entry by ID."
  def toggle_entry(activity, entry_id) do
    Enum.map(activity, fn entry ->
      if entry.id == entry_id do
        %{entry | collapsed: !entry.collapsed}
      else
        entry
      end
    end)
  end

  @doc """
  Build activity entries from agent start/stop events.
  Takes an agent map (%{name, pid, repo_path, active}) and an event type.
  """
  def agent_entry(agent, type, session_info \\ %{})

  def agent_entry(agent, :agent_started, _session_info) do
    %Entry{
      id: generate_id(),
      type: :agent_started,
      repo: Path.basename(agent.repo_path),
      repo_path: agent.repo_path,
      summary: "#{agent.name} started",
      detail: %{agent_name: agent.name, pid: agent.pid},
      timestamp: DateTime.utc_now()
    }
  end

  def agent_entry(agent, :agent_stopped, session_info) do
    duration = Map.get(session_info, :duration)

    summary =
      if duration do
        "#{agent.name} stopped · #{duration}"
      else
        "#{agent.name} stopped"
      end

    %Entry{
      id: generate_id(),
      type: :agent_stopped,
      repo: Path.basename(agent.repo_path),
      repo_path: agent.repo_path,
      summary: summary,
      detail: Map.merge(%{agent_name: agent.name, pid: agent.pid}, session_info),
      timestamp: DateTime.utc_now()
    }
  end

  # -- Private --

  defp maybe_detect_branch_switch(entries, old, new) do
    if old.branch != nil and new.branch != nil and old.branch != new.branch do
      entry = %Entry{
        id: generate_id(),
        type: :branch_switched,
        repo: new.name,
        repo_path: new.path,
        summary: "switched to #{new.branch}",
        detail: %{from: old.branch, to: new.branch},
        timestamp: DateTime.utc_now()
      }

      [entry | entries]
    else
      entries
    end
  end

  defp maybe_detect_commit(entries, old, new) do
    # Detect real commit via HEAD OID change on the same branch
    oid_changed =
      old[:head_oid] != nil and new[:head_oid] != nil and
        old.head_oid != new.head_oid and
        new.branch != nil and old.branch == new.branch

    if oid_changed do
      {summary, detail} = fetch_commit_info(new.path, new.head_oid, new.branch, old.dirty_count)

      entry = %Entry{
        id: generate_id(),
        type: :commit,
        repo: new.name,
        repo_path: new.path,
        summary: summary,
        detail: detail,
        timestamp: DateTime.utc_now()
      }

      [entry | entries]
    else
      entries
    end
  end

  @doc false
  def fetch_commit_info(repo_path, oid, branch, files_committed) do
    case System.cmd("git", ["log", "-1", "--format=%H\0%s", oid],
           cd: repo_path,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case String.split(String.trim(output), "\0") do
          [sha, message] ->
            short = String.slice(sha, 0, 7)

            {"#{short} #{message}",
             %{sha: sha, message: message, branch: branch, files_committed: files_committed}}

          _ ->
            fallback_commit_info(oid, branch, files_committed)
        end

      _ ->
        fallback_commit_info(oid, branch, files_committed)
    end
  end

  defp fallback_commit_info(oid, branch, files_committed) do
    short = String.slice(oid, 0, 7)

    {"#{short} committed on #{branch}",
     %{sha: oid, branch: branch, files_committed: files_committed}}
  end

  defp maybe_detect_status_change(entries, old, new) do
    cond do
      old.dirty_count == 0 and new.dirty_count > 0 ->
        entry = %Entry{
          id: generate_id(),
          type: :repo_status,
          repo: new.name,
          repo_path: new.path,
          summary: "#{new.dirty_count} uncommitted #{pluralize(new.dirty_count, "change")}",
          detail: %{dirty_count: new.dirty_count},
          timestamp: DateTime.utc_now()
        }

        [entry | entries]

      # Emit 'clean' status only on branch switch or non-commit transitions;
      # for dirty→clean on the same branch with OID change, the commit entry covers it.
      old.dirty_count > 0 and new.dirty_count == 0 and
          (old.branch != new.branch or old[:head_oid] == new[:head_oid]) ->
        entry = %Entry{
          id: generate_id(),
          type: :repo_status,
          repo: new.name,
          repo_path: new.path,
          summary: "working tree clean",
          detail: %{dirty_count: 0},
          timestamp: DateTime.utc_now()
        }

        [entry | entries]

      true ->
        entries
    end
  end

  defp file_change_summary(1), do: "1 file changed"
  defp file_change_summary(n), do: "#{n} files changed"

  defp pluralize(1, word), do: word
  defp pluralize(_, word), do: "#{word}s"

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end
