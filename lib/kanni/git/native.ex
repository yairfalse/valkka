defmodule Kanni.Git.Native do
  @moduledoc """
  Rust NIF bindings for git operations via libgit2.

  All functions run on the BEAM's dirty CPU scheduler to avoid
  blocking normal schedulers during potentially slow git I/O.
  """

  use Rustler,
    otp_app: :kanni,
    crate: "kanni_git"

  @doc "Open a git repository at the given filesystem path."
  @spec repo_open(String.t()) :: {:ok, reference()} | {:error, String.t()}
  def repo_open(_path), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Close a repository handle."
  @spec repo_close(reference()) :: :ok
  def repo_close(_handle), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Get the working directory status as a JSON string."
  @spec repo_status(reference()) :: {:ok, String.t()} | {:error, String.t()}
  def repo_status(_handle), do: :erlang.nif_error(:nif_not_loaded)
end
