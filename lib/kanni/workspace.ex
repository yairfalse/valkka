defmodule Kanni.Workspace do
  @moduledoc """
  Discovers and manages git repositories across configured workspace roots.

  Scans configured directories for `.git` repos and starts a Worker for each.
  Provides `list_repos/0` for the UI to enumerate live repo state.
  """

  require Logger

  @doc "Scan configured workspace roots and start workers for discovered repos."
  def scan do
    roots = Application.get_env(:kanni, :workspace_roots, [])
    depth = Application.get_env(:kanni, :scan_depth, 1)

    repos =
      roots
      |> Enum.map(&expand_path/1)
      |> Enum.flat_map(fn root -> scan_root(root, depth) end)
      |> Enum.uniq_by(& &1.path)

    Enum.each(repos, fn repo ->
      case Kanni.Repo.Supervisor.open(repo.path) do
        {:ok, _pid} ->
          Logger.debug("Started worker for #{repo.name}")

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to start worker for #{repo.name}: #{inspect(reason)}")
      end
    end)

    repos
  end

  @doc "List all active repos with their current state from workers."
  def list_repos do
    Registry.select(Kanni.Repo.Registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.map(fn {path, pid} ->
      case Kanni.Repo.Worker.get_state(pid) do
        {:ok, state} -> state
        _ -> %{path: path, name: Path.basename(path), status: :error}
      end
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp scan_root(root, depth) do
    case Kanni.Git.Native.workspace_scan(root, depth) do
      json when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, repos} ->
            Enum.map(repos, fn %{"path" => path, "name" => name} ->
              %{path: path, name: name}
            end)

          {:error, reason} ->
            Logger.warning("Failed to parse scan results for #{root}: #{inspect(reason)}")
            []
        end

      {:error, reason} ->
        Logger.warning("Failed to scan #{root}: #{inspect(reason)}")
        []
    end
  end

  defp expand_path("~/" <> rest), do: Path.join(System.user_home!(), rest)
  defp expand_path("~"), do: System.user_home!()
  defp expand_path(path), do: path
end
