defmodule Kanni.Cache.CommitCache do
  @moduledoc """
  ETS-backed cache for commit metadata.

  Stores parsed commit data (message, author, timestamp) indexed
  by OID for fast lookup without hitting the NIF layer.
  """

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    table = :ets.new(:kanni_commit_cache, [:set, :public, :named_table])
    {:ok, %{table: table}}
  end
end
