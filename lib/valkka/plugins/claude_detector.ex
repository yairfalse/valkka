defmodule Valkka.Plugins.ClaudeDetector do
  @moduledoc """
  Detects Claude Code agent processes and maps them to repos.

  Polls `ps` to find claude processes, then `lsof` to resolve
  working directories. Broadcasts changes on the "agents" PubSub topic.
  """

  use GenServer

  @behaviour Valkka.Plugin
  @behaviour Valkka.Plugin.AgentDetector

  @poll_interval 3_000

  # Plugin callbacks

  @impl Valkka.Plugin
  def name, do: "Claude Detector"

  @impl Valkka.Plugin
  def capabilities, do: [:agent_detector]

  @impl Valkka.Plugin
  def child_spec(_opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [[]]}}
  end

  # AgentDetector callback — reads from cached state

  @impl Valkka.Plugin.AgentDetector
  def detect_agents do
    GenServer.call(__MODULE__, :detect_agents)
  catch
    :exit, _ -> []
  end

  # GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    schedule_poll()
    {:ok, %{agents: []}}
  end

  @impl GenServer
  def handle_call(:detect_agents, _from, state) do
    {:reply, state.agents, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    agents = scan_agents()
    schedule_poll()

    if agents_changed?(state.agents, agents) do
      {started, stopped} = compute_agent_diffs(state.agents, agents)

      for agent <- started do
        Phoenix.PubSub.broadcast(Valkka.PubSub, "agents", {:agent_started, agent})
      end

      for agent <- stopped do
        Phoenix.PubSub.broadcast(Valkka.PubSub, "agents", {:agent_stopped, agent})
      end

      Phoenix.PubSub.broadcast(Valkka.PubSub, "agents", {:agents_changed, agents})
      {:noreply, %{state | agents: agents}}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Detection logic

  defp scan_agents do
    with {:ok, pids_with_state} <- find_claude_pids(),
         {:ok, pid_dirs} <- resolve_working_dirs(pids_with_state) do
      pid_dirs
    else
      _ -> []
    end
  catch
    :throw, :not_found -> []
  end

  defp find_claude_pids do
    unless System.find_executable("ps"), do: throw(:not_found)

    case System.cmd("ps", ["-eo", "pid,state,comm"], stderr_to_stdout: true) do
      {output, 0} ->
        pids =
          output
          |> String.split("\n")
          |> Enum.filter(&String.contains?(&1, "claude"))
          |> Enum.flat_map(fn line ->
            case String.split(String.trim(line), ~r/\s+/, parts: 3) do
              [pid_str, state | _] ->
                case Integer.parse(pid_str) do
                  {pid, _} -> [{pid, String.starts_with?(state, "R")}]
                  :error -> []
                end

              _ ->
                []
            end
          end)

        {:ok, pids}

      _ ->
        {:error, :ps_failed}
    end
  end

  defp resolve_working_dirs([]), do: {:ok, []}

  defp resolve_working_dirs(pids_with_state) do
    unless System.find_executable("lsof"), do: throw(:not_found)

    pid_strs = Enum.map(pids_with_state, fn {pid, _} -> Integer.to_string(pid) end)
    state_map = Map.new(pids_with_state)

    case System.cmd("lsof", ["-p", Enum.join(pid_strs, ","), "-d", "cwd", "-Fn"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        agents =
          output
          |> parse_lsof_output()
          |> Enum.flat_map(fn {pid, path} ->
            case Map.fetch(state_map, pid) do
              {:ok, active} ->
                [%{name: "Claude", pid: pid, repo_path: path, active: active}]

              :error ->
                []
            end
          end)

        {:ok, agents}

      _ ->
        {:error, :lsof_failed}
    end
  end

  # lsof -Fn output: p<pid>\nn<path>\n repeating
  defp parse_lsof_output(output) do
    output
    |> String.split("\n")
    |> Enum.reduce({nil, []}, fn line, {current_pid, acc} ->
      cond do
        String.starts_with?(line, "p") ->
          case Integer.parse(String.slice(line, 1..-1//1)) do
            {pid, _} -> {pid, acc}
            :error -> {current_pid, acc}
          end

        String.starts_with?(line, "n") and current_pid != nil ->
          path = String.slice(line, 1..-1//1)
          {current_pid, [{current_pid, path} | acc]}

        true ->
          {current_pid, acc}
      end
    end)
    |> elem(1)
  end

  @doc """
  Compute which agents started and stopped between two snapshots.
  Identity key: {pid, repo_path}. Returns {started, stopped}.
  """
  def compute_agent_diffs(old_agents, new_agents) do
    old_keys = MapSet.new(old_agents, &{&1.pid, &1.repo_path})
    new_keys = MapSet.new(new_agents, &{&1.pid, &1.repo_path})

    started =
      new_agents
      |> Enum.filter(fn a -> not MapSet.member?(old_keys, {a.pid, a.repo_path}) end)

    stopped =
      old_agents
      |> Enum.filter(fn a -> not MapSet.member?(new_keys, {a.pid, a.repo_path}) end)

    {started, stopped}
  end

  defp agents_changed?(old, new) do
    old_set = MapSet.new(old, &{&1.pid, &1.active, &1.repo_path, &1.name})
    new_set = MapSet.new(new, &{&1.pid, &1.active, &1.repo_path, &1.name})
    old_set != new_set
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval)
  end
end
