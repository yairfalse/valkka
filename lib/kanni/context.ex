defmodule Kanni.Context do
  @moduledoc """
  Queries context from all registered context provider plugins.
  Returns the first non-nil result.
  """

  @doc "Get rendered context for a file from the first provider that has it."
  def get_file_context(file_path) do
    first_result(fn mod -> mod.get_file_context(file_path) end)
  end

  @doc "Get rendered context for a repo from the first provider that has it."
  def get_repo_context(repo_name) do
    first_result(fn mod -> mod.get_repo_context(repo_name) end)
  end

  @doc "Merge status maps from all context providers."
  def status do
    Kanni.Plugin.Registry.context_providers()
    |> Enum.reduce(%{}, fn mod, acc ->
      if function_exported?(mod, :status, 0) do
        Map.merge(acc, mod.status())
      else
        acc
      end
    end)
  rescue
    _ -> %{}
  end

  defp first_result(fun) do
    Kanni.Plugin.Registry.context_providers()
    |> Enum.reduce_while({:ok, nil}, fn mod, _acc ->
      case fun.(mod) do
        {:ok, nil} -> {:cont, {:ok, nil}}
        {:ok, value} -> {:halt, {:ok, value}}
        {:error, _} -> {:cont, {:ok, nil}}
      end
    end)
  rescue
    _ -> {:ok, nil}
  end
end
