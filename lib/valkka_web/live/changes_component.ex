defmodule ValkkaWeb.ChangesComponent do
  @moduledoc """
  LiveComponent showing staged, unstaged, and untracked files for a repo.
  Clicking a file loads its diff. Stage/unstage buttons per file.
  """

  use ValkkaWeb, :live_component

  import ValkkaWeb.Components.DiffViewer

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       staged: [],
       unstaged: [],
       untracked: [],
       selected_file: nil,
       selected_section: nil,
       diff: nil,
       loading: true,
       active_agent: nil
     )}
  end

  @impl true
  def update(%{repo_path: path, handle: handle} = assigns, socket) do
    agents = assigns[:agents] || []
    active_agent = Enum.find(agents, fn a -> a.active && a.repo_path == path end)

    socket =
      socket
      |> assign(repo_path: path, handle: handle, active_agent: active_agent)

    socket =
      if socket.assigns.loading || assigns[:force_refresh] do
        load_status(socket, handle)
      else
        socket
      end

    {:ok, socket}
  end

  def update(%{action: :stage_focused}, socket) do
    case {socket.assigns.selected_file, socket.assigns.selected_section} do
      {file, section} when file != nil and section in ["unstaged", "untracked"] ->
        case Valkka.Repo.Worker.stage(socket.assigns.repo_path, file) do
          {:error, reason} -> send(self(), {:flash, :error, "Stage failed: #{inspect(reason)}"})
          _ -> :ok
        end

        {:ok, reload_status(socket)}

      _ ->
        {:ok, socket}
    end
  end

  def update(%{action: :unstage_focused}, socket) do
    case {socket.assigns.selected_file, socket.assigns.selected_section} do
      {file, "staged"} when file != nil ->
        case Valkka.Repo.Worker.unstage(socket.assigns.repo_path, file) do
          {:error, reason} -> send(self(), {:flash, :error, "Unstage failed: #{inspect(reason)}"})
          _ -> :ok
        end

        {:ok, reload_status(socket)}

      _ ->
        {:ok, socket}
    end
  end

  def update(%{action: :stage_all}, socket) do
    case Valkka.Repo.Worker.stage_all(socket.assigns.repo_path) do
      {:error, reason} -> send(self(), {:flash, :error, "Stage all failed: #{inspect(reason)}"})
      _ -> :ok
    end

    {:ok, reload_status(socket)}
  end

  def update(%{action: :discard_file, file: file}, socket) do
    case Valkka.Repo.Worker.discard_file(socket.assigns.repo_path, file) do
      {:ok, _} -> :ok
      {:error, reason} -> send(self(), {:flash, :error, "Discard failed: #{inspect(reason)}"})
    end

    {:ok, reload_status(socket)}
  end

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="valkka-changes-split">
      <div class="valkka-changes-left">
        <div class="valkka-file-lists">
          <.file_section
            title="Staged"
            files={@staged}
            section="staged"
            action="unstage"
            action_label="u"
            selected_file={@selected_file}
            selected_section={@selected_section}
            active_agent={@active_agent}
            myself={@myself}
          />
          <.file_section
            title="Unstaged"
            files={@unstaged}
            section="unstaged"
            action="stage"
            action_label="s"
            discardable={true}
            selected_file={@selected_file}
            selected_section={@selected_section}
            active_agent={@active_agent}
            myself={@myself}
          />
          <.file_section
            title="Untracked"
            files={@untracked}
            section="untracked"
            action="stage"
            action_label="s"
            selected_file={@selected_file}
            selected_section={@selected_section}
            active_agent={@active_agent}
            myself={@myself}
          />
          <div
            :if={@staged == [] && @unstaged == [] && @untracked == []}
            class="valkka-empty"
          >
            Working tree clean
          </div>
        </div>

        <div
          :if={@staged != []}
          class="valkka-commit-bar"
          style="flex-direction:column;height:auto;padding:8px 12px"
        >
          <.live_component
            module={ValkkaWeb.CommitComponent}
            id="commit-form"
            repo_path={@repo_path}
            handle={@handle}
            has_staged={@staged != []}
          />
        </div>
      </div>

      <div class="valkka-changes-right">
        <div :if={@diff} class="valkka-diff-area">
          <.diff_viewer diff={@diff} />
        </div>
        <div :if={!@diff} class="valkka-empty" style="padding-top:40px">
          Click a file to view its diff
        </div>
      </div>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :files, :list, required: true
  attr :section, :string, required: true
  attr :action, :string, required: true
  attr :action_label, :string, required: true
  attr :selected_file, :string, default: nil
  attr :selected_section, :string, default: nil
  attr :discardable, :boolean, default: false
  attr :active_agent, :any, default: nil
  attr :myself, :any, required: true

  defp file_section(assigns) do
    ~H"""
    <div :if={@files != []} class="valkka-changes-section">
      <div class="valkka-section">
        <div class="valkka-section-label">
          {@title} <span class="valkka-section-count">{length(@files)}</span>
        </div>
        <button
          class="valkka-btn ghost"
          style="font-size:11px;height:20px"
          phx-click={"#{@action}_all"}
          phx-value-section={@section}
          phx-target={@myself}
        >
          {String.capitalize(@action)} all
        </button>
      </div>
      <div
        :for={file <- @files}
        class={"valkka-file-row #{if @selected_file == file["path"] && @selected_section == @section, do: "selected"}"}
        phx-click="select_file"
        phx-value-path={file["path"]}
        phx-value-section={@section}
        phx-target={@myself}
      >
        <span class={"valkka-file-status #{file["status"]}"}>
          {status_letter(file["status"])}
        </span>
        <span class="valkka-file-name">{split_dir_name(file["path"])}</span>
        <span :if={@active_agent} class="valkka-file-tag agent">{@active_agent.name}</span>
        <button
          :if={@discardable}
          class="valkka-btn danger valkka-file-action"
          phx-click="discard_file"
          phx-value-path={file["path"]}
          phx-target={@myself}
          data-confirm={"Discard changes to #{file["path"]}?"}
          title="Discard"
        >
          ✕
        </button>
        <button
          class="valkka-btn ghost valkka-file-action"
          phx-click={@action}
          phx-value-path={file["path"]}
          phx-target={@myself}
          title={@action}
        >
          {@action_label}
        </button>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("select_file", %{"path" => path, "section" => section}, socket) do
    send(self(), {:file_selected, path, socket.assigns.repo_path})

    socket =
      socket
      |> assign(selected_file: path, selected_section: section)
      |> load_diff(path, section)

    {:noreply, socket}
  end

  def handle_event("stage", %{"path" => path}, socket) do
    case Valkka.Repo.Worker.stage(socket.assigns.repo_path, path) do
      {:error, reason} -> send(self(), {:flash, :error, "Stage failed: #{inspect(reason)}"})
      _ -> :ok
    end

    {:noreply, reload_status(socket)}
  end

  def handle_event("unstage", %{"path" => path}, socket) do
    case Valkka.Repo.Worker.unstage(socket.assigns.repo_path, path) do
      {:error, reason} -> send(self(), {:flash, :error, "Unstage failed: #{inspect(reason)}"})
      _ -> :ok
    end

    {:noreply, reload_status(socket)}
  end

  def handle_event("stage_all", _params, socket) do
    case Valkka.Repo.Worker.stage_all(socket.assigns.repo_path) do
      {:error, reason} -> send(self(), {:flash, :error, "Stage all failed: #{inspect(reason)}"})
      _ -> :ok
    end

    {:noreply, reload_status(socket)}
  end

  def handle_event("unstage_all", _params, socket) do
    for file <- socket.assigns.staged do
      Valkka.Repo.Worker.unstage(socket.assigns.repo_path, file["path"])
    end

    {:noreply, reload_status(socket)}
  end

  def handle_event("discard_file", %{"path" => path}, socket) do
    case Valkka.Repo.Worker.discard_file(socket.assigns.repo_path, path) do
      {:ok, _} -> :ok
      {:error, reason} -> send(self(), {:flash, :error, "Discard failed: #{inspect(reason)}"})
    end

    {:noreply, reload_status(socket)}
  end

  defp reload_status(socket) do
    socket
    |> load_status(socket.assigns.handle)
    |> then(fn s ->
      if s.assigns.selected_file do
        load_diff(s, s.assigns.selected_file, s.assigns.selected_section)
      else
        s
      end
    end)
  end

  defp load_status(socket, handle) do
    case Valkka.Git.Native.repo_status(handle) do
      json when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, %{"staged" => staged, "unstaged" => unstaged, "untracked" => untracked}} ->
            assign(socket,
              staged: staged,
              unstaged: unstaged,
              untracked: untracked,
              loading: false
            )

          _ ->
            assign(socket, loading: false)
        end

      _ ->
        assign(socket, loading: false)
    end
  end

  defp load_diff(socket, path, section) do
    handle = socket.assigns.handle

    result =
      case section do
        "staged" -> Valkka.Git.Native.repo_diff_file(handle, path, true)
        "unstaged" -> Valkka.Git.Native.repo_diff_file(handle, path, false)
        "untracked" -> Valkka.Git.Native.repo_diff_untracked(handle, path)
      end

    case result do
      json when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, diff} -> assign(socket, diff: diff)
          _ -> socket
        end

      _ ->
        socket
    end
  end

  defp status_letter("added"), do: "A"
  defp status_letter("modified"), do: "M"
  defp status_letter("deleted"), do: "D"
  defp status_letter("renamed"), do: "R"
  defp status_letter("new"), do: "?"
  defp status_letter(_), do: "?"

  defp split_dir_name(path) when is_binary(path) do
    case Path.split(path) do
      [name] ->
        assigns = %{name: name}
        ~H"{@name}"

      parts ->
        dir = Enum.slice(parts, 0..-2//1) |> Path.join()
        name = List.last(parts)
        assigns = %{dir: dir <> "/", name: name}
        ~H|<span class="dir">{@dir}</span>{@name}|
    end
  end

  defp split_dir_name(_), do: ""
end
