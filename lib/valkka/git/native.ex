defmodule Valkka.Git.Native do
  @moduledoc """
  Rust NIF bindings for git operations via libgit2.

  All functions run on the BEAM's dirty CPU scheduler to avoid
  blocking normal schedulers during potentially slow git I/O.
  """

  use Rustler,
    otp_app: :valkka,
    crate: "valkka_git"

  @doc "Open a git repository at the given filesystem path."
  @spec repo_open(String.t()) :: {:ok, reference()} | {:error, String.t()}
  def repo_open(_path), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Close a repository handle."
  @spec repo_close(reference()) :: :ok
  def repo_close(_handle), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Get the working directory status as a JSON string."
  @spec repo_status(reference()) :: {:ok, String.t()} | {:error, String.t()}
  def repo_status(_handle), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Scan a directory for git repositories. Returns JSON array."
  @spec workspace_scan(String.t(), non_neg_integer()) :: {:ok, String.t()} | {:error, String.t()}
  def workspace_scan(_root, _max_depth), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Get head info (branch, ahead/behind, detached) as JSON."
  @spec repo_head_info(reference()) :: {:ok, String.t()} | {:error, String.t()}
  def repo_head_info(_handle), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Get diff for a specific file. staged=true diffs index vs HEAD."
  @spec repo_diff_file(reference(), String.t(), boolean()) :: String.t()
  def repo_diff_file(_handle, _path, _staged), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Get diff for an untracked file (full content as additions)."
  @spec repo_diff_untracked(reference(), String.t()) :: String.t()
  def repo_diff_untracked(_handle, _path), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Stage a file (add to index)."
  @spec repo_stage(reference(), String.t()) :: :ok | {:error, String.t()}
  def repo_stage(_handle, _path), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Unstage a file (reset to HEAD)."
  @spec repo_unstage(reference(), String.t()) :: :ok | {:error, String.t()}
  def repo_unstage(_handle, _path), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Create a commit from the current index."
  @spec repo_commit(reference(), String.t(), String.t(), String.t()) :: String.t()
  def repo_commit(_handle, _message, _author_name, _author_email),
    do: :erlang.nif_error(:nif_not_loaded)
end
