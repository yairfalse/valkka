defmodule ValkkaWeb.Presence do
  @moduledoc """
  Tracks connected users and their viewing state.

  Each connected browser tracks: user name, assigned color,
  current view, selected repo/tab/commit/file.
  """

  use Phoenix.Presence,
    otp_app: :valkka,
    pubsub_server: Valkka.PubSub

  @topic "presence:global"

  @colors ~w(#5b8def #e5534b #5ec4b6 #a78bfa #f472b6 #3ecf8e #e5a445 #8ab4f8)

  def topic, do: @topic

  @doc "Track a user joining with initial viewing state."
  def track_user(pid, user_id, user_name) do
    color = Enum.at(@colors, :erlang.phash2(user_id, length(@colors)))

    track(pid, @topic, user_id, %{
      user_name: user_name,
      color: color,
      viewing: %{
        view: "fleet",
        repo_path: nil,
        tab: nil,
        selected_commit: nil,
        selected_file: nil
      },
      joined_at: DateTime.utc_now()
    })
  end

  @doc "Update the user's current viewing state."
  def update_viewing(pid, user_id, viewing) do
    update(pid, @topic, user_id, fn meta ->
      %{meta | viewing: Map.merge(meta.viewing, viewing)}
    end)
  end

  @doc "List all currently present users."
  def list_users do
    list(@topic)
    |> Enum.flat_map(fn {user_id, %{metas: metas}} ->
      case metas do
        [meta | _] -> [Map.put(meta, :user_id, user_id)]
        _ -> []
      end
    end)
  end
end
