defmodule Valkka.Cache.GraphCache do
  @moduledoc """
  ETS-backed cache for the commit graph (DAG).

  Owns an ETS table that stores commit relationships for fast
  graph traversal and visualization. The table is populated
  lazily as commits are fetched.
  """

  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    table = :ets.new(:valkka_graph_cache, [:set, :public, :named_table])
    {:ok, %{table: table}}
  end
end
