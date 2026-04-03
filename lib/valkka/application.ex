defmodule Valkka.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ValkkaWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:valkka, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Valkka.PubSub},
      {Task.Supervisor, name: Valkka.TaskSupervisor},
      Valkka.Cache.GraphCache,
      Valkka.Cache.CommitCache,
      Valkka.Cache.StatusCache,
      Valkka.Cache.ReviewCache,
      ValkkaWeb.Presence,
      Valkka.Plugin.Registry,
      Valkka.Plugin.Supervisor,
      {Registry, keys: :unique, name: Valkka.Repo.Registry},
      Valkka.Repo.Supervisor,
      Valkka.Watcher.Handler,
      ValkkaWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Valkka.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Start plugin child processes and scan workspace after boot
    Task.Supervisor.start_child(Valkka.TaskSupervisor, fn ->
      Valkka.Plugin.Supervisor.start_plugins()
      Valkka.Workspace.scan()
    end)

    # In prod release mode (no Tauri), open browser automatically
    if Application.get_env(:valkka, :open_browser, false) do
      Task.Supervisor.start_child(Valkka.TaskSupervisor, fn ->
        Process.sleep(500)
        open_browser("http://localhost:4420")
      end)
    end

    result
  end

  @impl true
  def config_change(changed, _new, removed) do
    ValkkaWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp open_browser(url) do
    case :os.type() do
      {:unix, :darwin} -> System.cmd("open", [url])
      {:unix, _} -> System.cmd("xdg-open", [url])
      {:win32, _} -> System.cmd("cmd", ["/c", "start", url])
    end
  rescue
    _ -> :ok
  end
end
