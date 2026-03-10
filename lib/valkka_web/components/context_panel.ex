defmodule ValkkaWeb.Components.ContextPanel do
  @moduledoc """
  Right panel: Activity stream only.
  Agent info is shown in the activity stream and overview, not in a separate tab.
  """

  use Phoenix.Component

  slot :activity

  def context_panel(assigns) do
    ~H"""
    <aside class="valkka-right-panel">
      <div class="valkka-rp-header">
        <span class="valkka-rp-title">Activity</span>
      </div>
      <div class="valkka-rp-body">
        {render_slot(@activity)}
      </div>
    </aside>
    """
  end
end
