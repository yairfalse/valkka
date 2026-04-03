defmodule ValkkaWeb.CommandComponent do
  @moduledoc """
  Command view: workstream cards for active agents, unfinished work
  for dirty repos without agents, no-agents fallback showing all repos.

  A workstream is a UI projection joining an active agent to its repo.
  """

  use ValkkaWeb, :live_component

  @impl true
  def update(assigns, socket) do
    repos = assigns.repos
    agents = assigns.agents
    agent_start_times = assigns.agent_start_times
    activity = assigns.activity

    active_agents = Enum.filter(agents, & &1.active)

    agent_paths =
      active_agents
      |> Enum.map(& &1.repo_path)
      |> MapSet.new()

    # Cache activity-derived data — only rescan when activity changes.
    # Activity is append-only (prepended), so {length, first_id} is a
    # perfect fingerprint. Elapsed time is O(1) and always recomputed.
    activity_key = activity_fingerprint(activity)
    cached_key = socket.assigns[:cached_activity_key]

    repo_activity =
      if activity_key == cached_key && socket.assigns[:cached_repo_activity] do
        socket.assigns.cached_repo_activity
      else
        build_repo_activity(activity)
      end

    workstreams =
      Enum.map(active_agents, fn agent ->
        repo = Enum.find(repos, &(&1.path == agent.repo_path))
        repo_name = if repo, do: repo.name, else: Path.basename(agent.repo_path || "unknown")

        key = {agent.pid, agent.repo_path}
        started_at = Map.get(agent_start_times, key)

        elapsed =
          if started_at,
            do: format_duration(DateTime.diff(DateTime.utc_now(), started_at, :second)),
            else: nil

        cached = Map.get(repo_activity, agent.repo_path, %{})

        %{
          agent: agent,
          repo: repo,
          repo_name: repo_name,
          branch: repo && repo[:branch],
          dirty_count: (repo && Map.get(repo, :dirty_count, 0)) || 0,
          ahead: (repo && Map.get(repo, :ahead, 0)) || 0,
          elapsed: elapsed,
          recent_files: Map.get(cached, :recent_files, []),
          last_commit: Map.get(cached, :last_commit)
        }
      end)
      |> Enum.sort_by(& &1.repo_name)

    {_agent_repos, rest} = Enum.split_with(repos, &MapSet.member?(agent_paths, &1.path))

    unfinished =
      rest
      |> Enum.filter(&(Map.get(&1, :dirty_count, 0) > 0))
      |> Enum.sort_by(& &1.name)

    {:ok,
     assign(socket,
       workstreams: workstreams,
       unfinished: unfinished,
       repos: repos,
       has_agents: active_agents != [],
       cached_activity_key: activity_key,
       cached_repo_activity: repo_activity
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="valkka-command">
      <%!-- Workstream cards --%>
      <div :if={@has_agents} class="valkka-command-section">
        <div
          :for={ws <- @workstreams}
          class="valkka-ws-card"
          phx-click="select_repo"
          phx-value-path={ws.agent.repo_path}
        >
          <div class="valkka-ws-card-header">
            <span class="valkka-pulse" style="width:6px;height:6px"></span>
            <span class="valkka-ws-card-agent">{ws.agent.name}</span>
            <span :if={ws.elapsed} class="valkka-ws-card-elapsed">{ws.elapsed}</span>
          </div>
          <div class="valkka-ws-card-repo">
            <span class="valkka-ws-card-name">{ws.repo_name}</span>
            <span :if={ws.branch} class="valkka-ws-card-branch">{"⎇ #{ws.branch}"}</span>
            <span :if={ws.dirty_count > 0} class="valkka-ws-card-dirty">
              {"◇ #{ws.dirty_count}"}
            </span>
            <span :if={ws.ahead > 0} class="valkka-ws-card-ahead">{"↑ #{ws.ahead}"}</span>
          </div>
          <div :if={ws.recent_files != []} class="valkka-ws-card-files">
            <span :for={file <- ws.recent_files} class="valkka-ws-card-file">{file}</span>
          </div>
          <div :if={ws.last_commit} class="valkka-ws-card-commit">
            {ws.last_commit}
          </div>
        </div>
      </div>

      <%!-- Unfinished work --%>
      <div :if={@unfinished != []} class="valkka-command-section">
        <div class="valkka-command-heading">Unfinished work</div>
        <div
          :for={repo <- @unfinished}
          class="valkka-ws-card quiet"
          phx-click="select_repo"
          phx-value-path={repo.path}
        >
          <div class="valkka-ws-card-repo">
            <span class="valkka-dot dirty" style="margin-right:8px" />
            <span class="valkka-ws-card-name">{repo.name}</span>
            <span :if={repo[:branch]} class="valkka-ws-card-branch">{"⎇ #{repo[:branch]}"}</span>
            <span class="valkka-ws-card-dirty">{"◇ #{Map.get(repo, :dirty_count, 0)}"}</span>
            <span :if={Map.get(repo, :ahead, 0) > 0} class="valkka-ws-card-ahead">
              {"↑ #{repo.ahead}"}
            </span>
          </div>
        </div>
      </div>

      <%!-- No agents fallback: show all repos grouped --%>
      <div :if={!@has_agents && @unfinished == []} class="valkka-command-section">
        <div :if={@repos != []} class="valkka-command-heading">All repos</div>
        <div
          :for={repo <- @repos}
          class="valkka-ws-card quiet"
          phx-click="select_repo"
          phx-value-path={repo.path}
        >
          <div class="valkka-ws-card-repo">
            <span class={"valkka-dot #{fallback_dot(repo)}"} style="margin-right:8px" />
            <span class="valkka-ws-card-name">{repo.name}</span>
            <span :if={repo[:branch]} class="valkka-ws-card-branch">{"⎇ #{repo[:branch]}"}</span>
            <span :if={Map.get(repo, :dirty_count, 0) > 0} class="valkka-ws-card-dirty">
              {"◇ #{repo.dirty_count}"}
            </span>
          </div>
        </div>
        <div :if={@repos == []} class="valkka-empty">No repos monitored</div>
      </div>
    </div>
    """
  end

  defp activity_fingerprint([]), do: {0, nil}

  defp activity_fingerprint([first | _] = activity),
    do: {length(activity), first.id}

  # Single pass: collect recent files and last commit per repo path.
  defp build_repo_activity(activity) do
    Enum.reduce(activity, %{}, fn entry, acc ->
      path = entry.repo_path

      case entry.type do
        :files_changed ->
          existing = Map.get(acc, path, %{})
          files = Map.get(existing, :recent_files, [])

          new_files =
            entry.files
            |> Enum.reject(&(&1 in files))
            |> Enum.take(5 - length(files))

          if new_files == [] do
            acc
          else
            Map.update(acc, path, %{recent_files: new_files}, fn m ->
              Map.put(m, :recent_files, files ++ new_files)
            end)
          end

        :commit ->
          Map.update(acc, path, %{last_commit: entry.summary}, fn m ->
            Map.put_new(m, :last_commit, entry.summary)
          end)

        _ ->
          acc
      end
    end)
  end

  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_duration(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"
  defp format_duration(seconds), do: "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"

  defp fallback_dot(%{status: :error}), do: "error"
  defp fallback_dot(%{dirty_count: n}) when n > 0, do: "dirty"
  defp fallback_dot(_), do: "clean"
end
