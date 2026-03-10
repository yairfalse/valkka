defmodule Valkka.Plugin do
  @moduledoc """
  Behaviour for Valkka plugins.

  A plugin implements any combination of capabilities:
  - `:context_provider` — answers "what do you know about X?"
  - `:event_consumer` — receives file changes, commits, etc.
  - `:action_provider` — adds commands (trigger build, run tests)
  - `:panel_provider` — contributes UI sections to the dashboard
  - `:agent_detector` — detects AI agents running in repos
  """

  @type capability ::
          :context_provider
          | :event_consumer
          | :action_provider
          | :panel_provider
          | :agent_detector

  @callback name() :: String.t()
  @callback capabilities() :: [capability()]

  @doc "Return a child spec if the plugin needs a supervised process."
  @callback child_spec(keyword()) :: Supervisor.child_spec() | nil

  # init/1 is not declared as a callback to avoid conflicts with
  # GenServer.init/1 in plugins that use GenServer. The Plugin.Supervisor
  # checks function_exported?/3 at runtime instead.

  @optional_callbacks child_spec: 1
end
