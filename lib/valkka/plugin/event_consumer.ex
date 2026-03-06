defmodule Valkka.Plugin.EventConsumer do
  @moduledoc """
  Capability for plugins that consume events (file changes, commits, etc.).
  """

  @type event :: %{type: atom(), payload: map(), timestamp: DateTime.t()}

  @callback handle_event(event()) :: :ok
end
