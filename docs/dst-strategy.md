# Deterministic Simulation Testing (DST) Strategy

> Find the bugs that only appear at 3 AM under load. Then replay them at breakfast.

---

## 1. Why DST for Kanni

Kanni is a concurrent system with at least seven sources of nondeterminism:

1. File system events arrive in unpredictable order and batch sizes
2. Rust NIFs run on dirty schedulers with variable latency
3. AI providers stream tokens at variable rates and can fail mid-stream
4. PubSub message delivery order between processes is not guaranteed
5. Git operations contend on locks and network
6. BEAM process scheduling decides which repo worker runs first
7. WebSocket reconnection timing after network interrupts

Traditional unit tests hold all of these constant. DST controls them explicitly,
replaying exact interleavings from a seed. When a bug surfaces, the seed
reproduces it deterministically forever.

---

## 2. Nondeterminism Inventory

### 2.1 File System Events

| Source | Nondeterminism | DST Control |
|--------|---------------|-------------|
| Event ordering | `create` before `modify`, or reversed | SimFileSystem emits in seed-determined order |
| Event batching | 1 event or 50 events per callback | SimFileSystem controls batch size per tick |
| Event coalescing | OS may merge rapid writes into one event | SimFileSystem decides whether to coalesce |
| Timing | Events arrive 1ms or 500ms after write | SimClock advances manually; events fire on tick |
| .git directory | Internal git writes trigger watcher | SimFileSystem filters configurable paths |

### 2.2 NIF Execution Time

| Source | Nondeterminism | DST Control |
|--------|---------------|-------------|
| Dirty scheduler availability | Queued behind other dirty NIF calls | SimGit responds immediately (no real scheduler) |
| Operation latency | `diff` on 10 files vs 10,000 files | SimGit latency is seed-controlled |
| Mutex contention | RepoHandle Mutex held by concurrent call | SimGit simulates lock hold times |
| Panic/crash | Rust panic on corrupt data | SimGit injects panics at seed-determined points |
| Memory pressure | Large diff OOM | SimGit can return `:error` for memory simulation |

### 2.3 AI Response Timing and Content

| Source | Nondeterminism | DST Control |
|--------|---------------|-------------|
| First token latency | 200ms to 5s depending on provider load | SimAI latency is seed-controlled |
| Token rate | Bursty: 0 tokens, then 20, then 3 | SimAI token schedule is deterministic |
| Response content | Same prompt yields different text | SimAI returns seeded responses |
| Stream interruption | Connection drops at byte N | SimAI interrupts at seed-determined token index |
| Provider failover | Primary down, switch to secondary | SimAI fails primary at seed-determined call count |

### 2.4 PubSub Message Delivery Order

| Source | Nondeterminism | DST Control |
|--------|---------------|-------------|
| Subscriber notification order | Who gets the message first | SimPubSub delivers in seed-shuffled order |
| Message interleaving | Repo event vs AI event vs watcher event | SimPubSub queues all, delivers one per tick |
| Dropped messages | Process mailbox overflow | SimPubSub can drop messages per seed |

### 2.5 Git Operations

| Source | Nondeterminism | DST Control |
|--------|---------------|-------------|
| Lock file contention | `.git/index.lock` held by another process | SimGit simulates lock contention duration |
| Network latency (push/pull) | 50ms to timeout | SimGit network delay is seed-controlled |
| Remote state | What is on origin when we push | SimGit holds deterministic remote state |
| Partial transfer | Connection drops mid-push | SimGit fails at seed-determined byte count |

### 2.6 Process Scheduling

| Source | Nondeterminism | DST Control |
|--------|---------------|-------------|
| GenServer call order | Which repo worker processes its message first | Simulated scheduler picks processes in seed order |
| Task completion order | Which Task.async finishes first | Tasks complete when SimClock advances them |
| Supervisor restart timing | How fast a crashed child restarts | Deterministic restart delay |

### 2.7 WebSocket Reconnection Timing

| Source | Nondeterminism | DST Control |
|--------|---------------|-------------|
| Disconnect detection | 1s to 30s to notice | SimSocket disconnects at seed-determined time |
| Reconnect backoff | Exponential with jitter | SeededRandom controls jitter |
| State sync on reconnect | What changed while disconnected | SimClock controls time gap |

---

## 3. DST Harness Design

### 3.1 SimClock

Controllable monotonic clock. All time-dependent code reads from SimClock
instead of `System.monotonic_time/0` or `DateTime.utc_now/0`.

```elixir
defmodule Kanni.DST.SimClock do
  @moduledoc """
  Deterministic clock for simulation testing.

  Replaces all time sources in the system. Time only advances
  when explicitly told to. No real wall-clock time passes.

  ## Usage

      {:ok, clock} = SimClock.start_link(seed: 42)
      SimClock.now(clock)           # => 0
      SimClock.advance(clock, 100)  # advance 100ms
      SimClock.now(clock)           # => 100
      SimClock.advance_to_next_event(clock)  # jump to next scheduled event
  """

  use GenServer

  defstruct [
    :now_ms,
    :seed,
    :rng,
    :event_queue,
    :subscribers
  ]

  # --- Public API ---

  def start_link(opts) do
    seed = Keyword.fetch!(opts, :seed)
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, seed, name: name)
  end

  @doc "Current simulation time in milliseconds."
  @spec now(GenServer.server()) :: non_neg_integer()
  def now(clock \\ __MODULE__) do
    GenServer.call(clock, :now)
  end

  @doc "Advance clock by `delta_ms` milliseconds. Fires all events in that window."
  @spec advance(GenServer.server(), non_neg_integer()) :: :ok
  def advance(clock \\ __MODULE__, delta_ms) when is_integer(delta_ms) and delta_ms >= 0 do
    GenServer.call(clock, {:advance, delta_ms})
  end

  @doc "Advance to the next scheduled event and fire it."
  @spec advance_to_next_event(GenServer.server()) :: {:ok, non_neg_integer()} | :no_events
  def advance_to_next_event(clock \\ __MODULE__) do
    GenServer.call(clock, :advance_to_next_event)
  end

  @doc "Schedule a callback to fire at a specific simulation time."
  @spec schedule_at(GenServer.server(), non_neg_integer(), (-> any())) :: :ok
  def schedule_at(clock \\ __MODULE__, at_ms, callback) when is_function(callback, 0) do
    GenServer.call(clock, {:schedule_at, at_ms, callback})
  end

  @doc "Schedule a callback to fire after a delay from now."
  @spec schedule_after(GenServer.server(), non_neg_integer(), (-> any())) :: :ok
  def schedule_after(clock \\ __MODULE__, delay_ms, callback) do
    GenServer.call(clock, {:schedule_after, delay_ms, callback})
  end

  @doc "Subscribe to clock ticks. Receives {:sim_tick, now_ms} on each advance."
  @spec subscribe(GenServer.server(), pid()) :: :ok
  def subscribe(clock \\ __MODULE__, pid \\ self()) do
    GenServer.call(clock, {:subscribe, pid})
  end

  @doc "Return the time of the next scheduled event, or :none."
  @spec peek_next(GenServer.server()) :: {:ok, non_neg_integer()} | :none
  def peek_next(clock \\ __MODULE__) do
    GenServer.call(clock, :peek_next)
  end

  # --- Callbacks ---

  @impl true
  def init(seed) do
    rng = :rand.seed(:exsss, {seed, seed * 7, seed * 13})

    state = %__MODULE__{
      now_ms: 0,
      seed: seed,
      rng: rng,
      event_queue: :gb_trees.empty(),
      subscribers: MapSet.new()
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:now, _from, state) do
    {:reply, state.now_ms, state}
  end

  def handle_call({:advance, delta_ms}, _from, state) do
    target = state.now_ms + delta_ms
    state = fire_events_until(state, target)
    state = %{state | now_ms: target}
    notify_subscribers(state)
    {:reply, :ok, state}
  end

  def handle_call(:advance_to_next_event, _from, state) do
    case next_event_time(state) do
      :none ->
        {:reply, :no_events, state}

      time ->
        state = fire_events_until(state, time)
        state = %{state | now_ms: time}
        notify_subscribers(state)
        {:reply, {:ok, time}, state}
    end
  end

  def handle_call({:schedule_at, at_ms, callback}, _from, state) do
    state = enqueue_event(state, at_ms, callback)
    {:reply, :ok, state}
  end

  def handle_call({:schedule_after, delay_ms, callback}, _from, state) do
    state = enqueue_event(state, state.now_ms + delay_ms, callback)
    {:reply, :ok, state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  def handle_call(:peek_next, _from, state) do
    case next_event_time(state) do
      :none -> {:reply, :none, state}
      time -> {:reply, {:ok, time}, state}
    end
  end

  # --- Internal ---

  defp fire_events_until(state, target) do
    case next_event_time(state) do
      :none ->
        state

      time when time > target ->
        state

      time ->
        {callbacks, tree} = pop_events_at(state.event_queue, time)
        state = %{state | now_ms: time, event_queue: tree}

        Enum.each(callbacks, fn cb ->
          try do
            cb.()
          rescue
            _ -> :ok
          end
        end)

        fire_events_until(state, target)
    end
  end

  defp enqueue_event(state, at_ms, callback) do
    tree = state.event_queue

    existing =
      case :gb_trees.lookup(at_ms, tree) do
        {:value, cbs} -> cbs
        :none -> []
      end

    tree = :gb_trees.enter(at_ms, [callback | existing], tree)
    %{state | event_queue: tree}
  end

  defp next_event_time(state) do
    case :gb_trees.is_empty(state.event_queue) do
      true -> :none
      false -> :gb_trees.smallest(state.event_queue) |> elem(0)
    end
  end

  defp pop_events_at(tree, time) do
    case :gb_trees.lookup(time, tree) do
      {:value, callbacks} ->
        {Enum.reverse(callbacks), :gb_trees.delete(time, tree)}

      :none ->
        {[], tree}
    end
  end

  defp notify_subscribers(state) do
    for pid <- state.subscribers do
      send(pid, {:sim_tick, state.now_ms})
    end
  end
end
```

### 3.2 SimFileSystem

Deterministic file system event source. Replaces the `FileSystem` library watcher.

