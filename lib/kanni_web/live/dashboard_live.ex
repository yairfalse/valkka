defmodule KanniWeb.DashboardLive do
  @moduledoc """
  Main surface — three-panel layout for multi-repo awareness.

  Left: repo list with live state
  Center: focused repo view (changes/graph/activity tabs)
  Right: context panel (populated by plugins)
  """

  use KanniWeb, :live_view

  import KanniWeb.Components.ReposPanel
  import KanniWeb.Components.FocusPanel
  import KanniWeb.Components.ContextPanel

  alias Kanni.Git.Log
  alias Kanni.Activity

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Kanni.PubSub, "repos")
      Phoenix.PubSub.subscribe(Kanni.PubSub, "file_events")
    end

    repos = Kanni.Workspace.list_repos()

    # Build initial prev_repo_states from current repo list
    prev_states =
      Map.new(repos, fn r -> {r.path, r} end)

    {:ok,
     assign(socket,
       page_title: "Känni",
       repos: repos,
       selected_path: nil,
       selected_repo: nil,
       active_tab: "changes",
       error: nil,
       graph: nil,
       graph_data: nil,
       context: nil,
       handle: nil,
       activity: [],
       activity_buffer: %{},
       activity_timer: nil,
       prev_repo_states: prev_states,
       kerto_status: Kanni.Context.status(),
       plugin_panels: collect_plugin_panels()
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
    <div class="kanni-shell">
      <div class="kanni-header">
        <span class="kanni-logo">Känni</span>
        <span class="kanni-tagline">context exchange surface</span>
      </div>
      <div class="kanni-panels">
        <.repos_panel repos={@repos} selected_path={@selected_path} />

        <.focus_panel selected_repo={@selected_repo} active_tab={@active_tab}>
          <:changes>
            <.live_component
              :if={@handle}
              module={KanniWeb.ChangesComponent}
              id="changes"
              repo_path={@selected_path}
              handle={@handle}
            />
            <div :if={!@handle} class="kanni-placeholder">
              <p>Loading...</p>
            </div>
          </:changes>
          <:graph>
            <div :if={@graph} style="color: #6b6b80; font-size: 0.75rem; margin-bottom: 0.5rem;">
              {@graph.total_commits} commits · {@graph.max_columns} lanes · {format_branches(
                @graph.branches
              )}
            </div>
            <div style="overflow-x: auto;">
              <canvas id="commit-graph" phx-hook="GraphHook" phx-update="ignore"></canvas>
            </div>
          </:graph>
          <:activity>
            <.live_component
              module={KanniWeb.ActivityComponent}
              id="activity"
              entries={@activity}
            />
          </:activity>
        </.focus_panel>

        <.context_panel
          selected_repo={@selected_repo}
          context={@context}
          kerto_status={@kerto_status}
          plugin_panels={@plugin_panels}
        />
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("select_repo", %{"path" => path}, socket) do
    {:noreply, push_patch(socket, to: "/?repo=#{URI.encode(path)}")}
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

  @impl true
  def handle_info({:refresh_changes, _path}, socket) do
    send_update(KanniWeb.ChangesComponent,
      id: "changes",
      force_refresh: true,
      repo_path: socket.assigns.selected_path,
      handle: socket.assigns.handle
    )

    if pid = worker_pid(socket.assigns.selected_path) do
      Kanni.Repo.Worker.refresh(pid)
    end

    {:noreply, socket}
  end

  def handle_info({:repo_state_changed, repo_state}, socket) do
    repos = update_repo_in_list(socket.assigns.repos, repo_state)

    # Detect state changes for activity stream
    old_state = Map.get(socket.assigns.prev_repo_states, repo_state.path)
    change_entries = Activity.detect_state_changes(old_state, repo_state)
    prev_states = Map.put(socket.assigns.prev_repo_states, repo_state.path, repo_state)

    activity = Activity.prepend(socket.assigns.activity, change_entries)

    socket = assign(socket, repos: repos, activity: activity, prev_repo_states: prev_states)

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

    # Start debounce timer if not already running
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

  defp select_repo(socket, path) do
    repo = Enum.find(socket.assigns.repos, &(&1.path == path))

    repo =
      repo ||
        case Kanni.Repo.Worker.get_state(path) do
          {:ok, state} -> state
          _ -> %{path: path, name: Path.basename(path), status: :unknown}
        end

    handle =
      case Kanni.Repo.Worker.get_handle(path) do
        {:ok, h} -> h
        _ -> nil
      end

    context =
      case Kanni.Context.get_repo_context(repo.name) do
        {:ok, ctx} -> ctx
        _ -> nil
      end

    socket
    |> assign(
      selected_path: path,
      selected_repo: repo,
      handle: handle,
      context: context,
      error: nil,
      kerto_status: Kanni.Context.status()
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
    case Registry.lookup(Kanni.Repo.Registry, path) do
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
      match?([{_, _}], Registry.lookup(Kanni.Repo.Registry, path))
  end

  defp collect_plugin_panels do
    Kanni.Plugin.Registry.panel_providers()
    |> Enum.flat_map(fn mod ->
      try do
        mod.panels()
      rescue
        e ->
          require Logger
          Logger.warning("Plugin #{inspect(mod)} panels/0 failed: #{Exception.message(e)}")
          []
      end
    end)
  end
end
