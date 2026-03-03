defmodule Kanni.Plugin do
  @moduledoc """
  Behaviour for Kanni plugins.

  A plugin implements any combination of capabilities:
  - `:context_provider` — answers "what do you know about X?"
  - `:event_consumer` — receives file changes, commits, etc.
  - `:action_provider` — adds commands (trigger build, run tests)
  - `:panel_provider` — contributes UI sections to the dashboard
  """

  @type capability :: :context_provider | :event_consumer | :action_provider | :panel_provider

  @callback name() :: String.t()
  @callback capabilities() :: [capability()]

  @doc "Return a child spec if the plugin needs a supervised process."
  @callback child_spec(keyword()) :: Supervisor.child_spec() | nil

  @doc "Called after the plugin's child process (if any) has started."
  @callback init(keyword()) :: :ok

  @optional_callbacks child_spec: 1, init: 1
end
