defmodule Kanni.Repo.Worker do
  @moduledoc """
  State machine for a single git repository.

  States:
  - `:initializing` — opening the repo via NIF
  - `:idle` — ready for operations
  - `:operating` — a git operation is in progress
  - `:error` — an unrecoverable error occurred

  Each worker holds a NIF resource handle to a git2::Repository.
  """

  @behaviour :gen_statem

  require Logger

  defstruct [:path, :handle]

  @type t :: %__MODULE__{
          path: String.t(),
          handle: reference() | nil
        }

  def start_link(path) do
    :gen_statem.start_link(__MODULE__, path, [])
  end

  def child_spec(path) do
    %{
      id: {__MODULE__, path},
      start: {__MODULE__, :start_link, [path]},
      restart: :transient
    }
  end

  # gen_statem callbacks

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init(path) do
    data = %__MODULE__{path: path}
    {:ok, :initializing, data, [{:next_event, :internal, :open}]}
  end

  def initializing(:internal, :open, data) do
    case Kanni.Git.Native.repo_open(data.path) do
      {:ok, handle} ->
        {:next_state, :idle, %{data | handle: handle}}

      {:error, reason} ->
        Logger.error("Failed to open repo #{data.path}: #{inspect(reason)}")
        {:next_state, :error, data}
    end
  end

  def idle(:info, _msg, data) do
    {:keep_state, data}
  end

  def error(:info, _msg, data) do
    {:keep_state, data}
  end
end