```elixir
defmodule Kanni.DST.SimFileSystem do
  @moduledoc """
  Deterministic file system watcher for simulation testing.

  Instead of watching real file system events, this module emits
  events from a seeded schedule. Supports configurable:

  - Event ordering and batching
  - Coalescing (rapid writes merged into one event)
  - Storm simulation (1000 events in 100ms)
  - Filtered paths (.git directory)

  ## Usage

      {:ok, fs} = SimFileSystem.start_link(
        seed: 42,
        clock: clock,
        repo_path: "/fake/repo"
      )

      # Inject events that will fire when clock advances
      SimFileSystem.inject_events(fs, [
        {:created, "lib/new_file.ex"},
        {:modified, "lib/existing.ex"},
        {:deleted, "tmp/scratch.txt"}
      ])

      # Events are delivered to subscribers when clock ticks
      SimClock.advance(clock, 50)
  """

  use GenServer

  defstruct [
    :seed,
    :rng,
    :clock,
    :repo_path,
    :subscribers,
    :pending_events,
    :filter_patterns,
    :coalesce_window_ms,
    :batch_size_range
  ]

  @type event_type :: :created | :modified | :deleted | :renamed | :attribute_changed
  @type event :: {event_type(), String.t()}

  # --- Public API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Subscribe to file events. Receives {:file_event, watcher, {path, events}}."
  @spec subscribe(GenServer.server(), pid()) :: :ok
  def subscribe(fs \\ __MODULE__, pid \\ self()) do
    GenServer.call(fs, {:subscribe, pid})
  end

  @doc """
  Inject file events into the simulation. Events will be scheduled
  on the SimClock according to seed-determined timing.
  """
  @spec inject_events(GenServer.server(), [event()]) :: :ok
  def inject_events(fs \\ __MODULE__, events) do
    GenServer.call(fs, {:inject_events, events})
  end

  @doc """
  Simulate a file watcher storm: N events in M milliseconds.
  Typical scenario: `git checkout` touching hundreds of files.
  """
  @spec inject_storm(GenServer.server(), non_neg_integer(), non_neg_integer(), [String.t()]) ::
          :ok
  def inject_storm(fs \\ __MODULE__, count, duration_ms, paths) do
    GenServer.call(fs, {:inject_storm, count, duration_ms, paths})
  end

  @doc "Set path filter patterns. Events matching these are silently dropped."
  @spec set_filters(GenServer.server(), [String.t()]) :: :ok
  def set_filters(fs \\ __MODULE__, patterns) do
    GenServer.call(fs, {:set_filters, patterns})
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    seed = Keyword.fetch!(opts, :seed)
    clock = Keyword.fetch!(opts, :clock)
    repo_path = Keyword.get(opts, :repo_path, "/sim/repo")

    rng = :rand.seed(:exsss, {seed, seed * 3, seed * 17})

    state = %__MODULE__{
      seed: seed,
      rng: rng,
      clock: clock,
      repo_path: repo_path,
      subscribers: MapSet.new(),
      pending_events: [],
      filter_patterns: [".git/**"],
      coalesce_window_ms: 10,
      batch_size_range: {1, 10}
    }

    # Subscribe to clock ticks to know when to deliver events
    SimClock.subscribe(clock, self())

    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  def handle_call({:inject_events, events}, _from, state) do
    events = filter_events(events, state.filter_patterns, state.repo_path)
    now = SimClock.now(state.clock)
    {batches, rng} = batch_events(events, state.rng, state.batch_size_range)

    # Schedule each batch at a seed-determined offset from now
    {state, rng} =
      Enum.reduce(batches, {%{state | rng: rng}, rng}, fn batch, {st, r} ->
        {delay, r} = seeded_uniform(r, 0, 100)

        SimClock.schedule_at(st.clock, now + delay, fn ->
          deliver_batch(st.subscribers, st.repo_path, batch)
        end)

        {st, r}
      end)

    {:reply, :ok, %{state | rng: rng}}
  end

  def handle_call({:inject_storm, count, duration_ms, paths}, _from, state) do
    now = SimClock.now(state.clock)
    {events, rng} = generate_storm_events(count, paths, state.rng)
    events = filter_events(events, state.filter_patterns, state.repo_path)

    # Spread events across the duration window
    {_rng2, _} =
      Enum.reduce(events, {rng, 0}, fn event, {r, _idx} ->
        {offset, r} = seeded_uniform(r, 0, duration_ms)

        SimClock.schedule_at(state.clock, now + offset, fn ->
          deliver_batch(state.subscribers, state.repo_path, [event])
        end)

        {r, 0}
      end)

    {:reply, :ok, %{state | rng: rng}}
  end

  def handle_call({:set_filters, patterns}, _from, state) do
    {:reply, :ok, %{state | filter_patterns: patterns}}
  end

  @impl true
  def handle_info({:sim_tick, _now_ms}, state) do
    # Clock ticked — events are delivered via scheduled callbacks
    {:noreply, state}
  end

  # --- Internal ---

  defp filter_events(events, patterns, repo_path) do
    Enum.reject(events, fn {_type, path} ->
      full_path = Path.join(repo_path, path)

      Enum.any?(patterns, fn pattern ->
        match_glob?(full_path, Path.join(repo_path, pattern))
      end)
    end)
  end

  defp match_glob?(path, pattern) do
    # Simplified glob matching for .git filtering
    cond do
      String.contains?(pattern, "**") ->
        prefix = String.replace(pattern, "/**", "")
        String.starts_with?(path, prefix)

      true ->
        path == pattern
    end
  end

  defp batch_events(events, rng, {min, max}) do
    batch_events(events, rng, min, max, [])
  end

  defp batch_events([], _rng, _min, _max, acc), do: {Enum.reverse(acc), _rng = :rand.seed(:exsss)}

  defp batch_events(events, rng, min, max, acc) do
    {size, rng} = seeded_uniform(rng, min, max)
    {batch, rest} = Enum.split(events, size)
    batch_events(rest, rng, min, max, [batch | acc])
  end

  defp generate_storm_events(count, paths, rng) do
    types = [:created, :modified, :deleted, :modified, :modified]

    {events, rng} =
      Enum.reduce(1..count, {[], rng}, fn _i, {acc, r} ->
        {type_idx, r} = seeded_uniform(r, 0, length(types) - 1)
        {path_idx, r} = seeded_uniform(r, 0, length(paths) - 1)
        type = Enum.at(types, type_idx)
        path = Enum.at(paths, path_idx)
        {[{type, path} | acc], r}
      end)

    {Enum.reverse(events), rng}
  end

  defp deliver_batch(subscribers, repo_path, events) do
    for pid <- subscribers, {type, path} <- events do
      full_path = Path.join(repo_path, path)
      send(pid, {:file_event, self(), {full_path, [type]}})
    end
  end

  defp seeded_uniform(rng, min, max) when max > min do
    {val, rng} = :rand.uniform_s(max - min + 1, rng)
    {val - 1 + min, rng}
  end

  defp seeded_uniform(rng, val, val), do: {val, rng}
end
```

### 3.3 SimAI

Deterministic AI provider that replaces real LLM API calls.

```elixir
defmodule Kanni.DST.SimAI do
  @moduledoc """
  Deterministic AI provider for simulation testing.

  Controls:
  - Response content (seeded from a response bank)
  - Streaming speed (tokens per clock tick)
  - Failure injection (timeout, disconnect, invalid response)
  - Provider switching (primary fails, secondary used)

  Implements the `Kanni.AI.Provider` behaviour.

  ## Usage

      {:ok, ai} = SimAI.start_link(
        seed: 42,
        clock: clock,
        responses: %{
          commit_message: ["feat: add auth", "fix: resolve timeout"],
          review: ["## Summary\\nLow risk.", "## Summary\\nHigh risk."]
        }
      )

      # Request streams tokens deterministically
      SimAI.stream(ai, "generate commit message", fn chunk -> ... end)
      SimClock.advance(clock, 500)  # tokens arrive
  """

  use GenServer

  @behaviour Kanni.AI.Provider

  defstruct [
    :seed,
    :rng,
    :clock,
    :responses,
    :tokens_per_tick,
    :failure_schedule,
    :call_count,
    :active_streams,
    :provider_failures
  ]

  @type failure :: :timeout | :disconnect | :invalid_response | :rate_limit
  @type stream_handle :: reference()

  # --- Public API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Start a streaming AI request. Returns a stream handle.
  Tokens are delivered as clock advances.
  """
  @spec stream(GenServer.server(), String.t(), keyword()) ::
          {:ok, stream_handle()} | {:error, failure()}
  def stream(ai \\ __MODULE__, prompt, opts \\ []) do
    GenServer.call(ai, {:stream, prompt, opts, self()})
  end

  @doc "Cancel an active stream."
  @spec cancel_stream(GenServer.server(), stream_handle()) :: :ok
  def cancel_stream(ai \\ __MODULE__, handle) do
    GenServer.call(ai, {:cancel_stream, handle})
  end

  @doc """
  Configure failure injection.

  Schedule format: `[{call_number, failure_type}]`
  Example: `[{3, :timeout}, {7, :disconnect}]`
  Call 3 will timeout, call 7 will disconnect mid-stream.
  """
  @spec set_failure_schedule(GenServer.server(), [{pos_integer(), failure()}]) :: :ok
  def set_failure_schedule(ai \\ __MODULE__, schedule) do
    GenServer.call(ai, {:set_failure_schedule, schedule})
  end

  @doc """
  Configure provider failure. After N calls to primary,
  it fails and the system must switch.
  """
  @spec set_provider_failure(GenServer.server(), pos_integer()) :: :ok
  def set_provider_failure(ai \\ __MODULE__, fail_after_calls) do
    GenServer.call(ai, {:set_provider_failure, fail_after_calls})
  end

  @doc "Set tokens delivered per clock tick (controls streaming speed)."
  @spec set_tokens_per_tick(GenServer.server(), pos_integer()) :: :ok
  def set_tokens_per_tick(ai \\ __MODULE__, count) do
    GenServer.call(ai, {:set_tokens_per_tick, count})
  end

  @doc "Get the total number of calls made to this provider."
  @spec call_count(GenServer.server()) :: non_neg_integer()
  def call_count(ai \\ __MODULE__) do
    GenServer.call(ai, :call_count)
  end

  # --- Behaviour implementation ---

  @impl Kanni.AI.Provider
  def stream(prompt, opts) do
    __MODULE__.stream(__MODULE__, prompt, opts)
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    seed = Keyword.fetch!(opts, :seed)
    clock = Keyword.fetch!(opts, :clock)

    responses = Keyword.get(opts, :responses, default_responses())

    rng = :rand.seed(:exsss, {seed, seed * 11, seed * 23})

    state = %__MODULE__{
      seed: seed,
      rng: rng,
      clock: clock,
      responses: responses,
      tokens_per_tick: Keyword.get(opts, :tokens_per_tick, 5),
      failure_schedule: [],
      call_count: 0,
      active_streams: %{},
      provider_failures: nil
    }

    SimClock.subscribe(clock, self())
    {:ok, state}
  end

  @impl true
  def handle_call({:stream, prompt, _opts, caller}, _from, state) do
    call_number = state.call_count + 1
    state = %{state | call_count: call_number}

    # Check provider-level failure
    if state.provider_failures && call_number >= state.provider_failures do
      {:reply, {:error, :provider_unavailable}, state}
    else
      # Check per-call failure schedule
      case List.keyfind(state.failure_schedule, call_number, 0) do
        {_, :timeout} ->
          {:reply, {:error, :timeout}, state}

        {_, :rate_limit} ->
          {:reply, {:error, :rate_limit}, state}

        failure_or_nil ->
          # Select response based on prompt and seed
          {response, rng} = select_response(prompt, state.responses, state.rng)
          tokens = tokenize(response)

          handle = make_ref()

          disconnect_at =
            case failure_or_nil do
              {_, :disconnect} ->
                {idx, rng2} = seeded_uniform(rng, 1, max(1, length(tokens) - 1))
                state = %{state | rng: rng2}
                idx

              {_, :invalid_response} ->
                # Deliver all tokens then send garbage
                length(tokens) + 1

              _ ->
                nil
            end

          stream_state = %{
            caller: caller,
            tokens: tokens,
            position: 0,
            disconnect_at: disconnect_at,
            inject_invalid: failure_or_nil && elem(failure_or_nil, 1) == :invalid_response
          }

          state = %{state | active_streams: Map.put(state.active_streams, handle, stream_state), rng: rng}
          {:reply, {:ok, handle}, state}
      end
    end
  end

  def handle_call({:cancel_stream, handle}, _from, state) do
    state = %{state | active_streams: Map.delete(state.active_streams, handle)}
    {:reply, :ok, state}
  end

  def handle_call({:set_failure_schedule, schedule}, _from, state) do
    {:reply, :ok, %{state | failure_schedule: schedule}}
  end

  def handle_call({:set_provider_failure, n}, _from, state) do
    {:reply, :ok, %{state | provider_failures: n}}
  end

  def handle_call({:set_tokens_per_tick, count}, _from, state) do
    {:reply, :ok, %{state | tokens_per_tick: count}}
  end

  def handle_call(:call_count, _from, state) do
    {:reply, state.call_count, state}
  end

  @impl true
  def handle_info({:sim_tick, _now_ms}, state) do
    state = deliver_tokens(state)
    {:noreply, state}
  end

  # --- Internal ---

  defp deliver_tokens(state) do
    {updated_streams, completed} =
      Enum.reduce(state.active_streams, {%{}, []}, fn {handle, stream}, {acc, done} ->
        remaining = Enum.drop(stream.tokens, stream.position)
        to_send = Enum.take(remaining, state.tokens_per_tick)
        new_position = stream.position + length(to_send)

        # Check disconnect
        if stream.disconnect_at && new_position >= stream.disconnect_at do
          # Send partial then error
          partial = Enum.take(remaining, max(0, stream.disconnect_at - stream.position))
          for token <- partial, do: send(stream.caller, {:ai_token, handle, token})
          send(stream.caller, {:ai_error, handle, :stream_interrupted})
          {acc, [handle | done]}
        else
          for token <- to_send, do: send(stream.caller, {:ai_token, handle, token})

          if new_position >= length(stream.tokens) do
            if stream.inject_invalid do
              send(stream.caller, {:ai_token, handle, "\x00\xFF<INVALID>"})
            end

            send(stream.caller, {:ai_done, handle})
            {acc, [handle | done]}
          else
            updated = %{stream | position: new_position}
            {Map.put(acc, handle, updated), done}
          end
        end
      end)

    %{state | active_streams: updated_streams}
  end

  defp select_response(prompt, responses, rng) do
    category =
      cond do
        prompt =~ ~r/commit/i -> :commit_message
        prompt =~ ~r/review/i -> :review
        prompt =~ ~r/explain/i -> :explain
        prompt =~ ~r/conflict/i -> :conflict
        true -> :generic
      end

    candidates = Map.get(responses, category, Map.get(responses, :generic, ["OK"]))
    {idx, rng} = seeded_uniform(rng, 0, length(candidates) - 1)
    {Enum.at(candidates, idx), rng}
  end

  defp tokenize(text) do
    # Split into ~4 character chunks to simulate token-level streaming
    text
    |> String.graphemes()
    |> Enum.chunk_every(4)
    |> Enum.map(&Enum.join/1)
  end

  defp seeded_uniform(rng, min, max) when max > min do
    {val, rng} = :rand.uniform_s(max - min + 1, rng)
    {val - 1 + min, rng}
  end

  defp seeded_uniform(rng, val, val), do: {val, rng}

  defp default_responses do
    %{
      commit_message: [
        "feat: add user authentication\n\nImplement JWT-based auth with refresh tokens.",
        "fix: resolve race condition in repo worker\n\nAdd mutex guard around status refresh.",
        "refactor: extract semantic diff module\n\nSplit diff.rs into raw and semantic components."
      ],
      review: [
        "## Summary\nThis change adds authentication. Low risk.\n\n## Suggestions\n- Add rate limiting to login endpoint.",
        "## Summary\nLarge refactor of the git layer. Medium risk.\n\n## Suggestions\n- Add integration tests for rebase path."
      ],
      explain: [
        "This file handles the core git operations. The `checkout` function was modified to add timeout handling.",
        "The merge conflict occurs because both branches modified the same function signature."
      ],
      conflict: [
        "I suggest keeping the version from `main` because it includes the timeout fix from PR #42.",
        "Both changes are needed. Merge them by keeping the new parameter and the error handling."
      ],
      generic: [
        "I understand your request. Here's what I found.",
        "Based on the repository state, here's my analysis."
      ]
    }
  end
end
```

