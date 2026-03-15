defmodule ValkkaWeb.Components.ContextPanel do
  @moduledoc """
  Right panel: Activity stream.
  """

  use Phoenix.Component

  slot :activity

  def context_panel(assigns) do
    ~H"""
    <aside class="valkka-right-panel">
      <div class="valkka-rp-body">
        {render_slot(@activity)}
      </div>
    </aside>
    """
  end
end
