defmodule Valkka.Plugin.Events do
  @moduledoc """
  Event dispatcher for plugin event consumers.

  Each consumer is called in a Task.Supervisor child — fire-and-forget,
  crash-isolated so one failing consumer can't affect others.
  """

  require Logger

  @doc "Dispatch an event to all registered event consumers."
  def dispatch(type, payload) when is_atom(type) and is_map(payload) do
    event = %{type: type, payload: payload, timestamp: DateTime.utc_now()}

    for mod <- Valkka.Plugin.Registry.event_consumers() do
      Task.Supervisor.start_child(Valkka.TaskSupervisor, fn ->
        try do
          mod.handle_event(event)
        rescue
          e ->
            Logger.warning("Plugin #{mod.name()} failed to handle #{type}: #{Exception.message(e)}")
        end
      end)
    end

    :ok
  end
end