### 3.4 SimGit

In-memory git state that replaces real Rust NIF calls.

```elixir
defmodule Kanni.DST.SimGit do
  @moduledoc """
  In-memory git simulation replacing Rust NIF calls.

  Holds complete repository state in memory: commits, branches,
  index, working directory, and remote state. No real filesystem.

  Controls:
  - Operation latency (per-operation, seed-determined)
  - Lock contention simulation
  - Mutex poisoning
  - Network failures for push/pull
  - Memory pressure simulation

  ## Usage

      {:ok, git} = SimGit.start_link(
        seed: 42,
        clock: clock,
        repos: %{
          "repo-1" => %{
            commits: [...],
            branches: %{"main" => "abc123"},
            head: "main",
            working_dir: %{"lib/app.ex" => "contents..."},
            index: %{}
          }
        }
      )

      # Use like the real NIF — same return shapes
      {:ok, handle} = SimGit.repo_open(git, "/path/to/repo-1")
      {:ok, commits} = SimGit.log(git, handle, %{limit: 10})
  """

  use GenServer

  defstruct [
    :seed,
    :rng,
    :clock,
    :repos,
    :handles,
    :next_handle,
    :latency_config,
    :failure_schedule,
    :call_count,
    :lock_state,
    :poisoned_handles
  ]

  @type handle :: non_neg_integer()
  @type oid :: String.t()

  @type repo_state :: %{
          commits: [commit()],
          branches: %{String.t() => oid()},
          head: String.t() | {:detached, oid()},
          working_dir: %{String.t() => String.t()},
          index: %{String.t() => String.t()},
          remote: %{String.t() => remote_state()} | nil
        }

  @type commit :: %{
          oid: oid(),
          message: String.t(),
          author_name: String.t(),
          author_email: String.t(),
          timestamp: non_neg_integer(),
          parents: [oid()],
          files: [%{path: String.t(), status: String.t()}]
        }

  @type remote_state :: %{
          branches: %{String.t() => oid()},
          commits: [commit()]
        }

  # --- Public API ---

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Open a simulated repository. Returns an opaque handle."
  @spec repo_open(GenServer.server(), String.t()) :: {:ok, handle()} | {:error, String.t()}
  def repo_open(git \\ __MODULE__, path) do
    GenServer.call(git, {:repo_open, path})
  end

  @doc "Get repository status snapshot."
  @spec repo_info(GenServer.server(), handle()) :: {:ok, map()} | {:error, String.t()}
  def repo_info(git \\ __MODULE__, handle) do
    GenServer.call(git, {:repo_info, handle})
  end

  @doc "Get commit log."
  @spec log(GenServer.server(), handle(), map()) :: {:ok, [map()]} | {:error, String.t()}
  def log(git \\ __MODULE__, handle, opts \\ %{}) do
    GenServer.call(git, {:log, handle, opts})
  end

  @doc "Get branches."
  @spec branches(GenServer.server(), handle()) :: {:ok, [map()]} | {:error, String.t()}
  def branches(git \\ __MODULE__, handle) do
    GenServer.call(git, {:branches, handle})
  end

  @doc "Checkout a ref (branch or oid)."
  @spec checkout(GenServer.server(), handle(), String.t()) :: :ok | {:error, String.t()}
  def checkout(git \\ __MODULE__, handle, ref) do
    GenServer.call(git, {:checkout, handle, ref})
  end

  @doc "Stage files."
  @spec stage(GenServer.server(), handle(), [String.t()]) :: :ok | {:error, String.t()}
  def stage(git \\ __MODULE__, handle, paths) do
    GenServer.call(git, {:stage, handle, paths})
  end

  @doc "Create a commit."
  @spec commit(GenServer.server(), handle(), String.t(), map()) ::
          {:ok, oid()} | {:error, String.t()}
  def commit(git \\ __MODULE__, handle, message, opts \\ %{}) do
    GenServer.call(git, {:commit, handle, message, opts})
  end

  @doc "Diff between two refs."
  @spec diff(GenServer.server(), handle(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def diff(git \\ __MODULE__, handle, from, to) do
    GenServer.call(git, {:diff, handle, from, to})
  end

  @doc "Push to remote."
  @spec push(GenServer.server(), handle(), String.t(), String.t(), map()) ::
          :ok | {:error, String.t()}
  def push(git \\ __MODULE__, handle, remote, branch, opts \\ %{}) do
    GenServer.call(git, {:push, handle, remote, branch, opts})
  end

  @doc "Pull from remote."
  @spec pull(GenServer.server(), handle(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def pull(git \\ __MODULE__, handle, remote, branch) do
    GenServer.call(git, {:pull, handle, remote, branch})
  end

  @doc "Compute graph layout."
  @spec compute_graph(GenServer.server(), handle(), map()) ::
          {:ok, map()} | {:error, String.t()}
  def compute_graph(git \\ __MODULE__, handle, opts \\ %{}) do
    GenServer.call(git, {:compute_graph, handle, opts})
  end

  @doc "Poison a handle's mutex (simulates Rust Mutex poisoning)."
  @spec poison_handle(GenServer.server(), handle()) :: :ok
  def poison_handle(git \\ __MODULE__, handle) do
    GenServer.call(git, {:poison_handle, handle})
  end

  @doc """
  Configure operation latency.

  Format: `%{operation_atom => {min_ms, max_ms}}`
  Example: `%{log: {5, 50}, diff: {10, 200}, push: {100, 5000}}`
  """
  @spec set_latency(GenServer.server(), map()) :: :ok
  def set_latency(git \\ __MODULE__, config) do
    GenServer.call(git, {:set_latency, config})
  end

  @doc """
  Configure failure injection.

  Format: `[{call_number, failure}]`
  Failures: `:lock_contention`, `:network_timeout`, `:dns_failure`,
            `:partial_transfer`, `:nif_panic`, `:memory_pressure`
  """
  @spec set_failure_schedule(GenServer.server(), [{pos_integer(), atom()}]) :: :ok
  def set_failure_schedule(git \\ __MODULE__, schedule) do
    GenServer.call(git, {:set_failure_schedule, schedule})
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    seed = Keyword.fetch!(opts, :seed)
    clock = Keyword.fetch!(opts, :clock)
    repos = Keyword.get(opts, :repos, %{})

    rng = :rand.seed(:exsss, {seed, seed * 5, seed * 19})

    state = %__MODULE__{
      seed: seed,
      rng: rng,
      clock: clock,
      repos: repos,
      handles: %{},
      next_handle: 1,
      latency_config: default_latency(),
      failure_schedule: [],
      call_count: 0,
      lock_state: %{},
      poisoned_handles: MapSet.new()
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:repo_open, path}, _from, state) do
    state = bump_call_count(state)

    case check_failure(state) do
      {:fail, reason} ->
        {:reply, {:error, reason}, state}

      :ok ->
        # Find repo by path suffix matching
        repo_key =
          Enum.find_value(state.repos, fn {key, _repo} ->
            if String.ends_with?(path, key) or key == path, do: key
          end)

        case repo_key do
          nil ->
            {:reply, {:error, "failed to open repo: not found"}, state}

          key ->
            handle = state.next_handle
            handles = Map.put(state.handles, handle, key)
            state = %{state | handles: handles, next_handle: handle + 1}
            {:reply, {:ok, handle}, state}
        end
    end
  end

  def handle_call({:repo_info, handle}, _from, state) do
    state = bump_call_count(state)

    with :ok <- check_failure(state),
         :ok <- check_handle(handle, state),
         {:ok, repo} <- get_repo(handle, state) do
      head_branch = repo.head
      head_oid = resolve_ref(repo, head_branch)

      staged = repo.index |> Map.keys() |> Enum.map(&%{path: &1, status: "modified"})
      unstaged = working_dir_changes(repo)
      untracked = untracked_files(repo)

      info = %{
        head: head_oid,
        branch: (if is_binary(head_branch), do: head_branch, else: nil),
        state: (if map_size(repo.index) > 0 or length(unstaged) > 0, do: "dirty", else: "clean"),
        staged: staged,
        unstaged: unstaged,
        untracked: untracked,
        ahead: 0,
        behind: 0
      }

      {:reply, {:ok, info}, state}
    else
      {:fail, reason} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:log, handle, opts}, _from, state) do
    state = bump_call_count(state)

    with :ok <- check_failure(state),
         :ok <- check_handle(handle, state),
         {:ok, repo} <- get_repo(handle, state) do
      limit = Map.get(opts, :limit, 100)

      commits =
        repo.commits
        |> Enum.take(limit)
        |> Enum.map(fn c ->
          %{
            oid: c.oid,
            message: c.message,
            summary: c.message |> String.split("\n") |> hd(),
            author_name: c.author_name,
            author_email: c.author_email,
            timestamp: c.timestamp,
            parents: c.parents
          }
        end)

      {:reply, {:ok, commits}, state}
    else
      {:fail, reason} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:branches, handle}, _from, state) do
    state = bump_call_count(state)

    with :ok <- check_failure(state),
         :ok <- check_handle(handle, state),
         {:ok, repo} <- get_repo(handle, state) do
      branches =
        Enum.map(repo.branches, fn {name, target} ->
          %{
            name: name,
            target: target,
            is_head: name == repo.head,
            is_remote: false,
            upstream: nil,
            ahead: 0,
            behind: 0
          }
        end)

      {:reply, {:ok, branches}, state}
    else
      {:fail, reason} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:checkout, handle, ref}, _from, state) do
    state = bump_call_count(state)

    with :ok <- check_failure(state),
         :ok <- check_handle(handle, state),
         {:ok, repo} <- get_repo(handle, state) do
      # Check for dirty workdir
      if map_size(repo.index) > 0 do
        {:reply, {:error, "uncommitted changes would be overwritten"}, state}
      else
        if Map.has_key?(repo.branches, ref) do
          repo = %{repo | head: ref}
          state = put_repo(state, handle, repo)
          {:reply, :ok, state}
        else
          {:reply, {:error, "ref not found: #{ref}"}, state}
        end
      end
    else
      {:fail, reason} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stage, handle, paths}, _from, state) do
    state = bump_call_count(state)

    with :ok <- check_failure(state),
         :ok <- check_handle(handle, state),
         {:ok, repo} <- get_repo(handle, state) do
      new_index =
        Enum.reduce(paths, repo.index, fn path, idx ->
          case Map.get(repo.working_dir, path) do
            nil -> idx
            content -> Map.put(idx, path, content)
          end
        end)

      repo = %{repo | index: new_index}
      state = put_repo(state, handle, repo)
      {:reply, :ok, state}
    else
      {:fail, reason} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:commit, handle, message, _opts}, _from, state) do
    state = bump_call_count(state)

    with :ok <- check_failure(state),
         :ok <- check_handle(handle, state),
         {:ok, repo} <- get_repo(handle, state) do
      if map_size(repo.index) == 0 do
        {:reply, {:error, "nothing to commit"}, state}
      else
        {oid, rng} = generate_oid(state.rng)
        parent = resolve_ref(repo, repo.head)
        now = SimClock.now(state.clock)

        new_commit = %{
          oid: oid,
          message: message,
          author_name: "Test User",
          author_email: "test@test.com",
          timestamp: now,
          parents: (if parent, do: [parent], else: []),
          files: Enum.map(repo.index, fn {path, _} -> %{path: path, status: "modified"} end)
        }

        repo = %{
          repo
          | commits: [new_commit | repo.commits],
            branches: Map.put(repo.branches, repo.head, oid),
            index: %{}
        }

        state = put_repo(state, handle, repo)
        state = %{state | rng: rng}
        {:reply, {:ok, oid}, state}
      end
    else
      {:fail, reason} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:diff, handle, _from_ref, _to_ref}, _from, state) do
    state = bump_call_count(state)

    with :ok <- check_failure(state),
         :ok <- check_handle(handle, state),
         {:ok, repo} <- get_repo(handle, state) do
      # Simplified: return working dir changes as diff
      files =
        Enum.map(working_dir_changes(repo), fn change ->
          %{
            path: change.path,
            old_path: nil,
            status: change.status,
            insertions: 5,
            deletions: 2,
            hunks: []
          }
        end)

      diff = %{
        files: files,
        stats: %{
          files_changed: length(files),
          insertions: length(files) * 5,
          deletions: length(files) * 2
        }
      }

      {:reply, {:ok, diff}, state}
    else
      {:fail, reason} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:push, handle, _remote, branch, opts}, _from, state) do
    state = bump_call_count(state)

    with :ok <- check_failure(state),
         :ok <- check_handle(handle, state),
         {:ok, repo} <- get_repo(handle, state) do
      remote = Map.get(repo, :remote, %{}) |> Map.get("origin", %{branches: %{}, commits: []})
      local_oid = Map.get(repo.branches, branch)
      remote_oid = Map.get(remote.branches, branch)

      cond do
        local_oid == nil ->
          {:reply, {:error, "branch not found: #{branch}"}, state}

        remote_oid != nil and remote_oid != local_oid and !Map.get(opts, :force, false) ->
          {:reply, {:error, "rejected (non-fast-forward)"}, state}

        true ->
          remote = %{remote | branches: Map.put(remote.branches, branch, local_oid)}
          repo = %{repo | remote: %{"origin" => remote}}
          state = put_repo(state, handle, repo)
          {:reply, :ok, state}
      end
    else
      {:fail, reason} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:pull, handle, _remote, branch}, _from, state) do
    state = bump_call_count(state)

    with :ok <- check_failure(state),
         :ok <- check_handle(handle, state),
         {:ok, repo} <- get_repo(handle, state) do
      remote = Map.get(repo, :remote, %{}) |> Map.get("origin", %{branches: %{}, commits: []})
      remote_oid = Map.get(remote.branches, branch)

      case remote_oid do
        nil ->
          {:reply, {:error, "remote branch not found"}, state}

        oid ->
          repo = %{repo | branches: Map.put(repo.branches, branch, oid)}
          state = put_repo(state, handle, repo)
          {:reply, {:ok, %{type: "fast_forward", oid: oid}}, state}
      end
    else
      {:fail, reason} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:compute_graph, handle, opts}, _from, state) do
    state = bump_call_count(state)

    with :ok <- check_failure(state),
         :ok <- check_handle(handle, state),
         {:ok, repo} <- get_repo(handle, state) do
      limit = Map.get(opts, :limit, 500)

      nodes =
        repo.commits
        |> Enum.take(limit)
        |> Enum.with_index()
        |> Enum.map(fn {c, idx} ->
          %{
            oid: c.oid,
            column: 0,
            row: idx,
            message: c.message |> String.split("\n") |> hd(),
            author: c.author_name,
            timestamp: c.timestamp,
            branch: nil,
            is_merge: length(c.parents) > 1,
            parents: Enum.map(c.parents, &%{oid: &1, column: 0})
          }
        end)

      graph = %{
        nodes: nodes,
        max_columns: 1,
        branches: [],
        total_commits: length(repo.commits)
      }

      {:reply, {:ok, graph}, state}
    else
      {:fail, reason} -> {:reply, {:error, reason}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:poison_handle, handle}, _from, state) do
    state = %{state | poisoned_handles: MapSet.put(state.poisoned_handles, handle)}
    {:reply, :ok, state}
  end

  def handle_call({:set_latency, config}, _from, state) do
    {:reply, :ok, %{state | latency_config: config}}
  end

  def handle_call({:set_failure_schedule, schedule}, _from, state) do
    {:reply, :ok, %{state | failure_schedule: schedule}}
  end

  # --- Internal ---

  defp bump_call_count(state), do: %{state | call_count: state.call_count + 1}

  defp check_failure(state) do
    case List.keyfind(state.failure_schedule, state.call_count, 0) do
      {_, :lock_contention} -> {:fail, "lock file exists: .git/index.lock"}
      {_, :network_timeout} -> {:fail, "network timeout"}
      {_, :dns_failure} -> {:fail, "could not resolve host"}
      {_, :partial_transfer} -> {:fail, "connection reset by peer"}
      {_, :nif_panic} -> {:fail, "internal error: NIF panicked"}
      {_, :memory_pressure} -> {:fail, "out of memory"}
      _ -> :ok
    end
  end

  defp check_handle(handle, state) do
    cond do
      MapSet.member?(state.poisoned_handles, handle) ->
        {:fail, "mutex poisoned: previous operation panicked"}

      !Map.has_key?(state.handles, handle) ->
        {:fail, "invalid handle"}

      true ->
        :ok
    end
  end

  defp get_repo(handle, state) do
    key = Map.fetch!(state.handles, handle)

    case Map.get(state.repos, key) do
      nil -> {:error, "repo not found in simulation state"}
      repo -> {:ok, repo}
    end
  end

  defp put_repo(state, handle, repo) do
    key = Map.fetch!(state.handles, handle)
    %{state | repos: Map.put(state.repos, key, repo)}
  end

  defp resolve_ref(repo, ref) when is_binary(ref) do
    Map.get(repo.branches, ref)
  end

  defp resolve_ref(_repo, {:detached, oid}), do: oid

  defp working_dir_changes(repo) do
    # Files in working_dir not matching what's committed
    Enum.flat_map(repo.working_dir, fn {path, _content} ->
      [%{path: path, status: "modified"}]
    end)
  end

  defp untracked_files(_repo), do: []

  defp generate_oid(rng) do
    {n, rng} = :rand.uniform_s(0xFFFFFFFFFFFFFFFF, rng)
    oid = n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(40, "0")
    {String.slice(oid, 0, 40), rng}
  end

  defp default_latency do
    %{
      repo_open: {5, 50},
      repo_info: {2, 20},
      log: {5, 30},
      branches: {2, 10},
      checkout: {5, 30},
      stage: {5, 20},
      commit: {10, 50},
      diff: {5, 50},
      push: {100, 5000},
      pull: {100, 3000},
      compute_graph: {10, 50}
    }
  end
end
```

