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
       active_rp_tab: "activity",
       error: nil,
       graph: nil,
       graph_data: nil,
       handle: nil,
       activity: [],
       activity_buffer: %{},
       activity_timer: nil,
       prev_repo_states: prev_states,
       agents: agents,
       agent_summary: Valkka.Status.agent_summary(agents)
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

        <%= if @active_view == "agents" do %>
          <.live_component
            module={ValkkaWeb.AgentsComponent}
            id="agents-view"
            agents={@agents}
            repos={@repos}
          />
        <% end %>

        <%= if @active_view == "repo" do %>
          <.focus_panel selected_repo={@selected_repo} active_tab={@active_tab}>
            <:graph>
              <div :if={@graph} class="valkka-graph-info">
                {@graph.total_commits} commits · {@graph.max_columns} lanes · {format_branches(@graph.branches)}
              </div>
              <div class="valkka-scroll" style="padding:0">
                <canvas id="commit-graph" phx-hook="GraphHook" phx-update="ignore"></canvas>
              </div>
            </:graph>
            <:changes>
              <div class="valkka-scroll">
                <.live_component
                  :if={@handle}
                  module={ValkkaWeb.ChangesComponent}
                  id="changes"
                  repo_path={@selected_path}
                  handle={@handle}
                />
                <div :if={!@handle} class="valkka-empty">Loading...</div>
              </div>
            </:changes>
            <:diff>
              <div class="valkka-scroll">
                <div class="valkka-empty">Select a file from Changes to view its diff</div>
              </div>
            </:diff>
          </.focus_panel>
        <% end %>
      </div>

      <.context_panel active_rp_tab={@active_rp_tab}>
        <:activity>
          <.live_component
            module={ValkkaWeb.ActivityComponent}
            id="activity"
            entries={@activity}
          />
        </:activity>
        <:agents>
          <div :if={@agent_summary.active > 0} style="padding:2px 12px 8px;font-size:11.5px;color:var(--t3)">
            {@agent_summary.active} running
          </div>
          <div :for={agent <- Enum.filter(@agents, & &1.active)} class="valkka-agent-card live" style="margin-bottom:3px">
            <div class="valkka-agent-card-top">
              <span class="valkka-agent-card-dot live"></span>
              <span class="valkka-agent-card-name">{agent.name} · {agent_repo_name(agent, @repos)}</span>
              <span class="valkka-agent-card-pid">pid {agent.pid}</span>
            </div>
          </div>
          <div :for={agent <- Enum.reject(@agents, & &1.active)} class="valkka-agent-card" style="margin-bottom:3px">
            <div class="valkka-agent-card-top">
              <span class="valkka-agent-card-dot off"></span>
              <span class="valkka-agent-card-name" style="color:var(--t2)">{agent.name} · {agent_repo_name(agent, @repos)}</span>
              <span class="valkka-agent-card-pid">pid {agent.pid}</span>
            </div>
          </div>
          <div :if={@agents == []} class="valkka-empty">No agents detected</div>
        </:agents>
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
        if view != "repo", do: assign(s, selected_path: nil, selected_repo: nil, handle: nil), else: s
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

  def handle_event("switch_rp_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_rp_tab: tab)}
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

  def handle_info({:agent_started, agent}, socket) do
    entry = Activity.agent_entry(agent, :agent_started)
    activity = Activity.prepend(socket.assigns.activity, [entry])
    {:noreply, assign(socket, activity: activity)}
  end

  def handle_info({:agent_stopped, agent}, socket) do
    entry = Activity.agent_entry(agent, :agent_stopped)
    activity = Activity.prepend(socket.assigns.activity, [entry])
    {:noreply, assign(socket, activity: activity)}
  end

  def handle_info({:agents_changed, agents}, socket) do
    {:noreply, assign(socket, agents: agents, agent_summary: Valkka.Status.agent_summary(agents))}
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
    buffer = Activity.buffer_file_change(socket.assigns.activity_buffer, repo_path, repo_name, path)

    timer =
      if socket.assigns.activity_timer do
        socket.assigns.activity_timer
      else
        Process.send_after(self(), :flush_activity, Activity.window_ms())
      end

    {:noreply, assign(socket, activity_buffer: buffer, activity_timer: timer)}
  end

  def handle_info(:flush_activity, socket) do
    {new_entries, buffer} = Activity.flush_buffer(socket.assigns.activity_buffer)
    activity = Activity.prepend(socket.assigns.activity, new_entries)

    {:noreply, assign(socket, activity: activity, activity_buffer: buffer, activity_timer: nil)}
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
      error: nil
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

  defp valid_repo_path?(path, repos) do
    Enum.any?(repos, &(&1.path == path)) or
      match?([{_, _}], Registry.lookup(Valkka.Repo.Registry, path))
  end

  defp agent_repo_name(agent, repos) do
    repo = Enum.find(repos, &(&1.path == agent.repo_path))
    if repo, do: repo.name, else: Path.basename(agent.repo_path || "unknown")
  end
end
