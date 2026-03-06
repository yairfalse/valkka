defmodule Valkka.Plugin.AgentDetector do
  @moduledoc """
  Capability for plugins that detect AI agents running in repos.
  """

  @type agent :: %{
          name: String.t(),
          pid: integer(),
          repo_path: String.t(),
          active: boolean()
        }

  @callback detect_agents() :: [agent()]
end
