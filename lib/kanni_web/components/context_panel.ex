defmodule KanniWeb.Components.ContextPanel do
  @moduledoc """
  Right panel: shows context from any registered context provider plugin.
  Falls back to a "No plugins" message when none are active.
  """

  use Phoenix.Component

  attr :selected_repo, :map, default: nil
  attr :context, :string, default: nil
  attr :kerto_status, :map, default: %{}
  attr :plugin_panels, :list, default: []

  def context_panel(assigns) do
    ~H"""
    <div class="kanni-context-panel">
      <div class="kanni-panel-header">
        <span class="kanni-panel-title">Context</span>
        <span :if={@kerto_status != %{}} class="kanni-kerto-status">
          {@kerto_status[:nodes] || 0}n · {@kerto_status[:relationships] || 0}r
        </span>
      </div>
      <div class="kanni-context-content">
        <div :if={@context} class="kanni-context-rendered">
          <pre class="kanni-context-text">{@context}</pre>
        </div>
        <div :if={!@context} class="kanni-empty">
          <p :if={@selected_repo && has_plugins?(assigns)}>No context yet</p>
          <p :if={@selected_repo && !has_plugins?(assigns)} class="kanni-no-plugins">
            No plugins active
          </p>
          <p :if={!@selected_repo}>Select a repo</p>
        </div>
      </div>
    </div>
    """
  end

  defp has_plugins?(assigns) do
    assigns[:kerto_status] != %{} or assigns[:plugin_panels] != []
  end
end
