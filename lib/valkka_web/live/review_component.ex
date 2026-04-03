defmodule ValkkaWeb.ReviewComponent do
  @moduledoc """
  Review tab: queue of agent commits needing human review.
  Shows commit list with full diff, mark-reviewed/skip actions.
  """

  use ValkkaWeb, :live_component

  import ValkkaWeb.Components.DiffViewer

  alias Valkka.Review
  alias Valkka.Git.CLI

  @impl true
  def update(%{action: action} = _assigns, socket)
      when action in [:next, :prev, :mark_reviewed, :skip] do
    socket = handle_action(action, socket)
    {:ok, socket}
  end

  def update(assigns, socket) do
    repo_path = assigns.repo_path
    selected_repo = assigns.selected_repo
    ahead = Map.get(selected_repo, :ahead, 0)

    {commits, reviewable, selected, diff} =
      if socket.assigns[:repo_path] == repo_path && socket.assigns[:commits] do
        {socket.assigns.commits, socket.assigns.reviewable, socket.assigns.selected_oid,
         socket.assigns.diff}
      else
        load_review_data(repo_path, ahead)
      end

    {:ok,
     assign(socket,
       repo_path: repo_path,
       selected_repo: selected_repo,
       commits: commits,
       reviewable: reviewable,
       selected_oid: selected,
       diff: diff,
       commit_files: socket.assigns[:commit_files] || []
     )}
  end

  defp handle_action(:next, socket) do
    case next_oid(socket.assigns.reviewable, socket.assigns.selected_oid, 1) do
      nil ->
        socket

      oid ->
        assign(socket, selected_oid: oid, diff: load_commit_diff(socket.assigns.repo_path, oid))
    end
  end

  defp handle_action(:prev, socket) do
    case next_oid(socket.assigns.reviewable, socket.assigns.selected_oid, -1) do
      nil ->
        socket

      oid ->
        assign(socket, selected_oid: oid, diff: load_commit_diff(socket.assigns.repo_path, oid))
    end
  end

  defp handle_action(:mark_reviewed, socket) do
    oid = socket.assigns.selected_oid

    if oid do
      Review.mark_reviewed(socket.assigns.repo_path, oid)

      case next_unreviewed(socket.assigns.reviewable, socket.assigns.repo_path, oid) do
        nil ->
          socket

        next ->
          assign(socket,
            selected_oid: next.oid,
            diff: load_commit_diff(socket.assigns.repo_path, next.oid)
          )
      end
    else
      socket
    end
  end

  defp handle_action(:skip, socket) do
    handle_action(:next, socket)
  end

  defp next_oid(reviewable, current_oid, offset) do
    index = Enum.find_index(reviewable, &(&1.oid == current_oid)) || 0
    new_index = index + offset

    case Enum.at(reviewable, new_index) do
      nil -> nil
      commit -> commit.oid
    end
  end

  defp next_unreviewed(reviewable, repo_path, current_oid) do
    reviewable
    |> Enum.filter(fn c -> c.oid != current_oid && !Review.reviewed?(repo_path, c.oid) end)
    |> List.first()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="valkka-review">
      <div class="valkka-review-header">
        <span class="valkka-review-title">Review Queue</span>
        <span class="valkka-review-progress">
          {reviewed_count(@commits, @repo_path)} of {length(@reviewable)} reviewed
        </span>
      </div>

      <div :if={@reviewable == []} class="valkka-empty" style="padding:32px 16px">
        No agent commits to review
      </div>

      <div :if={@reviewable != []} class="valkka-review-queue">
        <div
          :for={commit <- @reviewable}
          class={"valkka-review-item #{if commit.oid == @selected_oid, do: "selected"} #{if Review.reviewed?(@repo_path, commit.oid), do: "reviewed"}"}
          phx-click="review:select"
          phx-value-oid={commit.oid}
          phx-target={@myself}
        >
          <span class={"valkka-review-check #{if Review.reviewed?(@repo_path, commit.oid), do: "done"}"}>
            {if Review.reviewed?(@repo_path, commit.oid), do: "✓", else: "○"}
          </span>
          <span class="valkka-review-oid">{String.slice(commit.oid, 0, 7)}</span>
          <span class="valkka-review-msg">{truncate(commit.message, 50)}</span>
          <span class="valkka-review-author">{commit.author}</span>
          <span class="valkka-review-time">{format_time(commit.timestamp)}</span>
        </div>
      </div>

      <div :if={@selected_oid && @diff != []} class="valkka-review-diff">
        <div class="valkka-review-diff-header">
          <span class="valkka-review-diff-oid">{String.slice(@selected_oid, 0, 7)}</span>
          <span
            :if={selected_commit = find_commit(@reviewable, @selected_oid)}
            class="valkka-review-diff-msg"
          >
            {selected_commit.message}
          </span>
          <span class="valkka-spacer"></span>
          <button
            :if={!Review.reviewed?(@repo_path, @selected_oid)}
            class="valkka-btn primary small"
            phx-click="review:mark_reviewed"
            phx-value-oid={@selected_oid}
            phx-target={@myself}
          >
            Mark Reviewed
          </button>
          <button
            :if={Review.reviewed?(@repo_path, @selected_oid)}
            class="valkka-btn ghost small"
            disabled
          >
            Reviewed ✓
          </button>
        </div>

        <div class="valkka-review-diff-body valkka-scroll">
          <div :for={file_diff <- @diff} class="valkka-review-file-diff">
            <.diff_viewer diff={file_diff} />
          </div>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("review:select", %{"oid" => oid}, socket) do
    diff = load_commit_diff(socket.assigns.repo_path, oid)
    {:noreply, assign(socket, selected_oid: oid, diff: diff)}
  end

  def handle_event("review:mark_reviewed", %{"oid" => oid}, socket) do
    Review.mark_reviewed(socket.assigns.repo_path, oid)

    # Move to next unreviewed
    next =
      socket.assigns.reviewable
      |> Enum.find(fn c ->
        c.oid != oid && !Review.reviewed?(socket.assigns.repo_path, c.oid)
      end)

    {next_oid, next_diff} =
      if next do
        {next.oid, load_commit_diff(socket.assigns.repo_path, next.oid)}
      else
        {oid, socket.assigns.diff}
      end

    {:noreply, assign(socket, selected_oid: next_oid, diff: next_diff)}
  end

  # ── Private ─────────────────────────────────────────────────

  defp load_review_data(repo_path, ahead) do
    case CLI.log(repo_path, limit: max(ahead, 20)) do
      {:ok, commits} ->
        reviewable = Review.reviewable_commits(commits, repo_path, ahead)
        # Also include already-reviewed agent commits for context
        all_agent =
          commits
          |> then(fn cs -> if ahead > 0, do: Enum.take(cs, ahead), else: cs end)
          |> Enum.filter(fn c -> Review.agent_commit?(c.message, c.author) end)

        first = List.first(reviewable) || List.first(all_agent)
        diff = if first, do: load_commit_diff(repo_path, first.oid), else: []
        selected = if first, do: first.oid, else: nil
        {commits, all_agent, selected, diff}

      _ ->
        {[], [], nil, []}
    end
  end

  defp load_commit_diff(repo_path, oid) do
    case CLI.run(repo_path, ["diff", "#{oid}~1..#{oid}", "--no-color"]) do
      {:ok, output} -> parse_unified_diff(output)
      _ -> []
    end
  end

  defp parse_unified_diff(raw) do
    raw
    |> String.split(~r/^diff --git /m)
    |> Enum.drop(1)
    |> Enum.map(fn chunk ->
      lines = String.split(chunk, "\n")
      path = extract_path(List.first(lines) || "")

      hunks =
        chunk
        |> String.split(~r/^@@/m)
        |> Enum.drop(1)
        |> Enum.map(fn hunk_text ->
          hunk_lines = String.split(hunk_text, "\n")
          header = "@@" <> (List.first(hunk_lines) || "")

          diff_lines =
            hunk_lines
            |> Enum.drop(1)
            |> Enum.reject(&(&1 == ""))
            |> Enum.map(fn line ->
              {origin, content} =
                case line do
                  "+" <> rest -> {"+", rest}
                  "-" <> rest -> {"-", rest}
                  " " <> rest -> {" ", rest}
                  other -> {" ", other}
                end

              %{
                "origin" => origin,
                "content" => content,
                "old_lineno" => nil,
                "new_lineno" => nil
              }
            end)

          %{"header" => header, "lines" => diff_lines}
        end)

      %{"path" => path, "hunks" => hunks}
    end)
  end

  defp extract_path(line) do
    case Regex.run(~r|a/(.+?) b/|, line) do
      [_, path] -> path
      _ -> String.trim(line)
    end
  end

  defp reviewed_count(commits, repo_path) do
    Enum.count(commits, fn c ->
      Review.agent_commit?(c.message, c.author) && Review.reviewed?(repo_path, c.oid)
    end)
  end

  defp find_commit(commits, oid) do
    Enum.find(commits, &(&1.oid == oid))
  end

  defp truncate(nil, _), do: ""
  defp truncate(s, max) when byte_size(s) <= max, do: s
  defp truncate(s, max), do: String.slice(s, 0, max - 1) <> "…"

  defp format_time(nil), do: ""

  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M")

  defp format_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%H:%M")
      _ -> ""
    end
  end

  defp format_time(_), do: ""
end
