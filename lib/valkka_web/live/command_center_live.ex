defmodule ValkkaWeb.CommandCenterLive do
  @moduledoc """
  Mission control — people and agents first, repos second.

  Layout: Status bar (top) | Roster (left) | Feed (center) | Detail (right)
  Primary question: "Is my team making progress, and does anything need me?"
  """

  use ValkkaWeb, :live_view

  import ValkkaWeb.Components.FocusPanel

  alias Valkka.Git.Log
  alias Valkka.Activity
  alias ValkkaWeb.Presence

  @impl true
  def mount(_params, _session, socket) do
    {user_id, user_name} =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Valkka.PubSub, "repos")
        Phoenix.PubSub.subscribe(Valkka.PubSub, "file_events")
        Phoenix.PubSub.subscribe(Valkka.PubSub, "agents")
        Phoenix.PubSub.subscribe(Valkka.PubSub, Presence.topic())

        uid = generate_user_id()
        uname = get_user_name()
        Presence.track_user(self(), uid, uname)
        {uid, uname}
      else
        {nil, nil}
      end

    repos = Valkka.Workspace.list_repos()
    prev_states = Map.new(repos, fn r -> {r.path, r} end)
    agents = Valkka.Status.agents()
    summary = Valkka.Status.agent_summary(agents)

    {:ok,
     assign(socket,
       page_title: "Valkka",
       repos: repos,
       agents: agents,
       agent_summary: summary,
       agent_start_times: %{},
       agent_tick_ref: nil,
       activity: [],
       activity_buffer: %{},
       activity_timer: nil,
       prev_repo_states: prev_states,
       presence_users: [],
       user_id: user_id,
       user_name: user_name,
       # Filter state
       filter_person: nil,
       filter_repo: nil,
       # Detail panel state
       selected_event: nil,
       selected_path: nil,
       selected_repo: nil,
       active_tab: "changes",
       handle: nil,
       graph: nil,
       graph_data: nil,
       selected_commit: nil,
       commit_files: [],
       error: nil,
       review_summary: %{total: 0, reviewed: 0, pending: 0}
     )}
  end

  @impl true
  def handle_params(%{"repo" => path}, _uri, socket) when path != "" do
    if valid_repo_path?(path, socket.assigns.repos) do
      {:noreply, open_repo_detail(socket, path)}
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
      <%!-- Status bar — spans all columns --%>
      <div class="valkka-fleet-status">
        <div class="valkka-fleet-stat active">
          <span :if={@agent_summary.active > 0} class="valkka-pulse"></span>
          <span class="num">{@agent_summary.active}</span>
          <span>agents</span>
        </div>
        <div class={"valkka-fleet-stat #{if dirty_count(@repos) > 0, do: "warn"}"}>
          <span class="num">{dirty_count(@repos)}</span>
          <span>dirty</span>
        </div>
        <div class={"valkka-fleet-stat #{if error_count(@repos) > 0, do: "alert"}"}>
          <span class="num">{error_count(@repos)}</span>
          <span>errors</span>
        </div>
        <span class="valkka-spacer"></span>
        <div class="valkka-fleet-stat muted">
          {length(@repos)} repos
        </div>
        <div :if={last = List.first(@activity)} class="valkka-fleet-stat muted">
          {relative_time(last.timestamp)}
        </div>
      </div>

      <%!-- Roster — left rail --%>
      <aside class="valkka-roster">
        <div class="valkka-roster-section">
          <div class="valkka-roster-label">Team</div>

          <%!-- Current user --%>
          <div
            class={"valkka-person-row #{if @filter_person == nil && @filter_repo == nil, do: "active-filter"}"}
            phx-click="filter_all"
          >
            <span class="valkka-person-avatar">{initial(@user_name)}</span>
            <span class="valkka-person-name">All activity</span>
          </div>

          <%!-- Connected users --%>
          <div
            :for={user <- @presence_users}
            class={"valkka-person-row #{if @filter_person == user.user_id, do: "active-filter"}"}
            phx-click="filter_person"
            phx-value-id={user.user_id}
          >
            <span class="valkka-person-avatar" style={"border-color:#{user.color}"}>
              {initial(user.user_name)}
            </span>
            <div class="valkka-person-info">
              <span class="valkka-person-name">{user.user_name}</span>
              <span class="valkka-person-agent-line">{viewing_label(user.viewing)}</span>
            </div>
          </div>

          <%!-- Active agents --%>
          <div
            :for={agent <- Enum.filter(@agents, & &1.active)}
            class={"valkka-person-row #{if @filter_person == "agent:#{agent.pid}", do: "active-filter"}"}
            phx-click="filter_agent"
            phx-value-pid={agent.pid}
            phx-value-repo={agent.repo_path}
          >
            <span class="valkka-person-avatar agent">
              <span class="valkka-pulse" style="width:4px;height:4px"></span>
            </span>
            <div class="valkka-person-info">
              <span class="valkka-person-name">{agent.name}</span>
              <span class="valkka-person-agent-line">
                {Path.basename(agent.repo_path || "")} · {agent_elapsed(@agent_start_times, agent)}
              </span>
            </div>
          </div>
        </div>

        <div class="valkka-roster-section">
          <div class="valkka-roster-label">Repos</div>
          <div
            :for={repo <- @repos}
            class={"valkka-person-row #{if @filter_repo == repo.path, do: "active-filter"}"}
            phx-click="filter_repo"
            phx-value-path={repo.path}
          >
            <span class={"valkka-dot #{dot_class(repo)}"}></span>
            <span class="valkka-person-name">{repo.name}</span>
            <span :if={Map.get(repo, :dirty_count, 0) > 0} class="valkka-roster-count">
              {repo.dirty_count}
            </span>
          </div>
        </div>
      </aside>

      <%!-- Feed — center --%>
      <main class="valkka-feed">
        <div class="valkka-feed-list">
          <div
            :if={filtered_activity(@activity, @filter_person, @filter_repo, @agents) == []}
            class="valkka-empty"
            style="padding:48px 20px"
          >
            No activity yet. Agents and repo changes will appear here.
          </div>
          <div
            :for={entry <- filtered_activity(@activity, @filter_person, @filter_repo, @agents)}
            class={"valkka-event-card #{event_card_class(entry)} #{if @selected_event && @selected_event.id == entry.id, do: "selected"}"}
            phx-click="select_event"
            phx-value-id={entry.id}
          >
            <div class="valkka-event-avatar">
              <span class={"valkka-event-dot #{event_dot_class(entry)}"}></span>
            </div>
            <div class="valkka-event-body">
              <div class="valkka-event-headline">
                <span class="valkka-event-who">{event_who(entry)}</span>
                <span class="valkka-event-what">{entry.summary}</span>
              </div>
              <div class="valkka-event-meta">
                <span class="valkka-event-repo">{entry.repo}</span>
                <span :if={entry_subtitle_text(entry)} class="valkka-event-detail">
                  {entry_subtitle_text(entry)}
                </span>
              </div>
            </div>
            <div class="valkka-event-time">{relative_time(entry.timestamp)}</div>
          </div>
        </div>
      </main>

      <%!-- Detail — right panel --%>
      <aside class="valkka-detail">
        <%= cond do %>
          <% @selected_path != nil -> %>
            <%!-- Repo detail with tabs --%>
            <.focus_panel
              selected_repo={@selected_repo}
              active_tab={@active_tab}
              active_agent={active_agent_for_repo(@agents, @selected_path)}
              agent_elapsed={agent_elapsed_for_repo(@agent_start_times, @agents, @selected_path)}
              review_count={@review_summary.pending}
              presence_users={[]}
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
              <:review>
                <.live_component
                  :if={@handle}
                  module={ValkkaWeb.ReviewComponent}
                  id="review"
                  repo_path={@selected_path}
                  selected_repo={@selected_repo}
                />
                <div :if={!@handle} class="valkka-empty">Loading...</div>
              </:review>
            </.focus_panel>
          <% @selected_event != nil -> %>
            <%!-- Event detail --%>
            <div class="valkka-detail-header">
              <span class="valkka-detail-title">Event</span>
              <button
                class="valkka-btn ghost"
                phx-click="close_detail"
                style="font-size:11px;height:22px"
              >
                Close
              </button>
            </div>
            <div class="valkka-detail-body">
              <div class="valkka-detail-section">
                <div class="valkka-detail-label">Summary</div>
                <div class="valkka-detail-value">{@selected_event.summary}</div>
              </div>
              <div class="valkka-detail-section">
                <div class="valkka-detail-label">Repository</div>
                <div class="valkka-detail-value">
                  <button
                    class="valkka-btn ghost"
                    style="padding:0;font-size:13px;color:var(--accent)"
                    phx-click="select_repo"
                    phx-value-path={@selected_event.repo_path}
                  >
                    {@selected_event.repo} →
                  </button>
                </div>
              </div>
              <div :if={@selected_event.files != []} class="valkka-detail-section">
                <div class="valkka-detail-label">Files</div>
                <div :for={file <- @selected_event.files} class="valkka-detail-file">{file}</div>
              </div>
            </div>
          <% true -> %>
            <%!-- Empty detail --%>
            <div class="valkka-detail-empty">
              <div class="valkka-detail-empty-text">
                Click an event or repo to see details
              </div>
              <div class="valkka-detail-shortcuts">
                <div class="valkka-cr-shortcut"><kbd>s</kbd> stage</div>
                <div class="valkka-cr-shortcut"><kbd>c</kbd> commit</div>
                <div class="valkka-cr-shortcut"><kbd>p</kbd> push</div>
                <div class="valkka-cr-shortcut"><kbd>[</kbd><kbd>]</kbd> prev/next repo</div>
              </div>
            </div>
        <% end %>
      </aside>
    </div>
    """
  end

  # ── Events ──────────────────────────────────────────────────

  @impl true
  def handle_event("filter_all", _params, socket) do
    {:noreply, assign(socket, filter_person: nil, filter_repo: nil)}
  end

  def handle_event("filter_person", %{"id" => id}, socket) do
    {:noreply, assign(socket, filter_person: id, filter_repo: nil)}
  end

  def handle_event("filter_agent", %{"pid" => pid, "repo" => repo}, socket) do
    {:noreply, assign(socket, filter_person: "agent:#{pid}", filter_repo: repo)}
  end

  def handle_event("filter_repo", %{"path" => path}, socket) do
    {:noreply, assign(socket, filter_person: nil, filter_repo: path)}
  end

  def handle_event("select_event", %{"id" => id}, socket) do
    event = Enum.find(socket.assigns.activity, &(&1.id == id))

    {:noreply,
     assign(socket, selected_event: event, selected_path: nil, selected_repo: nil, handle: nil)}
  end

  def handle_event("select_repo", %{"path" => path}, socket) do
    {:noreply, push_patch(socket, to: "/?repo=#{URI.encode(path)}")}
  end

  def handle_event("close_detail", _params, socket) do
    {:noreply,
     assign(socket, selected_event: nil, selected_path: nil, selected_repo: nil, handle: nil)}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    socket = assign(socket, active_tab: tab)

    socket =
      cond do
        tab == "graph" and socket.assigns.selected_path -> load_graph_if_needed(socket)
        tab == "review" and socket.assigns.selected_path -> load_review_summary(socket)
        true -> socket
      end

    {:noreply, socket}
  end

  def handle_event("toggle_activity_entry", %{"id" => id}, socket) do
    {:noreply, assign(socket, activity: Activity.toggle_entry(socket.assigns.activity, id))}
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

  def handle_event("key:stage_focused", _p, socket),
    do:
      (
        send_update(ValkkaWeb.ChangesComponent, id: "changes", action: :stage_focused)
        {:noreply, socket}
      )

  def handle_event("key:unstage_focused", _p, socket),
    do:
      (
        send_update(ValkkaWeb.ChangesComponent, id: "changes", action: :unstage_focused)
        {:noreply, socket}
      )

  def handle_event("key:focus_commit", _p, socket),
    do: {:noreply, push_event(socket, "focus-commit-input", %{})}

  def handle_event("key:stage_all", _p, socket),
    do:
      (
        send_update(ValkkaWeb.ChangesComponent, id: "changes", action: :stage_all)
        {:noreply, socket}
      )

  def handle_event("key:discard_focused", _p, socket),
    do: {:noreply, push_event(socket, "confirm-discard", %{})}

  def handle_event("key:discard_confirmed", %{"file" => f}, socket),
    do:
      (
        send_update(ValkkaWeb.ChangesComponent, id: "changes", action: :discard_file, file: f)
        {:noreply, socket}
      )

  def handle_event("key:toggle_branch", _p, socket),
    do:
      (
        send_update(ValkkaWeb.CommitComponent, id: "commit-form", action: :toggle_branch)
        {:noreply, socket}
      )

  def handle_event("key:push", %{"confirmed" => true}, socket),
    do:
      (
        send_update(ValkkaWeb.CommitComponent, id: "commit-form", action: :push)
        {:noreply, socket}
      )

  def handle_event("key:push", _p, socket),
    do: {:noreply, push_event(socket, "confirm-push", %{})}

  def handle_event("key:pull", %{"confirmed" => true}, socket),
    do:
      (
        send_update(ValkkaWeb.CommitComponent, id: "commit-form", action: :pull)
        {:noreply, socket}
      )

  def handle_event("key:pull", _p, socket),
    do: {:noreply, push_event(socket, "confirm-pull", %{})}

  def handle_event("key:prev_repo", _p, socket) do
    case repo_at_offset(socket.assigns.repos, socket.assigns.selected_path, -1) do
      nil -> {:noreply, socket}
      repo -> {:noreply, push_patch(socket, to: "/?repo=#{URI.encode(repo.path)}")}
    end
  end

  def handle_event("key:next_repo", _p, socket) do
    case repo_at_offset(socket.assigns.repos, socket.assigns.selected_path, 1) do
      nil -> {:noreply, socket}
      repo -> {:noreply, push_patch(socket, to: "/?repo=#{URI.encode(repo.path)}")}
    end
  end

  def handle_event("key:review_next", _p, socket),
    do:
      (
        send_update(ValkkaWeb.ReviewComponent, id: "review", action: :next)
        {:noreply, socket}
      )

  def handle_event("key:review_prev", _p, socket),
    do:
      (
        send_update(ValkkaWeb.ReviewComponent, id: "review", action: :prev)
        {:noreply, socket}
      )

  def handle_event("key:review_mark", _p, socket),
    do:
      (
        send_update(ValkkaWeb.ReviewComponent, id: "review", action: :mark_reviewed)
        {:noreply, socket}
      )

  def handle_event("key:review_skip", _p, socket),
    do:
      (
        send_update(ValkkaWeb.ReviewComponent, id: "review", action: :skip)
        {:noreply, socket}
      )

  def handle_event("key:show_help", _p, socket), do: {:noreply, socket}

  # ── Info handlers ───────────────────────────────────────────

  @impl true
  def handle_info({:refresh_changes, _path}, socket) do
    send_update(ValkkaWeb.ChangesComponent,
      id: "changes",
      force_refresh: true,
      repo_path: socket.assigns.selected_path,
      handle: socket.assigns.handle
    )

    if pid = worker_pid(socket.assigns.selected_path), do: Valkka.Repo.Worker.refresh(pid)
    {:noreply, socket}
  end

  def handle_info({:flash, level, message}, socket),
    do: {:noreply, put_flash(socket, level, message)}

  def handle_info({:file_selected, _, _}, socket), do: {:noreply, socket}

  def handle_info({:push_completed, path}, socket) do
    if pid = worker_pid(path), do: Valkka.Repo.Worker.refresh(pid)
    repo = Enum.find(socket.assigns.repos, &(&1.path == path))

    entry = %Activity.Entry{
      id: :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false),
      type: :pushed,
      repo: (repo && repo.name) || Path.basename(path),
      repo_path: path,
      summary: "pushed to origin",
      detail: %{branch: repo && repo.branch},
      timestamp: DateTime.utc_now()
    }

    {:noreply, assign(socket, activity: Activity.prepend(socket.assigns.activity, [entry]))}
  end

  def handle_info({:pull_completed, path}, socket) do
    if pid = worker_pid(path), do: Valkka.Repo.Worker.refresh(pid)
    repo = Enum.find(socket.assigns.repos, &(&1.path == path))

    entry = %Activity.Entry{
      id: :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false),
      type: :pulled,
      repo: (repo && repo.name) || Path.basename(path),
      repo_path: path,
      summary: "pulled from origin",
      detail: %{branch: repo && repo.branch},
      timestamp: DateTime.utc_now()
    }

    {:noreply, assign(socket, activity: Activity.prepend(socket.assigns.activity, [entry]))}
  end

  def handle_info({:agent_started, agent}, socket) do
    key = {agent.pid, agent.repo_path}
    start_times = Map.put(socket.assigns.agent_start_times, key, DateTime.utc_now())
    entry = Activity.agent_entry(agent, :agent_started)

    {:noreply,
     assign(socket,
       activity: Activity.prepend(socket.assigns.activity, [entry]),
       agent_start_times: start_times
     )}
  end

  def handle_info({:agent_stopped, agent}, socket) do
    key = {agent.pid, agent.repo_path}
    started_at = Map.get(socket.assigns.agent_start_times, key)
    start_times = Map.delete(socket.assigns.agent_start_times, key)

    session_info =
      if started_at,
        do: %{duration: format_duration(DateTime.diff(DateTime.utc_now(), started_at, :second))},
        else: %{}

    entry = Activity.agent_entry(agent, :agent_stopped, session_info)

    {:noreply,
     assign(socket,
       activity: Activity.prepend(socket.assigns.activity, [entry]),
       agent_start_times: start_times
     )}
  end

  def handle_info({:agents_changed, agents}, socket) do
    summary = Valkka.Status.agent_summary(agents)

    socket =
      if summary.active > 0 && !socket.assigns[:agent_tick_ref] do
        assign(socket, agent_tick_ref: Process.send_after(self(), :agent_tick, 1_000))
      else
        socket
      end

    {:noreply, assign(socket, agents: agents, agent_summary: summary)}
  end

  def handle_info(:agent_tick, socket) do
    if socket.assigns.agent_summary.active > 0 do
      {:noreply, assign(socket, agent_tick_ref: Process.send_after(self(), :agent_tick, 1_000))}
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

    socket = assign(socket, repos: repos, activity: activity, prev_repo_states: prev_states)

    socket =
      if socket.assigns.selected_path == repo_state.path,
        do: assign(socket, selected_repo: repo_state),
        else: socket

    {:noreply, socket}
  end

  def handle_info({:file_changed, path, _events}, socket) do
    {repo_name, repo_path} = repo_info_for_path(path, socket.assigns.repos)

    buffer =
      Activity.buffer_file_change(socket.assigns.activity_buffer, repo_path, repo_name, path)

    timer =
      socket.assigns.activity_timer ||
        Process.send_after(self(), :flush_activity, Activity.window_ms())

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
      if socket.assigns.selected_commit && socket.assigns.selected_commit.oid == oid,
        do: assign(socket, commit_files: files),
        else: socket

    {:noreply, socket}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    {:noreply, assign(socket, presence_users: Presence.list_users())}
  end

  def handle_info({:DOWN, _, :process, _, _}, socket), do: {:noreply, socket}
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── Private ─────────────────────────────────────────────────

  defp open_repo_detail(socket, path) do
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
      selected_event: nil,
      handle: handle,
      error: nil,
      selected_commit: nil,
      commit_files: []
    )
    |> load_review_summary()
    |> then(fn s -> if s.assigns.active_tab == "graph", do: load_graph_if_needed(s), else: s end)
  end

  defp filtered_activity(activity, nil, nil, _agents), do: activity

  defp filtered_activity(activity, nil, repo_path, _agents) do
    Enum.filter(activity, &(&1.repo_path == repo_path))
  end

  defp filtered_activity(activity, "agent:" <> pid_str, _repo_path, _agents) do
    pid = String.to_integer(pid_str)

    Enum.filter(activity, fn e ->
      Map.get(e.detail, :pid) == pid ||
        Map.get(e.detail, :agent_name) != nil
    end)
  end

  defp filtered_activity(activity, _person_id, _repo_path, _agents), do: activity

  defp event_card_class(%{type: type}) when type in [:agent_started, :agent_stopped],
    do: "in-progress"

  defp event_card_class(%{type: :commit}), do: ""
  defp event_card_class(%{type: :pushed}), do: ""
  defp event_card_class(_), do: ""

  defp event_dot_class(%{type: :agent_started}), do: "dot-agent"
  defp event_dot_class(%{type: :agent_stopped}), do: "dot-agent-off"
  defp event_dot_class(%{type: :commit}), do: "dot-commit"
  defp event_dot_class(%{type: :pushed}), do: "dot-push"
  defp event_dot_class(%{type: :pulled}), do: "dot-push"
  defp event_dot_class(%{type: :branch_switched}), do: "dot-branch"
  defp event_dot_class(%{type: :files_changed, detail: %{agent_name: _}}), do: "dot-agent"
  defp event_dot_class(%{type: :files_changed}), do: "dot-files"
  defp event_dot_class(_), do: "dot-default"

  defp event_who(%{type: type, detail: %{agent_name: name}})
       when type in [:agent_started, :agent_stopped, :files_changed], do: name

  defp event_who(%{type: :commit, detail: %{author: author}}) when is_binary(author), do: author
  defp event_who(_), do: nil

  defp entry_subtitle_text(%{type: :commit, detail: %{short_oid: oid}}) when is_binary(oid),
    do: oid

  defp entry_subtitle_text(%{type: :branch_switched, detail: %{from: f, to: t}})
       when is_binary(f) and is_binary(t), do: "#{f} → #{t}"

  defp entry_subtitle_text(%{type: type, detail: %{branch: b}})
       when type in [:pushed, :pulled] and is_binary(b), do: b

  defp entry_subtitle_text(_), do: nil

  defp relative_time(nil), do: ""

  defp relative_time(dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 5 -> "now"
      diff < 60 -> "#{diff}s"
      diff < 3600 -> "#{div(diff, 60)}m"
      diff < 86400 -> "#{div(diff, 3600)}h"
      true -> "#{div(diff, 86400)}d"
    end
  end

  defp dirty_count(repos), do: Enum.count(repos, &(Map.get(&1, :dirty_count, 0) > 0))
  defp error_count(repos), do: Enum.count(repos, &(Map.get(&1, :status) == :error))

  defp initial(nil), do: "?"
  defp initial(name) when is_binary(name), do: String.first(name) |> String.upcase()

  defp viewing_label(%{view: "repo", repo_path: p}) when is_binary(p), do: Path.basename(p)
  defp viewing_label(_), do: ""

  defp dot_class(%{status: :error}), do: "error"
  defp dot_class(%{agent_active: true}), do: "agent"
  defp dot_class(%{dirty_count: n}) when n > 0, do: "dirty"
  defp dot_class(_), do: "clean"

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

  defp load_review_summary(socket) do
    path = socket.assigns.selected_path
    repo = socket.assigns.selected_repo

    if path && repo do
      ahead = Map.get(repo, :ahead, 0)

      case Valkka.Git.CLI.log(path, limit: max(ahead, 20)) do
        {:ok, commits} ->
          assign(socket, review_summary: Valkka.Review.summary(commits, path, ahead))

        _ ->
          assign(socket, review_summary: %{total: 0, reviewed: 0, pending: 0})
      end
    else
      socket
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
    if Enum.any?(repos, &(&1.path == repo_state.path)),
      do: Enum.map(repos, fn r -> if r.path == repo_state.path, do: repo_state, else: r end),
      else: Enum.sort_by([repo_state | repos], & &1.name)
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

  defp active_agent_for_repo(agents, path),
    do: Enum.find(agents, fn a -> a.active && a.repo_path == path end)

  defp agent_elapsed(start_times, agent) do
    key = {agent.pid, agent.repo_path}

    case Map.get(start_times, key) do
      nil -> ""
      started_at -> format_duration(DateTime.diff(DateTime.utc_now(), started_at, :second))
    end
  end

  defp agent_elapsed_for_repo(start_times, agents, path) do
    agent = active_agent_for_repo(agents, path)
    if agent, do: agent_elapsed(start_times, agent), else: nil
  end

  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"
  defp format_duration(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"
  defp format_duration(seconds), do: "#{div(seconds, 3600)}h#{div(rem(seconds, 3600), 60)}m"

  defp repo_at_offset(repos, nil, _offset), do: List.first(repos)

  defp repo_at_offset(repos, current, offset) do
    index = Enum.find_index(repos, &(&1.path == current)) || 0
    Enum.at(repos, rem(index + offset + length(repos), length(repos)))
  end

  defp valid_repo_path?(path, repos) do
    Enum.any?(repos, &(&1.path == path)) or
      match?([{_, _}], Registry.lookup(Valkka.Repo.Registry, path))
  end

  defp generate_user_id, do: :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)

  defp get_user_name do
    case System.cmd("git", ["config", "user.name"], stderr_to_stdout: true) do
      {name, 0} -> String.trim(name)
      _ -> "User"
    end
  end
end
