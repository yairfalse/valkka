defmodule Valkka.Cache.ReviewCache do
  @moduledoc """
  ETS-backed cache for review state.

  Owns an ETS table tracking which commits have been reviewed.
  Keyed by {repo_path, commit_oid}.
  """

  use GenServer

  @table :valkka_review_cache

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:set, :public, :named_table])
    {:ok, %{table: table}}
  end

  @doc "Mark a commit as reviewed."
  def mark_reviewed(repo_path, oid) do
    :ets.insert(@table, {{repo_path, oid}, :reviewed, DateTime.utc_now()})
    :ok
  end

  @doc "Check if a commit has been reviewed."
  def reviewed?(repo_path, oid) do
    case :ets.lookup(@table, {repo_path, oid}) do
      [{_, :reviewed, _}] -> true
      _ -> false
    end
  end

  @doc "Clear review state for a repo (e.g., after push)."
  def clear_repo(repo_path) do
    :ets.match_delete(@table, {{repo_path, :_}, :_, :_})
    :ok
  end

  @doc "Get all reviewed OIDs for a repo."
  def reviewed_oids(repo_path) do
    :ets.match(@table, {{repo_path, :"$1"}, :reviewed, :_})
    |> Enum.map(fn [oid] -> oid end)
  end
end
