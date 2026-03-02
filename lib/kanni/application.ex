defmodule Kanni.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      KanniWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:kanni, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Kanni.PubSub},
      {Task.Supervisor, name: Kanni.TaskSupervisor},
      Kanni.Cache.GraphCache,
      Kanni.Cache.CommitCache,
      Kanni.Cache.StatusCache,
      Kanni.Repo.Supervisor,
      Kanni.Watcher.Handler,
      KanniWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Kanni.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    KanniWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
