defmodule Kanni.AI.Providers.Null do
  @moduledoc """
  Offline AI provider that returns canned responses.

  Used when no AI provider is configured, during testing, or when
  the user explicitly wants to work offline.
  """

  @behaviour Kanni.AI.Provider

  @impl true
  def complete(_prompt, _opts \\ []) do
    {:ok, "[AI offline] No provider configured."}
  end

  @impl true
  def summarize_diff(_diff) do
    {:ok, "[AI offline] Diff summary unavailable."}
  end

  @impl true
  def suggest_commit_message(_diff) do
    {:ok, "Update files"}
  end
end