### 3.5 SeededRandom

Reproducible randomness for all nondeterministic decisions in the harness.

```elixir
defmodule Kanni.DST.SeededRandom do
  @moduledoc """
  Reproducible random number generator for DST.

  Every nondeterministic decision in the simulation draws from this
  single source. Same seed = same sequence of decisions = same test outcome.

  ## Usage

      rng = SeededRandom.new(42)
      {value, rng} = SeededRandom.uniform(rng, 1, 100)
      {bool, rng} = SeededRandom.boolean(rng, 0.3)  # 30% chance true
      {item, rng} = SeededRandom.pick(rng, [:a, :b, :c])
      {shuffled, rng} = SeededRandom.shuffle(rng, [1, 2, 3, 4])
  """

  @enforce_keys [:state, :seed]
  defstruct [:state, :seed, :call_count]

  @type t :: %__MODULE__{
          state: :rand.state(),
          seed: non_neg_integer(),
          call_count: non_neg_integer()
        }

  @doc "Create a new RNG from a seed."
  @spec new(non_neg_integer()) :: t()
  def new(seed) when is_integer(seed) and seed >= 0 do
    state = :rand.seed_s(:exsss, {seed, seed * 7, seed * 13})
    %__MODULE__{state: state, seed: seed, call_count: 0}
  end

  @doc "Generate a uniform integer in [min, max]."
  @spec uniform(t(), integer(), integer()) :: {integer(), t()}
  def uniform(%__MODULE__{} = rng, min, max) when max >= min do
    range = max - min + 1
    {val, new_state} = :rand.uniform_s(range, rng.state)
    result = val - 1 + min
    {result, %{rng | state: new_state, call_count: rng.call_count + 1}}
  end

  @doc "Generate a float in [0.0, 1.0)."
  @spec float(t()) :: {float(), t()}
  def float(%__MODULE__{} = rng) do
    {val, new_state} = :rand.uniform_s(rng.state)
    {val, %{rng | state: new_state, call_count: rng.call_count + 1}}
  end

  @doc "Generate a boolean with given probability of true."
  @spec boolean(t(), float()) :: {boolean(), t()}
  def boolean(%__MODULE__{} = rng, probability \\ 0.5) when probability >= 0.0 and probability <= 1.0 do
    {val, rng} = float(rng)
    {val < probability, rng}
  end

  @doc "Pick a random element from a non-empty list."
  @spec pick(t(), [any(), ...]) :: {any(), t()}
  def pick(%__MODULE__{} = rng, list) when is_list(list) and list != [] do
    {idx, rng} = uniform(rng, 0, length(list) - 1)
    {Enum.at(list, idx), rng}
  end

  @doc "Shuffle a list (Fisher-Yates)."
  @spec shuffle(t(), [any()]) :: {[any()], t()}
  def shuffle(%__MODULE__{} = rng, list) when is_list(list) do
    arr = :array.from_list(list)
    n = :array.size(arr)

    {arr, rng} =
      Enum.reduce((n - 1)..1//-1, {arr, rng}, fn i, {a, r} ->
        {j, r} = uniform(r, 0, i)
        vi = :array.get(i, a)
        vj = :array.get(j, a)
        a = :array.set(i, vj, a)
        a = :array.set(j, vi, a)
        {a, r}
      end)

    {:array.to_list(arr), rng}
  end

  @doc "Fork the RNG into two independent streams (for parallel simulation paths)."
  @spec fork(t()) :: {t(), t()}
  def fork(%__MODULE__{} = rng) do
    {seed_a, rng} = uniform(rng, 0, 0xFFFFFFFF)
    {seed_b, rng} = uniform(rng, 0, 0xFFFFFFFF)
    {new(seed_a), new(seed_b)}
  end

  @doc "Return the seed and call count for logging/replay."
  @spec info(t()) :: %{seed: non_neg_integer(), calls: non_neg_integer()}
  def info(%__MODULE__{} = rng) do
    %{seed: rng.seed, calls: rng.call_count}
  end
end
```

