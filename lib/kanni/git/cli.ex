defmodule Kanni.Git.CLI do
  @moduledoc """
  Wrapper around the git CLI for operations not yet covered by NIFs.

  Falls back to shelling out to git when libgit2 doesn't support an
  operation (e.g., interactive rebase, some config operations).
  """

  @doc "Run a git command in the given directory."
  @spec run(String.t(), [String.t()]) ::
          {:ok, String.t()} | {:error, {String.t(), non_neg_integer()}}
  def run(repo_path, args) do
    case System.cmd("git", args, cd: repo_path, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {String.trim(output), code}}
    end
  end

  @doc "Get the current branch name."
  @spec current_branch(String.t()) :: {:ok, String.t()} | {:error, term()}
  def current_branch(repo_path) do
    run(repo_path, ["rev-parse", "--abbrev-ref", "HEAD"])
  end

  @doc "Get commit log in topological order with parent and decoration info."
  @spec log(String.t(), keyword()) :: {:ok, [Kanni.Git.Types.Commit.t()]} | {:error, term()}
  def log(repo_path, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    args = [
      "log",
      "--format=%H%x00%P%x00%an%x00%aI%x00%s%x00%D",
      "--topo-order",
      "--all",
      "-n",
      to_string(limit)
    ]

    case run(repo_path, args) do
      {:ok, ""} -> {:ok, []}
      {:ok, output} -> {:ok, parse_log(output)}
      {:error, _} = err -> err
    end
  end

  @doc "Push current branch to origin."
  @spec push(String.t()) :: {:ok, String.t()} | {:error, term()}
  def push(repo_path) do
    run(repo_path, ["push"])
  end

  @doc "Get configured user name and email."
  @spec user_config(String.t()) :: {String.t(), String.t()}
  def user_config(repo_path) do
    name =
      case run(repo_path, ["config", "user.name"]) do
        {:ok, n} -> n
        _ -> "Unknown"
      end

    email =
      case run(repo_path, ["config", "user.email"]) do
        {:ok, e} -> e
        _ -> "unknown@unknown"
      end

    {name, email}
  end

  @doc "List all branches with their head commits."
  @spec branches(String.t()) :: {:ok, [Kanni.Git.Types.Branch.t()]} | {:error, term()}
  def branches(repo_path) do
    args = ["branch", "-a", "--format=%(refname:short)%x00%(objectname)%x00%(HEAD)"]

    case run(repo_path, args) do
      {:ok, ""} -> {:ok, []}
      {:ok, output} -> {:ok, parse_branches(output)}
      {:error, _} = err -> err
    end
  end

  defp parse_log(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&parse_log_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_log_line(line) do
    case String.split(line, "\0") do
      [oid, parents_str, author, timestamp_str, message, decorations] ->
        parents = String.split(parents_str, " ", trim: true)
        {:ok, timestamp, _} = DateTime.from_iso8601(timestamp_str)

        branches =
          decorations
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.map(&strip_decoration_prefix/1)
          |> Enum.reject(&(&1 == ""))

        %Kanni.Git.Types.Commit{
          oid: oid,
          message: message,
          author: author,
          timestamp: timestamp,
          parents: parents
        }
        |> Map.put(:__branches__, branches)

      _ ->
        nil
    end
  end

  defp strip_decoration_prefix("HEAD -> " <> rest), do: rest
  defp strip_decoration_prefix("tag: " <> rest), do: rest
  defp strip_decoration_prefix(ref), do: ref

  defp parse_branches(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&parse_branch_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_branch_line(line) do
    case String.split(line, "\0") do
      [name, oid, head_marker] ->
        %Kanni.Git.Types.Branch{
          name: name,
          head: oid,
          is_current: head_marker == "*"
        }

      _ ->
        nil
    end
  end
end
