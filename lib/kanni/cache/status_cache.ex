defmodule Kanni.Cache.StatusCache do
  @moduledoc """
  ETS-backed cache for repository working directory status.

  Caches the result of `git status` operations to avoid
  repeated NIF calls during rapid UI updates.
  """

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    table = :ets.new(:kanni_status_cache, [:set, :public, :named_table])
    {:ok, %{table: table}}
  end
end