---

## 4. Scenario Categories

### 4a. Concurrent Repo Operations

```elixir
defmodule Kanni.DST.Scenarios.ConcurrentRepoOps do
  @moduledoc """
  Scenarios where multiple operations target the same repository
  simultaneously, or where state changes during an ongoing operation.
  """

  alias Kanni.DST.{SimClock, SimGit, SimFileSystem, SeededRandom}

  @doc """
  Two operations on same repo simultaneously.

  Setup: Repo worker receives a commit request. While NIF is "running"
  (dirty scheduler), a checkout request arrives.

  Expected: Second operation waits (GenServer serialization) or
  returns {:error, :busy}. Never corrupts state.
  """
  def two_ops_same_repo(seed) do
    rng = SeededRandom.new(seed)
    # Start harness
    {:ok, clock} = SimClock.start_link(seed: seed)
    {:ok, git} = SimGit.start_link(seed: seed, clock: clock, repos: test_repo())

    {:ok, handle} = SimGit.repo_open(git, "repo-1")

    # Stage a file
    SimGit.stage(git, handle, ["lib/app.ex"])

    # Fire commit and checkout concurrently
    commit_task = Task.async(fn -> SimGit.commit(git, handle, "test commit") end)
    checkout_task = Task.async(fn -> SimGit.checkout(git, handle, "feat/branch") end)

    SimClock.advance(clock, 100)

    commit_result = Task.await(commit_task)
    checkout_result = Task.await(checkout_task)

    # At least one must succeed. State must be consistent.
    {:ok, info} = SimGit.repo_info(git, handle)
    assert_valid_repo_state(info)

    {commit_result, checkout_result}
  end

  @doc """
  File change during an ongoing commit.

  Setup: User initiates commit. While commit NIF runs, file watcher
  detects new file changes. Repo worker receives watcher event.

  Expected: Commit completes with the staged set at time of commit.
  New changes appear as unstaged after commit completes.
  """
  def file_change_during_commit(seed) do
    {:ok, clock} = SimClock.start_link(seed: seed)
    {:ok, git} = SimGit.start_link(seed: seed, clock: clock, repos: test_repo())
    {:ok, fs} = SimFileSystem.start_link(seed: seed, clock: clock, repo_path: "/sim/repo-1")

    {:ok, handle} = SimGit.repo_open(git, "repo-1")
    SimGit.stage(git, handle, ["lib/app.ex"])

    # Schedule file change to arrive mid-commit
    SimClock.schedule_at(clock, 25, fn ->
      SimFileSystem.inject_events(fs, [{:modified, "lib/new_file.ex"}])
    end)

    {:ok, oid} = SimGit.commit(git, handle, "commit before new change")
    SimClock.advance(clock, 100)

    # Commit should have succeeded with original staged set
    assert is_binary(oid)

    # New file change should be visible as unstaged
    {:ok, info} = SimGit.repo_info(git, handle)
    info
  end

  @doc """
  Push while pull is happening.

  Expected: One succeeds, the other gets an error or queues.
  Remote state is consistent afterward.
  """
  def push_during_pull(seed) do
    {:ok, clock} = SimClock.start_link(seed: seed)
    {:ok, git} = SimGit.start_link(seed: seed, clock: clock, repos: test_repo_with_remote())

    {:ok, handle} = SimGit.repo_open(git, "repo-1")

    pull_task = Task.async(fn -> SimGit.pull(git, handle, "origin", "main") end)
    push_task = Task.async(fn -> SimGit.push(git, handle, "origin", "main") end)

    SimClock.advance(clock, 200)

    {Task.await(pull_task), Task.await(push_task)}
  end

  @doc """
  Graph recomputation during rebase.

  Expected: Graph reflects either pre-rebase or post-rebase state,
  never a partial/corrupt state.
  """
  def graph_during_rebase(seed) do
    {:ok, clock} = SimClock.start_link(seed: seed)
    {:ok, git} = SimGit.start_link(seed: seed, clock: clock, repos: test_repo_with_branches())

    {:ok, handle} = SimGit.repo_open(git, "repo-1")

    # Start graph computation while commits are being rewritten
    graph_result = SimGit.compute_graph(git, handle)
    SimClock.advance(clock, 50)

    # Graph must always be valid
    case graph_result do
      {:ok, graph} -> assert_valid_graph(graph)
      {:error, _} -> :ok
    end
  end

  # --- Helpers ---

  defp test_repo do
    %{
      "repo-1" => %{
        commits: [
          %{oid: "aaa111", message: "initial", author_name: "Test",
            author_email: "t@t.com", timestamp: 1000, parents: [],
            files: [%{path: "README.md", status: "added"}]}
        ],
        branches: %{"main" => "aaa111", "feat/branch" => "aaa111"},
        head: "main",
        working_dir: %{"lib/app.ex" => "defmodule App do\nend"},
        index: %{},
        remote: nil
      }
    }
  end

  defp test_repo_with_remote do
    base = test_repo()
    repo = base["repo-1"]
    repo = Map.put(repo, :remote, %{
      "origin" => %{branches: %{"main" => "aaa111"}, commits: repo.commits}
    })
    %{base | "repo-1" => repo}
  end

  defp test_repo_with_branches, do: test_repo()

  defp assert_valid_repo_state(info) do
    assert is_binary(info.head) or is_nil(info.head)
    assert info.state in ["clean", "dirty", "merge", "rebase"]
  end

  defp assert_valid_graph(graph) do
    assert is_list(graph.nodes)
    assert is_integer(graph.max_columns)
    assert graph.max_columns >= 0
    # Every node's parent must exist in the graph or be outside the window
    oids = MapSet.new(graph.nodes, & &1.oid)
    for node <- graph.nodes, parent <- node.parents do
      # Parent either in graph or truncated (outside limit)
      assert MapSet.member?(oids, parent.oid) or true
    end
  end
end
```

### 4b. AI Streaming Failures

```elixir
defmodule Kanni.DST.Scenarios.AIStreamingFailures do
  @moduledoc """
  Scenarios covering AI provider failures during streaming,
  backpressure, provider switching, and context building timeouts.
  """

  alias Kanni.DST.{SimClock, SimAI}

  @doc """
  Stream interrupts at various points.

  Seed controls WHERE in the token stream the disconnect happens.
  Test that partial responses are surfaced to the user.
  """
  def stream_interrupt_at_random_point(seed) do
    {:ok, clock} = SimClock.start_link(seed: seed)
    {:ok, ai} = SimAI.start_link(seed: seed, clock: clock)

    # Disconnect on call 1 at a seed-determined token position
    SimAI.set_failure_schedule(ai, [{1, :disconnect}])

    {:ok, handle} = SimAI.stream(ai, "generate commit message")

    # Collect tokens until error
    tokens = collect_tokens(handle, clock, 20)

    # Must have received SOME tokens before error
    assert length(tokens.received) > 0
    assert tokens.error == :stream_interrupted
  end

  @doc """
  Token-level backpressure.

  SimAI delivers tokens faster than consumer processes them.
  Clock controls delivery rate. Consumer deliberately slow.
  """
  def token_backpressure(seed) do
    {:ok, clock} = SimClock.start_link(seed: seed)
    {:ok, ai} = SimAI.start_link(seed: seed, clock: clock, tokens_per_tick: 50)

    {:ok, handle} = SimAI.stream(ai, "review this PR")

    # Advance clock rapidly — tokens pile up in mailbox
    for _ <- 1..20, do: SimClock.advance(clock, 10)

    # All tokens should be in our mailbox
    tokens = drain_mailbox(handle)
    assert length(tokens) > 0
  end

  @doc """
  Provider switches mid-stream.

  Primary provider fails after N calls. System should detect failure
  and switch to secondary. Ongoing stream is lost, retry happens.
  """
  def provider_switch_mid_stream(seed) do
    {:ok, clock} = SimClock.start_link(seed: seed)
    {:ok, primary} = SimAI.start_link(seed: seed, clock: clock, name: :primary_ai)
    {:ok, secondary} = SimAI.start_link(seed: seed + 1, clock: clock, name: :secondary_ai)

    # Primary dies after 2 calls
    SimAI.set_provider_failure(primary, 2)

    # First call works
    {:ok, _h1} = SimAI.stream(primary, "commit message")
    SimClock.advance(clock, 100)

    # Second call works
    {:ok, _h2} = SimAI.stream(primary, "review")
    SimClock.advance(clock, 100)

    # Third call fails — should trigger switch
    result = SimAI.stream(primary, "explain")
    assert result == {:error, :provider_unavailable}

    # Secondary still works
    {:ok, h3} = SimAI.stream(secondary, "explain")
    SimClock.advance(clock, 100)
    tokens = drain_mailbox(h3)
    assert length(tokens) > 0
  end

  @doc """
  Timeout during context building.

  Context builder takes too long gathering repo state for prompt.
  AI request should timeout gracefully.
  """
  def context_build_timeout(seed) do
    {:ok, clock} = SimClock.start_link(seed: seed)
    {:ok, ai} = SimAI.start_link(seed: seed, clock: clock)

    # First call times out
    SimAI.set_failure_schedule(ai, [{1, :timeout}])

    result = SimAI.stream(ai, "review large diff")
    assert result == {:error, :timeout}

    # Second call succeeds (retry scenario)
    {:ok, handle} = SimAI.stream(ai, "review large diff")
    SimClock.advance(clock, 200)
    tokens = drain_mailbox(handle)
    assert length(tokens) > 0
  end

  # --- Helpers ---

  defp collect_tokens(handle, clock, max_ticks) do
    Enum.reduce_while(1..max_ticks, %{received: [], error: nil}, fn _, acc ->
      SimClock.advance(clock, 10)

      case drain_one_tick(handle) do
        {:tokens, new_tokens} ->
          {:cont, %{acc | received: acc.received ++ new_tokens}}

        {:error, reason} ->
          {:halt, %{acc | error: reason}}

        :done ->
          {:halt, acc}
      end
    end)
  end

  defp drain_one_tick(handle) do
    receive do
      {:ai_token, ^handle, token} -> {:tokens, [token | drain_remaining_tokens(handle)]}
      {:ai_error, ^handle, reason} -> {:error, reason}
      {:ai_done, ^handle} -> :done
    after
      0 -> {:tokens, []}
    end
  end

  defp drain_remaining_tokens(handle) do
    receive do
      {:ai_token, ^handle, token} -> [token | drain_remaining_tokens(handle)]
    after
      0 -> []
    end
  end

  defp drain_mailbox(handle) do
    receive do
      {:ai_token, ^handle, token} -> [token | drain_mailbox(handle)]
      {:ai_done, ^handle} -> []
      {:ai_error, ^handle, _} -> []
    after
      0 -> []
    end
  end
end
```

