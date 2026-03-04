defmodule KanniWeb.CommitComponent do
  @moduledoc """
  Commit form: message textarea, commit button, push button.
  """

  use KanniWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok, assign(socket, message: "", committing: false, pushing: false, result: nil)}
  end

  @impl true
  def update(%{action: :push}, socket) do
    if socket.assigns.pushing do
      {:ok, socket}
    else
      socket = assign(socket, pushing: true, result: nil)

      case Kanni.Git.CLI.push(socket.assigns.repo_path) do
        {:ok, _} ->
          send(self(), {:push_completed, socket.assigns.repo_path})
          send(self(), {:flash, :info, "Pushed to origin"})
          {:ok, assign(socket, pushing: false, result: {:ok, "Pushed"})}

        {:error, {msg, _}} ->
          send(self(), {:flash, :error, "Push failed: #{msg}"})
          {:ok, assign(socket, pushing: false, result: {:error, "Push failed: #{msg}"})}
      end
    end
  end

  def update(assigns, socket) do
    {:ok, assign(socket, Map.take(assigns, [:repo_path, :handle, :id, :has_staged]))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="kanni-commit-form">
      <form phx-submit="commit" phx-target={@myself}>
        <textarea
          name="message"
          placeholder="Commit message..."
          class="kanni-commit-input"
          rows="3"
          phx-target={@myself}
        >{@message}</textarea>
        <div class="kanni-commit-actions">
          <button
            type="submit"
            class="kanni-btn kanni-btn-sm"
            disabled={!@has_staged || @committing}
          >
            {if @committing, do: "Committing...", else: "Commit"}
          </button>
          <button
            type="button"
            class="kanni-btn kanni-btn-sm kanni-btn-secondary"
            phx-click="push"
            phx-target={@myself}
            disabled={@pushing}
            data-confirm="Push to origin?"
          >
            {if @pushing, do: "Pushing...", else: "Push"}
          </button>
        </div>
      </form>
      <div
        :if={@result}
        class={"kanni-commit-result #{if elem(@result, 0) == :ok, do: "success", else: "error"}"}
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

      {name, email} = Kanni.Git.CLI.user_config(socket.assigns.repo_path)

      case Kanni.Git.Native.repo_commit(socket.assigns.handle, message, name, email) do
        oid when is_binary(oid) ->
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
          send(self(), {:flash, :error, "Commit failed: #{reason}"})

          {:noreply,
           assign(socket, committing: false, result: {:error, "Commit failed: #{reason}"})}
      end
    end
  end

  def handle_event("push", _params, socket) do
    socket = assign(socket, pushing: true, result: nil)

    case Kanni.Git.CLI.push(socket.assigns.repo_path) do
      {:ok, _} ->
        send(self(), {:push_completed, socket.assigns.repo_path})
        send(self(), {:flash, :info, "Pushed to origin"})
        {:noreply, assign(socket, pushing: false, result: {:ok, "Pushed"})}

      {:error, {msg, _}} ->
        send(self(), {:flash, :error, "Push failed: #{msg}"})
        {:noreply, assign(socket, pushing: false, result: {:error, "Push failed: #{msg}"})}
    end
  end
end
