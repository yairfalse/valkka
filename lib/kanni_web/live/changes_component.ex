defmodule KanniWeb.ChangesComponent do
  @moduledoc """
  LiveComponent showing staged, unstaged, and untracked files for a repo.
  Clicking a file loads its diff. Stage/unstage buttons per file.
  """

  use KanniWeb, :live_component

  import KanniWeb.Components.DiffViewer

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
       loading: true
     )}
  end

  @impl true
  def update(%{repo_path: path, handle: handle} = assigns, socket) do
    socket = assign(socket, repo_path: path, handle: handle)

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
        case Kanni.Git.Native.repo_stage(socket.assigns.handle, file) do
          {:error, reason} -> send(self(), {:flash, :error, "Stage failed: #{reason}"})
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
        case Kanni.Git.Native.repo_unstage(socket.assigns.handle, file) do
          {:error, reason} -> send(self(), {:flash, :error, "Unstage failed: #{reason}"})
          _ -> :ok
        end

        {:ok, reload_status(socket)}

      _ ->
        {:ok, socket}
    end
  end

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="kanni-changes">
      <div class="kanni-file-lists">
        <.file_section
          title="Staged"
          files={@staged}
          section="staged"
          action="unstage"
          action_label="u"
          selected_file={@selected_file}
          selected_section={@selected_section}
          myself={@myself}
        />
        <.file_section
          title="Unstaged"
          files={@unstaged}
          section="unstaged"
          action="stage"
          action_label="s"
          selected_file={@selected_file}
          selected_section={@selected_section}
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
          myself={@myself}
        />
        <div
          :if={@staged == [] && @unstaged == [] && @untracked == []}
          class="kanni-empty"
        >
          Working tree clean
        </div>
      </div>

      <div :if={@staged != []} class="kanni-commit-area">
        <.live_component
          module={KanniWeb.CommitComponent}
          id="commit-form"
          repo_path={@repo_path}
          handle={@handle}
          has_staged={@staged != []}
        />
      </div>

      <div :if={@diff} class="kanni-diff-area">
        <.diff_viewer diff={@diff} />
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
  attr :myself, :any, required: true

  defp file_section(assigns) do
    ~H"""
    <div :if={@files != []} class="kanni-file-section">
      <div class="kanni-section-header">
        <span class="kanni-section-title">{@title}</span>
        <div class="kanni-section-actions">
          <span class="kanni-section-count">{length(@files)}</span>
          <button
            class="kanni-action-btn"
            phx-click={"#{@action}_all"}
            phx-value-section={@section}
            phx-target={@myself}
            title={"#{String.capitalize(@action)} all"}
          >
            {String.capitalize(@action)} all
          </button>
        </div>
      </div>
      <div
        :for={file <- @files}
        class={"kanni-file-entry #{if @selected_file == file["path"] && @selected_section == @section, do: "selected"}"}
        phx-click="select_file"
        phx-value-path={file["path"]}
        phx-value-section={@section}
        phx-target={@myself}
      >
        <span class={"kanni-file-status #{file["status"]}"}>
          {status_letter(file["status"])}
        </span>
        <span class="kanni-file-path">{file["path"]}</span>
        <button
          class="kanni-action-btn kanni-file-action"
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
    case Kanni.Git.Native.repo_stage(socket.assigns.handle, path) do
      {:error, reason} -> send(self(), {:flash, :error, "Stage failed: #{reason}"})
      _ -> :ok
    end

    {:noreply, reload_status(socket)}
  end

  def handle_event("unstage", %{"path" => path}, socket) do
    case Kanni.Git.Native.repo_unstage(socket.assigns.handle, path) do
      {:error, reason} -> send(self(), {:flash, :error, "Unstage failed: #{reason}"})
      _ -> :ok
    end

    {:noreply, reload_status(socket)}
  end

  def handle_event("stage_all", _params, socket) do
    handle = socket.assigns.handle

    for file <- socket.assigns.unstaged ++ socket.assigns.untracked do
      Kanni.Git.Native.repo_stage(handle, file["path"])
    end

    {:noreply, reload_status(socket)}
  end

  def handle_event("unstage_all", _params, socket) do
    handle = socket.assigns.handle

    for file <- socket.assigns.staged do
      Kanni.Git.Native.repo_unstage(handle, file["path"])
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
    case Kanni.Git.Native.repo_status(handle) do
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
        "staged" -> Kanni.Git.Native.repo_diff_file(handle, path, true)
        "unstaged" -> Kanni.Git.Native.repo_diff_file(handle, path, false)
        "untracked" -> Kanni.Git.Native.repo_diff_untracked(handle, path)
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
end