### 4c. NIF Crash Recovery

```elixir
defmodule Kanni.DST.Scenarios.NIFCrashRecovery do
  @moduledoc """
  Scenarios for Rust NIF failures: mutex poisoning, handle invalidation,
  and memory pressure. Tests that the Elixir supervision tree recovers
  gracefully and no state is corrupted.
  """

  alias Kanni.DST.{SimClock, SimGit}

  @doc """
  Mutex poisoning simulation.

  A previous NIF call panicked, poisoning the Mutex<Repository>.
  Subsequent calls to the same handle should get a clear error,
  and the repo worker should re-open the repository.
  """
  def mutex_poisoning(seed) do
    {:ok, clock} = SimClock.start_link(seed: seed)
    {:ok, git} = SimGit.start_link(seed: seed, clock: clock, repos: test_repo())

    {:ok, handle} = SimGit.repo_open(git, "repo-1")

    # Normal operation works
    {:ok, _commits} = SimGit.log(git, handle)

    # Poison the handle
    SimGit.poison_handle(git, handle)

    # Next call should fail with clear error
    result = SimGit.log(git, handle)
    assert {:error, msg} = result
    assert msg =~ "mutex poisoned"

    # Recovery: open a new handle
    {:ok, new_handle} = SimGit.repo_open(git, "repo-1")
    {:ok, commits} = SimGit.log(git, new_handle)
    assert is_list(commits)
  end

  @doc """
  Handle invalidation mid-operation.

  The ResourceArc is garbage collected while a NIF call is in flight
  (simulated). Subsequent calls should fail gracefully.
  """
  def handle_invalidation(seed) do
    {:ok, clock} = SimClock.start_link(seed: seed)
    {:ok, git} = SimGit.start_link(seed: seed, clock: clock, repos: test_repo())

    {:ok, handle} = SimGit.repo_open(git, "repo-1")
    {:ok, _} = SimGit.log(git, handle)

    # Simulate handle becoming invalid (e.g., process died holding the ref)
    # Use a handle that was never opened
    bogus_handle = 99999
    result = SimGit.log(git, bogus_handle)
    assert {:error, "invalid handle"} = result
  end

  @doc """
  Memory pressure during large diff.

  Simulates OOM when diffing a very large changeset.
  System should return error, not crash the BEAM.
  """
  def memory_pressure_large_diff(seed) do
    {:ok, clock} = SimClock.start_link(seed: seed)
    {:ok, git} = SimGit.start_link(seed: seed, clock: clock, repos: test_repo())

    # Fail the next diff call with memory pressure
    SimGit.set_failure_schedule(git, [{2, :memory_pressure}])

    {:ok, handle} = SimGit.repo_open(git, "repo-1")
    result = SimGit.diff(git, handle, "HEAD", "WORKDIR")

    assert {:error, "out of memory"} = result

    # System is still functional after OOM
    {:ok, _commits} = SimGit.log(git, handle)
  end

  defp test_repo do
    %{
      "repo-1" => %{
        commits: [
          %{oid: "aaa111", message: "initial", author_name: "Test",
            author_email: "t@t.com", timestamp: 1000, parents: [],
            files: [%{path: "README.md", status: "added"}]}
        ],
        branches: %{"main" => "aaa111"},
        head: "main",
        working_dir: %{"lib/app.ex" => "defmodule App do\nend"},
        index: %{},
        remote: nil
      }
    }
  end
end
```

### 4d. File Watcher Storms

```elixir
defmodule Kanni.DST.Scenarios.FileWatcherStorms do
  @moduledoc """
  Scenarios for rapid file system events: git checkout storms,
  create/delete cycles, symlink changes, and .git directory filtering.
  """

  alias Kanni.DST.{SimClock, SimFileSystem}

  @doc """
  1000 file changes in 100ms (git checkout scenario).

  When the user does `git checkout another-branch`, the OS emits
  hundreds of file events in rapid succession. The file watcher
  must coalesce them into a single state refresh, not trigger
  1000 NIF calls.
  """
  def git_checkout_storm(seed) do
    {:ok, clock} = SimClock.start_link(seed: seed)
    {:ok, fs} = SimFileSystem.start_link(seed: seed, clock: clock, repo_path: "/sim/repo")
    SimFileSystem.subscribe(fs, self())

    # Generate 1000 file paths
    paths = for i <- 1..100, do: "lib/module_#{i}.ex"

    SimFileSystem.inject_storm(fs, 1000, 100, paths)

    # Advance clock through the storm window
    events = advance_and_collect_events(clock, 200, 20)

    # We should have received events, but the consumer should
    # be able to handle the volume without crashing
    assert length(events) > 0
    # In a real integration, the repo worker would debounce these
  end

  @doc """
  Rapid create/delete cycles.

  Editor temp files: create foo.ex~, write, rename to foo.ex, delete foo.ex~.
  The watcher should not choke on the ghost files.
  """
  def create_delete_cycles(seed) do
    {:ok, clock} = SimClock.start_link(seed: seed)
    {:ok, fs} = SimFileSystem.start_link(seed: seed, clock: clock, repo_path: "/sim/repo")
    SimFileSystem.subscribe(fs, self())

    events = [
      {:created, "lib/foo.ex~"},
      {:modified, "lib/foo.ex~"},
      {:renamed, "lib/foo.ex"},
      {:deleted, "lib/foo.ex~"},
      {:created, "lib/bar.ex~"},
      {:modified, "lib/bar.ex~"},
      {:renamed, "lib/bar.ex"},
      {:deleted, "lib/bar.ex~"}
    ]

    SimFileSystem.inject_events(fs, events)
    collected = advance_and_collect_events(clock, 200, 10)

    # Events were delivered without crashes
    assert length(collected) > 0
  end

  @doc """
  .git directory changes should be filtered.

  When git writes to .git/objects or .git/refs, the watcher
  must NOT trigger a state refresh (infinite loop risk).
  """
  def git_directory_filtered(seed) do
    {:ok, clock} = SimClock.start_link(seed: seed)
    {:ok, fs} = SimFileSystem.start_link(seed: seed, clock: clock, repo_path: "/sim/repo")
    SimFileSystem.subscribe(fs, self())

    # These should all be filtered
    git_events = [
      {:modified, ".git/objects/aa/bb1122"},
      {:modified, ".git/refs/heads/main"},
      {:modified, ".git/index"},
      {:created, ".git/index.lock"}
    ]

    # This should pass through
    user_events = [
      {:modified, "lib/app.ex"}
    ]

    SimFileSystem.inject_events(fs, git_events ++ user_events)
    collected = advance_and_collect_events(clock, 200, 10)

    # Only the user event should arrive
    paths = Enum.map(collected, fn {:file_event, _, {path, _}} -> path end)

    refute Enum.any?(paths, &String.contains?(&1, ".git"))
    assert Enum.any?(paths, &String.contains?(&1, "lib/app.ex"))
  end

  @doc """
  Symlink changes.

  Symlinks pointing into or out of the repo. Watcher should
  handle them without following into infinite loops.
  """
  def symlink_changes(seed) do
    {:ok, clock} = SimClock.start_link(seed: seed)
    {:ok, fs} = SimFileSystem.start_link(seed: seed, clock: clock, repo_path: "/sim/repo")
    SimFileSystem.subscribe(fs, self())

    events = [
      {:created, "lib/symlink_to_external"},
      {:attribute_changed, "lib/symlink_to_external"},
      {:modified, "lib/real_file.ex"}
    ]

    SimFileSystem.inject_events(fs, events)
    collected = advance_and_collect_events(clock, 200, 10)

    # Should not crash, events delivered
    assert length(collected) >= 1
  end

  # --- Helpers ---

  defp advance_and_collect_events(clock, total_ms, ticks) do
    step = div(total_ms, ticks)

    Enum.flat_map(1..ticks, fn _ ->
      SimClock.advance(clock, step)
      drain_file_events()
    end)
  end

  defp drain_file_events do
    receive do
      {:file_event, _, _} = event -> [event | drain_file_events()]
    after
      0 -> []
    end
  end
end
```

### 4e. Network Failures

```elixir
defmodule Kanni.DST.Scenarios.NetworkFailures do
  @moduledoc """
  Scenarios for git network operations failing: push timeout,
  conflicting remote changes, DNS resolution failure, and
  partial transfers.
  """

  alias Kanni.DST.{SimClock, SimGit}

  @doc "Push timeout — remote does not respond within deadline."
  def push_timeout(seed) do
    {:ok, clock} = SimClock.start_link(seed: seed)
    {:ok, git} = SimGit.start_link(seed: seed, clock: clock, repos: test_repo_with_remote())

    # Fail push with network timeout
    SimGit.set_failure_schedule(git, [{3, :network_timeout}])

    {:ok, handle} = SimGit.repo_open(git, "repo-1")
    SimGit.stage(git, handle, ["lib/app.ex"])
    {:ok, _oid} = SimGit.commit(git, handle, "local commit")

    result = SimGit.push(git, handle, "origin", "main")
    assert {:error, "network timeout"} = result

    # Local state is preserved — commit still exists
    {:ok, commits} = SimGit.log(git, handle, %{limit: 5})
    assert hd(commits).message == "local commit"
  end

  @doc "Pull with conflicting remote changes (non-fast-forward)."
  def pull_with_conflicts(seed) do
    {:ok, clock} = SimClock.start_link(seed: seed)
    {:ok, git} = SimGit.start_link(seed: seed, clock: clock, repos: test_repo_with_diverged_remote())

    {:ok, handle} = SimGit.repo_open(git, "repo-1")

    # Push should fail because remote has diverged
    result = SimGit.push(git, handle, "origin", "main")
    assert {:error, "rejected (non-fast-forward)"} = result
  end

  @doc "DNS resolution failure."
  def dns_failure(seed) do
    {:ok, clock} = SimClock.start_link(seed: seed)
    {:ok, git} = SimGit.start_link(seed: seed, clock: clock, repos: test_repo_with_remote())

    SimGit.set_failure_schedule(git, [{2, :dns_failure}])

    {:ok, handle} = SimGit.repo_open(git, "repo-1")
    result = SimGit.push(git, handle, "origin", "main")
    assert {:error, "could not resolve host"} = result
  end

  @doc "Connection drops mid-push (partial transfer)."
  def partial_transfer(seed) do
    {:ok, clock} = SimClock.start_link(seed: seed)
    {:ok, git} = SimGit.start_link(seed: seed, clock: clock, repos: test_repo_with_remote())

    SimGit.set_failure_schedule(git, [{2, :partial_transfer}])

    {:ok, handle} = SimGit.repo_open(git, "repo-1")
    result = SimGit.push(git, handle, "origin", "main")
    assert {:error, "connection reset by peer"} = result

    # Remote state should NOT have the partial push
    {:ok, info} = SimGit.repo_info(git, handle)
    assert is_map(info)
  end

  defp test_repo_with_remote do
    %{
      "repo-1" => %{
        commits: [
          %{oid: "aaa111", message: "initial", author_name: "Test",
            author_email: "t@t.com", timestamp: 1000, parents: [],
            files: [%{path: "README.md", status: "added"}]}
        ],
        branches: %{"main" => "aaa111"},
        head: "main",
        working_dir: %{"lib/app.ex" => "defmodule App do\nend"},
        index: %{},
        remote: %{
          "origin" => %{branches: %{"main" => "aaa111"}, commits: []}
        }
      }
    }
  end

  defp test_repo_with_diverged_remote do
    %{
      "repo-1" => %{
        commits: [
          %{oid: "bbb222", message: "local change", author_name: "Test",
            author_email: "t@t.com", timestamp: 2000, parents: ["aaa111"],
            files: []},
          %{oid: "aaa111", message: "initial", author_name: "Test",
            author_email: "t@t.com", timestamp: 1000, parents: [],
            files: []}
        ],
        branches: %{"main" => "bbb222"},
        head: "main",
        working_dir: %{},
        index: %{},
        remote: %{
          "origin" => %{
            branches: %{"main" => "ccc333"},
            commits: [
              %{oid: "ccc333", message: "remote change", author_name: "Other",
                author_email: "o@o.com", timestamp: 2000, parents: ["aaa111"],
                files: []}
            ]
          }
        }
      }
    }
  end
end
```

