defmodule ValkkaWeb.CommitComponent do
  @moduledoc """
  Commit form: message textarea, commit button, push button.
  """

  use ValkkaWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok, assign(socket, message: "", committing: false, pushing: false, result: nil, branching: false, branch_name: "")}
  end

  @impl true
  def update(%{action: :toggle_branch}, socket) do
    {:ok, assign(socket, branching: !socket.assigns.branching, branch_name: "")}
  end

  def update(%{action: :push}, socket) do
    if socket.assigns.pushing do
      {:ok, socket}
    else
      {:ok, do_push(socket)}
    end
  end

  def update(assigns, socket) do
    {:ok, assign(socket, Map.take(assigns, [:repo_path, :handle, :id, :has_staged]))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="valkka-commit-form">
      <form phx-submit="commit" phx-target={@myself}>
        <textarea
          name="message"
          placeholder="Commit message..."
          class="valkka-commit-input"
          rows="3"
          phx-target={@myself}
        >{@message}</textarea>
        <div class="valkka-commit-actions">
          <button
            type="submit"
            class="valkka-btn primary"
            disabled={!@has_staged || @committing}
          >
            {if @committing, do: "Committing...", else: "Commit staged"}
          </button>
          <button
            type="button"
            class="valkka-btn default"
            phx-click="push"
            phx-target={@myself}
            disabled={@pushing}
            data-confirm="Push to origin?"
          >
            {if @pushing, do: "Pushing...", else: "Push"}
          </button>
          <button
            type="button"
            class="valkka-btn ghost"
            phx-click="toggle_branch"
            phx-target={@myself}
          >
            Branch
          </button>
        </div>
      </form>

      <form :if={@branching} phx-submit="create_branch" phx-target={@myself} class="valkka-branch-form">
        <input
          type="text"
          name="name"
          placeholder="new-branch-name"
          class="valkka-input valkka-branch-input"
          value={@branch_name}
          autofocus
        />
        <button type="submit" class="valkka-btn primary">Create</button>
        <button type="button" class="valkka-btn ghost" phx-click="toggle_branch" phx-target={@myself}>Cancel</button>
      </form>
      <div
        :if={@result}
        class={"valkka-commit-result #{if elem(@result, 0) == :ok, do: "success", else: "error"}"}
      >
        {elem(@result, 1)}
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("commit", %{"message" => message}, socket) do
    message = String.trim(message)

    if message == "" do
      {:noreply, assign(socket, result: {:error, "Commit message required"})}
    else
      socket = assign(socket, committing: true, result: nil)

      case Valkka.Repo.Worker.commit(socket.assigns.repo_path, message) do
        {:ok, oid} ->
          short = String.slice(oid, 0, 7)

          send(self(), {:refresh_changes, socket.assigns.repo_path})
          send(self(), {:flash, :info, "Committed #{short}"})

          {:noreply,
           assign(socket,
             message: "",
             committing: false,
             result: {:ok, "Committed #{short}"}
           )}

        {:error, reason} ->
          send(self(), {:flash, :error, "Commit failed: #{inspect(reason)}"})

          {:noreply,
           assign(socket, committing: false, result: {:error, "Commit failed: #{inspect(reason)}"})}
      end
    end
  end

  def handle_event("push", _params, socket) do
    {:noreply, do_push(socket)}
  end

  def handle_event("toggle_branch", _params, socket) do
    {:noreply, assign(socket, branching: !socket.assigns.branching, branch_name: "")}
  end

  def handle_event("create_branch", %{"name" => name}, socket) do
    name = String.trim(name)

    if name == "" do
      {:noreply, assign(socket, result: {:error, "Branch name required"})}
    else
      case Valkka.Repo.Worker.create_branch(socket.assigns.repo_path, name) do
        {:ok, _} ->
          send(self(), {:refresh_changes, socket.assigns.repo_path})
          send(self(), {:flash, :info, "Switched to #{name}"})
          {:noreply, assign(socket, branching: false, branch_name: "", result: {:ok, "Branch #{name}"})}

        {:error, reason} ->
          send(self(), {:flash, :error, "Branch failed: #{inspect(reason)}"})
          {:noreply, assign(socket, result: {:error, "Branch failed: #{inspect(reason)}"})}
      end
    end
  end

  defp do_push(socket) do
    socket = assign(socket, pushing: true, result: nil)

    case Valkka.Repo.Worker.push(socket.assigns.repo_path) do
      {:ok, _} ->
        send(self(), {:push_completed, socket.assigns.repo_path})
        send(self(), {:flash, :info, "Pushed to origin"})
        assign(socket, pushing: false, result: {:ok, "Pushed"})

      {:error, {msg, _}} ->
        send(self(), {:flash, :error, "Push failed: #{msg}"})
        assign(socket, pushing: false, result: {:error, "Push failed: #{msg}"})

      {:error, reason} ->
        send(self(), {:flash, :error, "Push failed: #{inspect(reason)}"})
        assign(socket, pushing: false, result: {:error, "Push failed: #{inspect(reason)}"})
    end
  end
end
