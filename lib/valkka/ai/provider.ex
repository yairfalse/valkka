defmodule Valkka.AI.Provider do
  @moduledoc """
  Behaviour for AI provider integrations.

  Each provider (Anthropic, OpenAI, local, offline) implements this
  behaviour. The active provider is configured at the application level.
  """

  @type message :: %{role: String.t(), content: String.t()}
  @type response :: {:ok, String.t()} | {:error, term()}

  @callback complete(prompt :: String.t(), opts :: keyword()) :: response()
  @callback summarize_diff(diff :: String.t()) :: response()
  @callback suggest_commit_message(diff :: String.t()) :: response()
end