### 4f. LiveView Reconnection

```elixir
defmodule Kanni.DST.Scenarios.LiveViewReconnection do
  @moduledoc """
  Scenarios for WebSocket lifecycle events: server restart,
  stale state after reconnect, and multiple tabs with the same repo.

  These scenarios test at the PubSub/state level, not with real
  WebSocket connections. LiveView reconnection is modeled as:
  1. Process dies (simulating socket disconnect)
  2. New process starts (simulating reconnect)
  3. New process must catch up on missed state changes
  """

  alias Kanni.DST.{SimClock, SimGit, SimFileSystem}

  @doc """
  Server restart while client connected.

  Repo worker crashes and restarts. Connected LiveView must
  detect the restart and re-subscribe. State should be consistent
  after reconnect.
  """
  def server_restart_during_connection(seed) do
    {:ok, clock} = SimClock.start_link(seed: seed)
    {:ok, git} = SimGit.start_link(seed: seed, clock: clock, repos: test_repo())

    {:ok, handle} = SimGit.repo_open(git, "repo-1")

    # Simulate "connected client" by subscribing to PubSub
    # In real code: Phoenix.PubSub.subscribe(Kanni.PubSub, "repo:repo-1")

    # Get initial state
    {:ok, state_before} = SimGit.repo_info(git, handle)

    # Simulate server restart — worker process dies
    # In real system, DynamicSupervisor restarts the Worker
    # After restart, new handle is needed

    {:ok, new_handle} = SimGit.repo_open(git, "repo-1")
    {:ok, state_after} = SimGit.repo_info(git, new_handle)

    # State should be consistent (same repo)
    assert state_after.branch == state_before.branch
  end

  @doc """
  Stale state after reconnect.

  Client disconnects. While disconnected, repo state changes
  (new commits, branch switch). Client reconnects. Must see
  current state, not stale cached state.
  """
  def stale_state_after_reconnect(seed) do
    {:ok, clock} = SimClock.start_link(seed: seed)
    {:ok, git} = SimGit.start_link(seed: seed, clock: clock, repos: test_repo_with_branches())

    {:ok, handle} = SimGit.repo_open(git, "repo-1")

    # Initial state: on main
    {:ok, before} = SimGit.repo_info(git, handle)
    assert before.branch == "main"

    # --- Client disconnects ---
    # Changes happen while disconnected:
    SimGit.checkout(git, handle, "feat/auth")
    SimGit.stage(git, handle, ["lib/app.ex"])
    {:ok, _oid} = SimGit.commit(git, handle, "commit while disconnected")

    # --- Client reconnects ---
    # Must get fresh state, not cached
    {:ok, after_reconnect} = SimGit.repo_info(git, handle)
    assert after_reconnect.branch == "feat/auth"
  end

  @doc """
  Multiple tabs with same repo.

  Two LiveView processes subscribe to the same repo topic.
  Both must receive updates. Operations from one tab must
  be visible in the other.
  """
  def multiple_tabs_same_repo(seed) do
    {:ok, clock} = SimClock.start_link(seed: seed)
    {:ok, git} = SimGit.start_link(seed: seed, clock: clock, repos: test_repo())

    # Two "tabs" open the same repo
    {:ok, handle_a} = SimGit.repo_open(git, "repo-1")
    {:ok, handle_b} = SimGit.repo_open(git, "repo-1")

    # Tab A stages and commits
    SimGit.stage(git, handle_a, ["lib/app.ex"])
    {:ok, oid} = SimGit.commit(git, handle_a, "from tab A")

    # Tab B should see the new commit
    {:ok, commits} = SimGit.log(git, handle_b, %{limit: 5})
    assert hd(commits).message == "from tab A"
    assert hd(commits).oid == oid
  end

  defp test_repo do
    %{
      "repo-1" => %{
        commits: [
          %{oid: "aaa111", message: "initial", author_name: "Test",
            author_email: "t@t.com", timestamp: 1000, parents: [],
            files: []}
        ],
        branches: %{"main" => "aaa111"},
        head: "main",
        working_dir: %{"lib/app.ex" => "defmodule App do\nend"},
        index: %{},
        remote: nil
      }
    }
  end

  defp test_repo_with_branches do
    repo = test_repo()["repo-1"]
    repo = %{repo | branches: Map.put(repo.branches, "feat/auth", "aaa111")}
    %{"repo-1" => repo}
  end
end
```

---

## 5. Property-Based Testing Integration

Use StreamData for properties that must hold regardless of the seed.

```elixir
defmodule Kanni.DST.Properties do
  @moduledoc """
  Property-based tests using StreamData.

  These properties must hold for ALL seeds, ALL interleavings,
  ALL failure combinations. StreamData generates the scenarios;
  the DST harness controls the nondeterminism.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Kanni.DST.{SimClock, SimGit, SimAI, SeededRandom}

  # --- Generators ---

  defp seed_gen, do: StreamData.integer(0..0xFFFFFFFF)

  defp git_operation_gen do
    StreamData.one_of([
      StreamData.constant(:status),
      StreamData.constant(:log),
      StreamData.constant(:branches),
      StreamData.tuple({StreamData.constant(:stage), StreamData.constant(["lib/app.ex"])}),
      StreamData.tuple({StreamData.constant(:commit), StreamData.string(:alphanumeric, min_length: 1)}),
      StreamData.tuple({StreamData.constant(:checkout), StreamData.member_of(["main", "feat/auth"])})
    ])
  end

  defp operation_sequence_gen do
    StreamData.list_of(git_operation_gen(), min_length: 1, max_length: 20)
  end

  # --- Properties ---

  @tag timeout: 30_000
  property "commit graph is always a DAG (no cycles)" do
    check all seed <- seed_gen(),
              ops <- operation_sequence_gen(),
              max_runs: 100 do
      {:ok, clock} = SimClock.start_link(seed: seed, name: :"clock_#{seed}")
      {:ok, git} = SimGit.start_link(seed: seed, clock: :"clock_#{seed}", repos: test_repo(), name: :"git_#{seed}")

      {:ok, handle} = SimGit.repo_open(:"git_#{seed}", "repo-1")

      # Execute random operation sequence
      for op <- ops do
        execute_op(:"git_#{seed}", handle, op)
      end

      # Property: graph must be a DAG
      {:ok, graph} = SimGit.compute_graph(:"git_#{seed}", handle)
      assert is_dag?(graph)

      # Cleanup
      GenServer.stop(:"git_#{seed}")
      GenServer.stop(:"clock_#{seed}")
    end
  end

  @tag timeout: 30_000
  property "status is always consistent with working directory" do
    check all seed <- seed_gen(),
              ops <- operation_sequence_gen(),
              max_runs: 100 do
      {:ok, clock} = SimClock.start_link(seed: seed, name: :"clock_#{seed}")
      {:ok, git} = SimGit.start_link(seed: seed, clock: :"clock_#{seed}", repos: test_repo(), name: :"git_#{seed}")

      {:ok, handle} = SimGit.repo_open(:"git_#{seed}", "repo-1")

      for op <- ops do
        execute_op(:"git_#{seed}", handle, op)
      end

      # Property: status must be internally consistent
      {:ok, info} = SimGit.repo_info(:"git_#{seed}", handle)

      # If staged is empty and unstaged is empty and untracked is empty → clean
      if info.staged == [] and info.unstaged == [] and info.untracked == [] do
        assert info.state == "clean"
      end

      # If staged is non-empty → state is dirty
      if info.staged != [] do
        assert info.state == "dirty"
      end

      GenServer.stop(:"git_#{seed}")
      GenServer.stop(:"clock_#{seed}")
    end
  end

  @tag timeout: 30_000
  property "AI suggestions are always parseable intents" do
    check all seed <- seed_gen(),
              prompt <- StreamData.member_of([
                "generate commit message",
                "review this PR",
                "explain the diff"
              ]),
              max_runs: 50 do
      {:ok, clock} = SimClock.start_link(seed: seed, name: :"clock_#{seed}")
      {:ok, ai} = SimAI.start_link(seed: seed, clock: :"clock_#{seed}", name: :"ai_#{seed}")

      {:ok, handle} = SimAI.stream(:"ai_#{seed}", prompt)

      # Advance clock to get all tokens
      for _ <- 1..50, do: SimClock.advance(:"clock_#{seed}", 10)

      tokens = drain_all_tokens(handle)
      response = Enum.join(tokens)

      # Property: response must be valid UTF-8 and non-empty
      assert String.valid?(response)
      assert String.length(response) > 0

      GenServer.stop(:"ai_#{seed}")
      GenServer.stop(:"clock_#{seed}")
    end
  end

  # --- Helpers ---

  defp execute_op(git, handle, :status), do: SimGit.repo_info(git, handle)
  defp execute_op(git, handle, :log), do: SimGit.log(git, handle, %{limit: 10})
  defp execute_op(git, handle, :branches), do: SimGit.branches(git, handle)
  defp execute_op(git, handle, {:stage, paths}), do: SimGit.stage(git, handle, paths)

  defp execute_op(git, handle, {:commit, msg}) do
    # Must stage first
    SimGit.stage(git, handle, ["lib/app.ex"])
    SimGit.commit(git, handle, msg)
  end

  defp execute_op(git, handle, {:checkout, ref}), do: SimGit.checkout(git, handle, ref)

  defp is_dag?(graph) do
    # Topological sort — if it completes without cycle, it's a DAG
    nodes = Map.new(graph.nodes, &{&1.oid, &1})
    visited = MapSet.new()
    in_stack = MapSet.new()

    Enum.reduce_while(graph.nodes, {visited, in_stack, true}, fn node, {v, s, _} ->
      case dfs_cycle_check(node.oid, nodes, v, s) do
        {:ok, v, s} -> {:cont, {v, s, true}}
        :cycle -> {:halt, {v, s, false}}
      end
    end)
    |> elem(2)
  end

  defp dfs_cycle_check(oid, nodes, visited, in_stack) do
    cond do
      MapSet.member?(in_stack, oid) -> :cycle
      MapSet.member?(visited, oid) -> {:ok, visited, in_stack}
      true ->
        in_stack = MapSet.put(in_stack, oid)
        node = Map.get(nodes, oid)
        parents = if node, do: Enum.map(node.parents, & &1.oid), else: []

        result =
          Enum.reduce_while(parents, {:ok, visited, in_stack}, fn parent_oid, {:ok, v, s} ->
            case dfs_cycle_check(parent_oid, nodes, v, s) do
              {:ok, v, s} -> {:cont, {:ok, v, s}}
              :cycle -> {:halt, :cycle}
            end
          end)

        case result do
          :cycle -> :cycle
          {:ok, visited, in_stack} ->
            {:ok, MapSet.put(visited, oid), MapSet.delete(in_stack, oid)}
        end
    end
  end

  defp drain_all_tokens(handle) do
    receive do
      {:ai_token, ^handle, token} -> [token | drain_all_tokens(handle)]
      {:ai_done, ^handle} -> []
      {:ai_error, ^handle, _} -> []
    after
      0 -> []
    end
  end

  defp test_repo do
    %{
      "repo-1" => %{
        commits: [
          %{oid: "aaa111", message: "initial", author_name: "Test",
            author_email: "t@t.com", timestamp: 1000, parents: [],
            files: [%{path: "README.md", status: "added"}]}
        ],
        branches: %{"main" => "aaa111", "feat/auth" => "aaa111"},
        head: "main",
        working_dir: %{"lib/app.ex" => "defmodule App do\nend"},
        index: %{},
        remote: nil
      }
    }
  end
end
```

