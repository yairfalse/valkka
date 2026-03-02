defmodule Kanni.Repo.Supervisor do
  @moduledoc """
  DynamicSupervisor for repository worker processes.

  Each opened git repository gets its own `Kanni.Repo.Worker` process,
  managed by this supervisor. Workers are started on-demand when a user
  opens a repository in the UI.
  """

  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc "Start a new repo worker for the given path."
  @spec open(String.t()) :: DynamicSupervisor.on_start_child()
  def open(path) do
    DynamicSupervisor.start_child(__MODULE__, {Kanni.Repo.Worker, path})
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
