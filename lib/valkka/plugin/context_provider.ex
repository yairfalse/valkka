defmodule Valkka.Plugin.ContextProvider do
  @moduledoc """
  Capability for plugins that provide contextual knowledge.
  """

  @callback get_file_context(String.t()) :: {:ok, String.t() | nil} | {:error, term()}
  @callback get_repo_context(String.t()) :: {:ok, String.t() | nil} | {:error, term()}

  @doc "Return a status map (e.g. node/relationship counts)."
  @callback status() :: map()

  @optional_callbacks status: 0
end