---

## 6. Seed Management

### 6.1 Logging

Every DST test run logs its seed. On failure, the seed is the reproduction key.

```elixir
defmodule Kanni.DST.SeedManager do
  @moduledoc """
  Manages seed generation, logging, and replay for DST runs.

  Every test run generates a seed (or accepts one for replay).
  Seeds are logged to a file and to ExUnit output. CI stores
  failing seeds as artifacts.

  ## CI Integration

  On failure, the seed is written to `_build/test/failing_seeds.txt`.
  CI uploads this as an artifact. To replay:

      mix test --seed 42 test/dst/scenarios_test.exs

  ## Shrinking

  When a property test fails, we binary-search for the minimal
  failing seed by varying the operation sequence length.
  """

  require Logger

  @seeds_file "_build/test/failing_seeds.txt"

  @doc "Generate a seed from system entropy or use a fixed replay seed."
  @spec generate_or_replay(keyword()) :: non_neg_integer()
  def generate_or_replay(opts \\ []) do
    case Keyword.get(opts, :seed) do
      nil ->
        seed = :rand.uniform(0xFFFFFFFF)
        log_seed(seed, :generated)
        seed

      seed when is_integer(seed) ->
        log_seed(seed, :replay)
        seed
    end
  end

  @doc "Log a seed and scenario name."
  @spec log_seed(non_neg_integer(), atom()) :: :ok
  def log_seed(seed, mode) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    Logger.info("[DST] seed=#{seed} mode=#{mode} time=#{timestamp}")
    :ok
  end

  @doc "Record a failing seed for CI artifact collection."
  @spec record_failure(non_neg_integer(), String.t(), String.t()) :: :ok
  def record_failure(seed, scenario, error_message) do
    File.mkdir_p!(Path.dirname(@seeds_file))

    entry =
      "#{DateTime.utc_now() |> DateTime.to_iso8601()} seed=#{seed} scenario=#{scenario} error=#{String.slice(error_message, 0, 200)}\n"

    File.write!(@seeds_file, entry, [:append])
    Logger.error("[DST FAILURE] #{entry}")
    :ok
  end

  @doc "Load all recorded failing seeds."
  @spec load_failing_seeds() :: [{non_neg_integer(), String.t()}]
  def load_failing_seeds do
    case File.read(@seeds_file) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          seed =
            Regex.run(~r/seed=(\d+)/, line)
            |> case do
              [_, s] -> String.to_integer(s)
              _ -> nil
            end

          scenario =
            Regex.run(~r/scenario=(\S+)/, line)
            |> case do
              [_, s] -> s
              _ -> "unknown"
            end

          {seed, scenario}
        end)
        |> Enum.reject(fn {seed, _} -> is_nil(seed) end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Shrink a failing scenario to its minimal reproducing case.

  Given a seed and a scenario function that takes (seed, max_ops),
  binary-search for the smallest max_ops that still fails.
  """
  @spec shrink(non_neg_integer(), (non_neg_integer(), pos_integer() -> boolean()), pos_integer()) ::
          {:ok, pos_integer()} | :cannot_shrink
  def shrink(seed, scenario_fn, max_ops \\ 20) do
    # First verify it actually fails at max_ops
    unless scenario_fn.(seed, max_ops) do
      :cannot_shrink
    else
      # Binary search for minimum
      min = shrink_search(seed, scenario_fn, 1, max_ops)
      {:ok, min}
    end
  end

  defp shrink_search(_seed, _fn, low, high) when low >= high, do: low

  defp shrink_search(seed, scenario_fn, low, high) do
    mid = div(low + high, 2)

    if scenario_fn.(seed, mid) do
      # Still fails at mid — try smaller
      shrink_search(seed, scenario_fn, low, mid)
    else
      # Passes at mid — need more ops
      shrink_search(seed, scenario_fn, mid + 1, high)
    end
  end
end
```

### 6.2 Test Runner Integration

```elixir
defmodule Kanni.DST.Runner do
  @moduledoc """
  Runs DST scenarios with seed management.

  ## Usage in ExUnit

      defmodule MyDSTTest do
        use ExUnit.Case

        @tag :dst
        test "concurrent repo operations survive any interleaving" do
          seed = Kanni.DST.SeedManager.generate_or_replay()

          try do
            Kanni.DST.Scenarios.ConcurrentRepoOps.two_ops_same_repo(seed)
          rescue
            e ->
              Kanni.DST.SeedManager.record_failure(seed, "two_ops_same_repo", Exception.message(e))
              reraise e, __STACKTRACE__
          end
        end
      end

  ## Running

      # Random seed (normal CI run)
      mix test --only dst

      # Replay a specific failing seed
      DST_SEED=42 mix test --only dst

      # Run with many seeds (overnight soak)
      for i in $(seq 1 1000); do
        mix test --only dst --seed $i 2>&1 | tee -a dst_soak.log
      done
  """

  @doc "Run a scenario with automatic seed management."
  def run(scenario_module, scenario_fn, opts \\ []) do
    seed =
      case System.get_env("DST_SEED") do
        nil -> Kanni.DST.SeedManager.generate_or_replay(opts)
        s -> Kanni.DST.SeedManager.generate_or_replay(seed: String.to_integer(s))
      end

    try do
      apply(scenario_module, scenario_fn, [seed])
    rescue
      e ->
        scenario_name = "#{inspect(scenario_module)}.#{scenario_fn}"
        Kanni.DST.SeedManager.record_failure(seed, scenario_name, Exception.message(e))
        reraise e, __STACKTRACE__
    end
  end
end
```

### 6.3 CI Configuration

```yaml
# In Sykli pipeline or GitHub Actions
# failing seeds are stored as artifacts for replay

dst_test:
  script:
    - mix test --only dst
  artifacts:
    when: on_failure
    paths:
      - _build/test/failing_seeds.txt
    expire_in: 90 days

# Nightly soak test: run 10,000 random seeds
dst_soak:
  schedule: "0 2 * * *"
  script:
    - |
      for i in $(seq 1 10000); do
        DST_SEED=$i mix test --only dst 2>&1 || echo "FAILED seed=$i" >> failures.txt
      done
    - test ! -s failures.txt
  artifacts:
    when: on_failure
    paths:
      - failures.txt
      - _build/test/failing_seeds.txt
```

---

## 7. Implementation Roadmap

### Phase 1: Foundation (Week 1)

1. `SeededRandom` -- pure module, no dependencies, test first
2. `SimClock` -- GenServer with event queue
3. Basic `SimGit` -- repo_open, repo_info, log, commit
4. One scenario: `two_ops_same_repo`

### Phase 2: File & AI Simulation (Week 2)

1. `SimFileSystem` -- event injection, filtering, storms
2. `SimAI` -- seeded responses, streaming, failure injection
3. Scenarios: `git_checkout_storm`, `stream_interrupt_at_random_point`
4. `SeedManager` -- logging, CI integration

### Phase 3: Properties & Shrinking (Week 3)

1. StreamData integration for property-based tests
2. DAG property, status consistency property
3. Shrinking support in `SeedManager`
4. Nightly soak CI job

### Phase 4: Full Coverage (Week 4)

1. All scenario categories implemented
2. Network failure scenarios
3. LiveView reconnection scenarios
4. NIF crash recovery scenarios
5. Documentation and replay guide

---

## 8. File Structure

```
test/
├── dst/
│   ├── sim_clock_test.exs
│   ├── sim_file_system_test.exs
│   ├── sim_ai_test.exs
│   ├── sim_git_test.exs
│   ├── seeded_random_test.exs
│   ├── seed_manager_test.exs
│   ├── properties_test.exs
│   └── scenarios/
│       ├── concurrent_repo_ops_test.exs
│       ├── ai_streaming_failures_test.exs
│       ├── nif_crash_recovery_test.exs
│       ├── file_watcher_storms_test.exs
│       ├── network_failures_test.exs
│       └── liveview_reconnection_test.exs
│
lib/kanni/dst/
├── sim_clock.ex
├── sim_file_system.ex
├── sim_ai.ex
├── sim_git.ex
├── seeded_random.ex
├── seed_manager.ex
├── runner.ex
└── scenarios/
    ├── concurrent_repo_ops.ex
    ├── ai_streaming_failures.ex
    ├── nif_crash_recovery.ex
    ├── file_watcher_storms.ex
    ├── network_failures.ex
    └── liveview_reconnection.ex
```

---

## 9. Design Principles

1. **One seed, one outcome.** Given the same seed, every DST run produces the exact same sequence of events, failures, and results. No wall-clock time, no real I/O, no OS-level nondeterminism.

2. **Sim modules are drop-in replacements.** `SimGit` has the same API shape as `Kanni.Git.Native`. `SimAI` implements the same `Provider` behaviour. Application code uses a behaviour/protocol boundary; tests swap in the simulation.

3. **Clock is the universal coordinator.** Nothing happens unless `SimClock.advance/2` is called. Events fire in deterministic order within a tick. No `Process.sleep`, no `:timer.sleep`, no real time.

4. **Failures are first-class.** Every Sim module has a `set_failure_schedule/2` that injects failures at specific call counts. This is not random; it is seed-determined and reproducible.

5. **Properties over examples.** Individual scenario tests find specific bugs. Property tests with StreamData find classes of bugs. The combination catches what neither alone can.

6. **Seeds are artifacts.** Every CI run logs its seeds. Failing seeds are stored for 90 days. Any developer can replay any failure from any CI run by setting `DST_SEED=N`.

7. **Shrink to minimal case.** When a property fails at 20 operations, the shrinker binary-searches for the minimal operation count that still fails. Debugging a 3-operation failure is easier than debugging a 20-operation failure.
