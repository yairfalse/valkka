defmodule ValkkaWeb.DashboardLive do
  @moduledoc """
  Main surface — three-panel layout for multi-repo awareness.

  Left: sidebar with workspace header, nav, repo list
  Center: focused repo view (graph/changes/diff tabs) or overview/agents view
  Right: activity stream + agents panel
  """

  use ValkkaWeb, :live_view

  import ValkkaWeb.Components.ReposPanel
  import ValkkaWeb.Components.FocusPanel
  import ValkkaWeb.Components.ContextPanel

  alias Valkka.Git.Log
  alias Valkka.Activity

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Valkka.PubSub, "repos")
      Phoenix.PubSub.subscribe(Valkka.PubSub, "file_events")
      Phoenix.PubSub.subscribe(Valkka.PubSub, "agents")
    end

    repos = Valkka.Workspace.list_repos()

    prev_states =
      Map.new(repos, fn r -> {r.path, r} end)

    agents = Valkka.Status.agents()

    {:ok,
     assign(socket,
       page_title: "Valkka",
       repos: repos,
       selected_path: nil,
       selected_repo: nil,
       active_view: "overview",
       active_tab: "graph",
       error: nil,
       graph: nil,
       graph_data: nil,
       selected_commit: nil,
       commit_files: [],
       handle: nil,
       activity: [],
       activity_buffer: %{},
       activity_timer: nil,
       prev_repo_states: prev_states,
       agents: agents,
       agent_summary: Valkka.Status.agent_summary(agents),
       agent_start_times: %{},
       agent_tick_ref: nil
     )}
  end

  @impl true
  def handle_params(%{"repo" => path}, _uri, socket) when path != "" do
    if valid_repo_path?(path, socket.assigns.repos) do
      {:noreply, select_repo(socket, path)}
    else
      {:noreply, socket}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="valkka-shell" class="valkka-shell" phx-hook="KeyboardHook">
      <.repos_panel
        repos={@repos}
        selected_path={@selected_path}
        active_view={@active_view}
        agent_count={@agent_summary.active}
      />

      <div class="valkka-center" style="display:flex;flex-direction:column;overflow:hidden">
        <%= if @active_view == "overview" do %>
          <.live_component
            module={ValkkaWeb.OverviewComponent}
            id="overview"
            repos={@repos}
            agents={@agents}
          />
        <% end %>

        <%= if @active_view == "repo" do %>
          <.focus_panel
            selected_repo={@selected_repo}
            active_tab={@active_tab}
            active_agent={active_agent_for_repo(@agents, @selected_path)}
            agent_elapsed={agent_elapsed(@agent_start_times, @agents, @selected_path)}
          >
            <:graph>
              <div :if={@graph} class="valkka-graph-info">
                {@graph.total_commits} commits · {@graph.max_columns} lanes · {format_branches(
                  @graph.branches
                )}
              </div>
              <div style="display:flex;flex-direction:column;flex:1;overflow:hidden">
                <div
                  class="valkka-scroll"
                  style={"padding:0;#{if @selected_commit, do: "flex:1;min-height:200px", else: "flex:1"}"}
                >
                  <canvas id="commit-graph" phx-hook="GraphHook" phx-update="ignore"></canvas>
                </div>
                <.live_component
                  :if={@selected_commit}
                  module={ValkkaWeb.CommitDetailComponent}
                  id="commit-detail"
                  commit={@selected_commit}
                  files={@commit_files}
                />
              </div>
            </:graph>
            <:changes>
              <.live_component
                :if={@handle}
                module={ValkkaWeb.ChangesComponent}
                id="changes"
                repo_path={@selected_path}
                handle={@handle}
                agents={@agents}
              />
              <div :if={!@handle} class="valkka-empty">Loading...</div>
            </:changes>
          </.focus_panel>
        <% end %>
      </div>

      <.context_panel>
        <:activity>
          <.live_component
            module={ValkkaWeb.ActivityComponent}
            id="activity"
            entries={@activity}
          />
        </:activity>
      </.context_panel>
    </div>
    """
  end

  # ── Events ──────────────────────────────────────────────────

  @impl true
  def handle_event("select_repo", %{"path" => path}, socket) do
    {:noreply, push_patch(socket, to: "/?repo=#{URI.encode(path)}")}
  end

  def handle_event("switch_view", %{"view" => view}, socket) do
    socket =
      socket
      |> assign(active_view: view)
      |> then(fn s ->
        if view != "repo",
          do: assign(s, selected_path: nil, selected_repo: nil, handle: nil),
          else: s
      end)

    {:noreply, socket}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    socket = assign(socket, active_tab: tab)

    socket =
      if tab == "graph" and socket.assigns.selected_path do
        load_graph_if_needed(socket)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("toggle_activity_entry", %{"id" => id}, socket) do
    {:noreply, assign(socket, activity: Activity.toggle_entry(socket.assigns.activity, id))}
  end

  def handle_event("activity_select_repo", %{"path" => path}, socket) do
    {:noreply, push_patch(socket, to: "/?repo=#{URI.encode(path)}")}
  end

  def handle_event("activity_select_file", %{"repo-path" => repo_path, "tab" => tab}, socket) do
    socket =
      socket
      |> push_patch(to: "/?repo=#{URI.encode(repo_path)}")
      |> assign(active_tab: tab)

    {:noreply, socket}
  end

  def handle_event("graph:select_commit", params, socket) do
    commit = %{
      oid: params["oid"],
      short_oid: params["short_oid"],
      message: params["message"],
      author: params["author"],
      timestamp: params["timestamp"],
      branches: params["branches"] || [],
      is_merge: params["is_merge"],
      parents: params["parents"] || []
    }

    repo_path = socket.assigns.selected_path
    oid = commit.oid

    Task.Supervisor.async_nolink(Valkka.TaskSupervisor, fn ->
      case Valkka.Git.CLI.commit_files(repo_path, oid) do
        {:ok, f} -> {:commit_files_loaded, oid, f}
        _ -> {:commit_files_loaded, oid, []}
      end
    end)

    {:noreply, assign(socket, selected_commit: commit, commit_files: [])}
  end

  def handle_event("graph:deselect_commit", _params, socket) do
    {:noreply, assign(socket, selected_commit: nil, commit_files: [])}
  end

  def handle_event("key:select_repo", %{"index" => index}, socket) do
    case Enum.at(socket.assigns.repos, index) do
      nil -> {:noreply, socket}
      repo -> {:noreply, push_patch(socket, to: "/?repo=#{URI.encode(repo.path)}")}
    end
  end

  def handle_event("key:stage_focused", _params, socket) do
    send_update(ValkkaWeb.ChangesComponent, id: "changes", action: :stage_focused)
    {:noreply, socket}
  end

  def handle_event("key:unstage_focused", _params, socket) do
    send_update(ValkkaWeb.ChangesComponent, id: "changes", action: :unstage_focused)
    {:noreply, socket}
  end

  def handle_event("key:focus_commit", _params, socket) do
    {:noreply, push_event(socket, "focus-commit-input", %{})}
  end

  def handle_event("key:stage_all", _params, socket) do
    send_update(ValkkaWeb.ChangesComponent, id: "changes", action: :stage_all)
    {:noreply, socket}
  end

  def handle_event("key:discard_focused", _params, socket) do
    {:noreply, push_event(socket, "confirm-discard", %{})}
  end

  def handle_event("key:discard_confirmed", %{"file" => file}, socket) do
    send_update(ValkkaWeb.ChangesComponent, id: "changes", action: :discard_file, file: file)
    {:noreply, socket}
  end

  def handle_event("key:toggle_branch", _params, socket) do
    send_update(ValkkaWeb.CommitComponent, id: "commit-form", action: :toggle_branch)
    {:noreply, socket}
  end

  def handle_event("key:push", %{"confirmed" => true}, socket) do
    send_update(ValkkaWeb.CommitComponent, id: "commit-form", action: :push)
    {:noreply, socket}
  end

  def handle_event("key:push", _params, socket) do
    {:noreply, push_event(socket, "confirm-push", %{})}
  end

  def handle_event("key:pull", %{"confirmed" => true}, socket) do
    send_update(ValkkaWeb.CommitComponent, id: "commit-form", action: :pull)
    {:noreply, socket}
  end

  def handle_event("key:pull", _params, socket) do
    {:noreply, push_event(socket, "confirm-pull", %{})}
  end

  # ── Info handlers ───────────────────────────────────────────

  @impl true
  def handle_info({:refresh_changes, _path}, socket) do
    send_update(ValkkaWeb.ChangesComponent,
      id: "changes",
      force_refresh: true,
      repo_path: socket.assigns.selected_path,
      handle: socket.assigns.handle
    )

    if pid = worker_pid(socket.assigns.selected_path) do
      Valkka.Repo.Worker.refresh(pid)
    end

    {:noreply, socket}
  end

  def handle_info({:flash, level, message}, socket) do
    {:noreply, put_flash(socket, level, message)}
  end

  def handle_info({:file_selected, _file_path, _repo_path}, socket) do
    # Stay on changes tab when a file is selected
    {:noreply, socket}
  end

  def handle_info({:push_completed, path}, socket) do
    if pid = worker_pid(path) do
      Valkka.Repo.Worker.refresh(pid)
    end

    repo = Enum.find(socket.assigns.repos, &(&1.path == path))
    branch = if repo, do: repo.branch, else: nil

    entry = %Activity.Entry{
      id: :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false),
      type: :pushed,
      repo: (repo && repo.name) || Path.basename(path),
      repo_path: path,
      summary: "pushed to origin",
      detail: %{branch: branch},
      timestamp: DateTime.utc_now()
    }

    activity = Activity.prepend(socket.assigns.activity, [entry])
    {:noreply, assign(socket, activity: activity)}
  end

  def handle_info({:pull_completed, path}, socket) do
    if pid = worker_pid(path) do
      Valkka.Repo.Worker.refresh(pid)
    end

    repo = Enum.find(socket.assigns.repos, &(&1.path == path))
    branch = if repo, do: repo.branch, else: nil

    entry = %Activity.Entry{
      id: :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false),
      type: :pulled,
      repo: (repo && repo.name) || Path.basename(path),
      repo_path: path,
      summary: "pulled from origin",
      detail: %{branch: branch},
      timestamp: DateTime.utc_now()
    }

    activity = Activity.prepend(socket.assigns.activity, [entry])
    {:noreply, assign(socket, activity: activity)}
  end

  def handle_info({:agent_started, agent}, socket) do
    key = {agent.pid, agent.repo_path}
    start_times = Map.put(socket.assigns.agent_start_times, key, DateTime.utc_now())
    entry = Activity.agent_entry(agent, :agent_started)
    activity = Activity.prepend(socket.assigns.activity, [entry])
    {:noreply, assign(socket, activity: activity, agent_start_times: start_times)}
  end

  def handle_info({:agent_stopped, agent}, socket) do
    key = {agent.pid, agent.repo_path}
    started_at = Map.get(socket.assigns.agent_start_times, key)
    start_times = Map.delete(socket.assigns.agent_start_times, key)

    session_info =
      if started_at do
        duration_s = DateTime.diff(DateTime.utc_now(), started_at, :second)
        %{duration: format_duration(duration_s)}
      else
        %{}
      end

    entry = Activity.agent_entry(agent, :agent_stopped, session_info)
    activity = Activity.prepend(socket.assigns.activity, [entry])
    {:noreply, assign(socket, activity: activity, agent_start_times: start_times)}
  end

  def handle_info({:agents_changed, agents}, socket) do
    summary = Valkka.Status.agent_summary(agents)

    socket =
      if summary.active > 0 && !socket.assigns[:agent_tick_ref] do
        ref = Process.send_after(self(), :agent_tick, 1_000)
        assign(socket, agent_tick_ref: ref)
      else
        socket
      end

    {:noreply, assign(socket, agents: agents, agent_summary: summary)}
  end

  def handle_info(:agent_tick, socket) do
    if socket.assigns.agent_summary.active > 0 do
      ref = Process.send_after(self(), :agent_tick, 1_000)
      {:noreply, assign(socket, agent_tick_ref: ref)}
    else
      {:noreply, assign(socket, agent_tick_ref: nil)}
    end
  end

  def handle_info({:repo_state_changed, repo_state}, socket) do
    repos = update_repo_in_list(socket.assigns.repos, repo_state)

    old_state = Map.get(socket.assigns.prev_repo_states, repo_state.path)
    change_entries = Activity.detect_state_changes(old_state, repo_state)
    prev_states = Map.put(socket.assigns.prev_repo_states, repo_state.path, repo_state)

    activity = Activity.prepend(socket.assigns.activity, change_entries)

    socket =
      assign(socket,
        repos: repos,
        activity: activity,
        prev_repo_states: prev_states
      )

    socket =
      if socket.assigns.selected_path == repo_state.path do
        assign(socket, selected_repo: repo_state)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:file_changed, path, _events}, socket) do
    {repo_name, repo_path} = repo_info_for_path(path, socket.assigns.repos)

    buffer =
      Activity.buffer_file_change(socket.assigns.activity_buffer, repo_path, repo_name, path)

    timer =
      if socket.assigns.activity_timer do
        socket.assigns.activity_timer
      else
        Process.send_after(self(), :flush_activity, Activity.window_ms())
      end

    {:noreply, assign(socket, activity_buffer: buffer, activity_timer: timer)}
  end

  def handle_info(:flush_activity, socket) do
    {new_entries, buffer} =
      Activity.flush_buffer(socket.assigns.activity_buffer, socket.assigns.agents)

    activity = Activity.prepend(socket.assigns.activity, new_entries)

    {:noreply, assign(socket, activity: activity, activity_buffer: buffer, activity_timer: nil)}
  end

  def handle_info({ref, {:commit_files_loaded, oid, files}}, socket) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    socket =
      if socket.assigns.selected_commit && socket.assigns.selected_commit.oid == oid do
        assign(socket, commit_files: files)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket) do
    {:noreply, socket}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # ── Private ─────────────────────────────────────────────────

  defp select_repo(socket, path) do
    repo = Enum.find(socket.assigns.repos, &(&1.path == path))

    repo =
      repo ||
        case Valkka.Repo.Worker.get_state(path) do
          {:ok, state} -> state
          _ -> %{path: path, name: Path.basename(path), status: :unknown}
        end

    handle =
      case Valkka.Repo.Worker.get_handle(path) do
        {:ok, h} -> h
        _ -> nil
      end

    socket
    |> assign(
      selected_path: path,
      selected_repo: repo,
      active_view: "repo",
      handle: handle,
      error: nil,
      selected_commit: nil,
      commit_files: []
    )
    |> then(fn s ->
      if s.assigns.active_tab == "graph", do: load_graph_if_needed(s), else: s
    end)
  end

  defp load_graph_if_needed(socket) do
    path = socket.assigns.selected_path

    if path && (socket.assigns.graph == nil || socket.assigns[:last_graph_path] != path) do
      case Log.load_graph(path) do
        {:ok, layout, graph_data} ->
          socket
          |> assign(graph: layout, graph_data: graph_data, last_graph_path: path, error: nil)
          |> push_event("graph:update", graph_data)

        {:error, reason} ->
          assign(socket, error: reason, graph: nil, graph_data: nil)
      end
    else
      case socket.assigns[:graph_data] do
        nil -> socket
        data -> push_event(socket, "graph:update", data)
      end
    end
  end

  defp format_branches(branches) do
    local =
      branches
      |> Enum.reject(&String.starts_with?(&1, "origin/"))
      |> Enum.reject(&String.starts_with?(&1, "refs/"))

    shown = Enum.take(local, 4)
    rest = length(local) - length(shown)

    label = Enum.join(shown, ", ")
    if rest > 0, do: "#{label} +#{rest} more", else: label
  end

  defp update_repo_in_list(repos, repo_state) do
    if Enum.any?(repos, &(&1.path == repo_state.path)) do
      Enum.map(repos, fn r ->
        if r.path == repo_state.path, do: repo_state, else: r
      end)
    else
      Enum.sort_by([repo_state | repos], & &1.name)
    end
  end

  defp worker_pid(nil), do: nil

  defp worker_pid(path) do
    case Registry.lookup(Valkka.Repo.Registry, path) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp repo_info_for_path(file_path, repos) do
    Enum.find_value(repos, {Path.basename(file_path), file_path}, fn repo ->
      if String.starts_with?(file_path, repo.path), do: {repo.name, repo.path}
    end)
  end

  defp active_agent_for_repo(_agents, nil), do: nil

  defp active_agent_for_repo(agents, path) do
    Enum.find(agents, fn a -> a.active && a.repo_path == path end)
  end

  defp agent_elapsed(start_times, agents, path) do
    agent = active_agent_for_repo(agents, path)

    if agent do
      key = {agent.pid, agent.repo_path}

      case Map.get(start_times, key) do
        nil -> nil
        started_at -> format_duration(DateTime.diff(DateTime.utc_now(), started_at, :second))
      end
    end
  end

  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_duration(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"
  defp format_duration(seconds), do: "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"

  defp valid_repo_path?(path, repos) do
    Enum.any?(repos, &(&1.path == path)) or
      match?([{_, _}], Registry.lookup(Valkka.Repo.Registry, path))
  end
end
