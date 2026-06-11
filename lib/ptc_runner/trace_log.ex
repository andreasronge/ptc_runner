defmodule PtcRunner.TraceLog do
  @moduledoc """
  Captures SubAgent execution events to JSONL files for offline analysis.

  TraceLog attaches to SubAgent telemetry events and writes them to a JSONL file,
  enabling detailed debugging and performance analysis of agent executions.

  ## Usage

  The simplest way to capture a trace is with `with_trace/2`:

      {:ok, {:ok, step}, trace_path} = TraceLog.with_trace(fn ->
        SubAgent.run(agent, llm: my_llm())
      end)

      # Analyze the trace
      events = TraceLog.Analyzer.load(trace_path)
      summary = TraceLog.Analyzer.summary(events)

  For more control, use `start/1` and `stop/1`:

      {:ok, collector} = TraceLog.start(path: "my_trace.jsonl")
      {:ok, step} = SubAgent.run(agent, llm: my_llm())
      {:ok, path, errors} = TraceLog.stop(collector)

  ## Event Format

  Each line in the JSONL file is a JSON object with:

      {
        "event": "run.start",           # Event type (run|turn|llm|tool).(start|stop|exception)
        "trace_id": "abc123...",        # Unique trace identifier
        "timestamp": "2024-01-...",     # ISO 8601 timestamp
        "measurements": {...},          # Telemetry measurements
        "metadata": {...},              # Event-specific metadata
        "duration_ms": 123              # Duration (for stop events)
      }

  ## Process Isolation and Cross-Process Propagation

  Traces are isolated by process. Only events from the process that called `start/1`
  are captured. This allows multiple concurrent traces without interference.

  Nested traces are supported - each `with_trace` call creates its own trace file,
  and events are routed to the innermost active collector.

  ### Cross-Process Tracing

  When execution spans multiple processes (e.g., parallel tasks), use
  `join/2` to propagate trace context to child processes:

      collectors = TraceLog.active_collectors()
      parent_span = PtcRunner.SubAgent.Telemetry.current_span_id()

      Task.async(fn ->
        TraceLog.join(collectors, parent_span)
        # Events from this process are now captured AND linked to parent
      end)

  **Note:** The sandbox process inherits trace collectors via `join/2`, so tool
  telemetry events (`tool.start`, `tool.stop`) emitted inside the sandbox are
  captured directly by the trace handler.

  ## See Also

  - `PtcRunner.TraceLog.Analyzer` - Load and analyze trace files
  - `PtcRunner.TraceLog.Collector` - Low-level file writing
  - `PtcRunner.TraceLog.Handler` - Telemetry handler
  - [Observability Guide](subagent-observability.md) - How TraceLog relates to `PtcRunner.Tracer`
  """

  alias PtcRunner.SubAgent.Telemetry
  alias PtcRunner.TraceContext
  alias PtcRunner.TraceLog.{Collector, Handler, MemorySink}

  @doc """
  Starts trace collection for the current process.

  Returns a collector process that will capture all SubAgent telemetry events
  from this process until `stop/1` is called.

  ## Options

    * `:path` - File path for the JSONL output. Defaults to a timestamped file.
    * `:trace_id` - Custom trace identifier. Defaults to a random hex string.
    * `:trace_kind` - Trace type discriminator (e.g., `"benchmark"`, `"analysis"`).
    * `:producer` - Component that created this trace (e.g., `"demo.benchmark"`).
    * `:trace_label` - Human-readable label (e.g., test case name).
    * `:model` - LLM model identifier.
    * `:query` - Input query or question.
    * `:meta` - Producer-specific metadata under `data`.

  ## Examples

      {:ok, collector} = TraceLog.start()
      {:ok, step} = SubAgent.run(agent, llm: my_llm())
      {:ok, path, errors} = TraceLog.stop(collector)

      # With typed trace header
      {:ok, collector} = TraceLog.start(
        path: "/tmp/debug.jsonl",
        trace_kind: "benchmark",
        producer: "my_app",
        query: "How many products?"
      )
  """
  @spec start(keyword()) :: {:ok, pid()}
  def start(opts \\ []) do
    {:ok, collector} = Collector.start_link(opts)

    trace_id = Collector.trace_id(collector)
    handler_id = "trace-log-#{System.unique_integer([:positive])}"
    meta = Keyword.get(opts, :meta, %{})

    Handler.attach(handler_id, collector, trace_id, meta)

    # Push collector onto stack (supports nested traces)
    TraceContext.push_collector(collector, handler_id)

    {:ok, collector}
  end

  @doc """
  Stops trace collection and closes the trace file.

  Returns the path to the trace file and the number of write errors (if any).

  ## Examples

      {:ok, collector} = TraceLog.start()
      # ... run SubAgent ...
      {:ok, path, errors} = TraceLog.stop(collector)
  """
  @spec stop(pid()) :: {:ok, String.t(), non_neg_integer()}
  def stop(collector) do
    # Remove collector from stack (supports nested traces and out-of-order stops)
    case TraceContext.remove_collector(collector) do
      {_collector, handler_id} ->
        Handler.detach(handler_id)
        Collector.stop(collector)

      nil ->
        # Collector already stopped, return a default result
        {:ok, "unknown", 0}
    end
  end

  @doc """
  Executes a function while capturing a trace.

  This is the recommended way to capture traces. It ensures the trace is
  properly started and stopped, even if the function raises an exception.

  ## Options

  Accepts all options from `start/1`: `:path`, `:trace_id`, `:trace_kind`,
  `:producer`, `:trace_label`, `:model`, `:query`, `:meta`.

  ## Examples

      {:ok, {:ok, step}, trace_path} = TraceLog.with_trace(fn ->
        SubAgent.run(agent, llm: my_llm())
      end)

      # With typed trace header
      {:ok, {:ok, step}, path} = TraceLog.with_trace(
        fn -> SubAgent.run(agent, llm: my_llm()) end,
        trace_kind: "benchmark",
        query: "How many products?"
      )
  """
  @spec with_trace((-> result), keyword()) :: {:ok, result, String.t()} when result: term()
  def with_trace(fun, opts \\ []) when is_function(fun, 0) do
    {:ok, collector} = start(opts)

    try do
      result = fun.()
      {:ok, path, _errors} = stop(collector)
      {:ok, result, path}
    catch
      kind, reason ->
        try do
          stop(collector)
        catch
          _, _ -> :ok
        end

        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @doc """
  Returns the collector for the current process, if any.

  ## Examples

      {:ok, _collector} = TraceLog.start()
      collector = TraceLog.current_collector()
      # collector is a pid
  """
  @spec current_collector() :: pid() | nil
  def current_collector do
    TraceContext.current_collector()
  end

  @doc """
  Returns all active collectors for the current process.

  The list is ordered from innermost (most recent) to outermost.
  """
  @spec active_collectors() :: [pid()]
  def active_collectors do
    TraceContext.collectors()
  end

  @doc """
  Joins the current process to existing trace collectors.

  This is used for trace propagation across process boundaries. When spawning
  child processes (via Task.async_stream, Process.spawn, etc.), the parent's
  trace collectors are not automatically inherited. Call this function at the
  start of the child process to re-attach to the parent's trace session.

  ## Parameters

    * `collectors` - List of collector PIDs to join (from `active_collectors/0`)
    * `parent_span_id` - Optional span ID from parent process for span hierarchy

  ## Example

      # In parent process
      collectors = TraceLog.active_collectors()
      parent_span = PtcRunner.SubAgent.Telemetry.current_span_id()

      Task.async(fn ->
        TraceLog.join(collectors, parent_span)
        # Now trace events from this process will be captured
        # AND linked to the parent span hierarchy
        SubAgent.run(agent, llm: llm)
      end)

  ## Notes

  - Only joins collectors that are still alive (stale PIDs are filtered out)
  - Does not attach telemetry handlers (they are global and already attached)
  - Safe to call multiple times or with an empty list
  - When `parent_span_id` is provided, sets up span hierarchy so new spans
    in this process have the parent span as their parent_span_id
  """
  @spec join([pid()], String.t() | nil) :: :ok
  def join(collectors, parent_span_id \\ nil)

  def join([], nil), do: :ok

  def join([], parent_span_id) do
    # Even without collectors, set up span hierarchy if provided
    Telemetry.set_parent_span(parent_span_id)
    :ok
  end

  def join(collectors, parent_span_id) when is_list(collectors) do
    TraceContext.merge_collectors(collectors)

    # Set up span hierarchy for proper parent-child relationships
    Telemetry.set_parent_span(parent_span_id)

    :ok
  end

  def join(_, _), do: :ok

  @doc """
  Writes a serialized event map to the innermost active collector in the
  calling process's collector stack.

  Used by call sites that need to emit a custom JSONL line from outside
  the SubAgent telemetry path (e.g., the MCP server recording per-call
  outcomes). The event map is forwarded as-is to
  `PtcRunner.TraceLog.Collector.write_event/2`, which assigns a `seq`,
  encodes via `PtcRunner.TraceLog.Event.encode/1`, and appends a JSONL
  line.

  Returns `:ok` if a collector was active and the event was queued for
  writing, or `:no_collector` if no `with_trace/2` / `start/1` scope is
  active in this process.

  This function never raises. Errors during forwarding are swallowed
  (writes are async casts; encoding failures degrade gracefully).

  ## Examples

      TraceLog.with_trace(fn ->
        TraceLog.write_to_active(%{
          "event" => "mcp.call.stop",
          "trace_id" => "abc",
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "data" => %{"reason" => "ok"}
        })
      end)
  """
  @spec write_to_active(map()) :: :ok | :no_collector
  def write_to_active(event_map) when is_map(event_map) do
    case TraceContext.current_collector() do
      nil ->
        :no_collector

      collector ->
        try do
          Collector.write_event(collector, event_map)
          :ok
        catch
          _, _ -> :ok
        end
    end
  rescue
    _ -> :no_collector
  end

  def write_to_active(_), do: :no_collector

  @doc """
  Returns true if any turn-log sink (JSONL collector or in-memory sink) is
  active in the current process.

  Turn drivers consult this before building a turn event so the (small) build
  cost is skipped entirely when nothing is recording.
  """
  @spec recording?() :: boolean()
  def recording? do
    TraceContext.current_collector() != nil or TraceContext.memory_sinks() != []
  end

  @doc """
  Records an already-built turn-event map to every active sink — *every* JSONL
  collector on the stack and every active in-memory sink.

  Unlike `write_to_active/1` (innermost collector only), this fans out to all
  active collectors, matching the telemetry handler's routing: under nested
  `with_trace/2` scopes both the inner and outer trace files capture the turn,
  so cross-session analysis works for either. Each collector stamps its own
  `trace_id`/`seq` on its copy of the event.

  This is the single emission point shared by both turn drivers
  (`PtcRunner.Session` and the `PtcRunner.SubAgent` loop). It never raises and
  is a no-op when nothing is recording. Build the event with
  `PtcRunner.TraceLog.TurnEvent.build/1`.
  """
  @spec record_turn_event(map()) :: :ok
  def record_turn_event(event_map) when is_map(event_map) do
    Enum.each(TraceContext.collectors(), fn collector ->
      safe_write(fn -> Collector.write_event(collector, event_map) end)
    end)

    Enum.each(TraceContext.memory_sinks(), fn sink ->
      safe_write(fn -> MemorySink.record(sink, event_map) end)
    end)

    :ok
  end

  def record_turn_event(_), do: :ok

  defp safe_write(fun) do
    fun.()
    :ok
  catch
    _, _ -> :ok
  end

  @doc """
  Starts an in-memory turn-log sink and activates it for the current process.

  Returns the sink pid; query it with `PtcRunner.TraceLog.MemorySink.events/1`
  (or the cross-session `PtcRunner.TraceLog.Analyzer` functions). Accepts the
  same options as `PtcRunner.TraceLog.MemorySink.start_link/1` (`:max_bytes`,
  `:name`). Detach with `stop_memory_sink/1`.
  """
  @spec start_memory_sink(keyword()) :: {:ok, pid()}
  def start_memory_sink(opts \\ []) do
    {:ok, sink} = MemorySink.start_link(opts)
    TraceContext.push_memory_sink(sink)
    {:ok, sink}
  end

  @doc """
  Detaches an in-memory sink from the current process so new turn events no
  longer route to it. The sink process is left alive so its events stay
  queryable; stop it explicitly when done.
  """
  @spec stop_memory_sink(pid()) :: :ok
  def stop_memory_sink(sink) when is_pid(sink) do
    TraceContext.remove_memory_sink(sink)
    :ok
  end

  @doc """
  Returns all in-memory sinks active in the current process (innermost first).
  """
  @spec active_memory_sinks() :: [pid()]
  def active_memory_sinks do
    TraceContext.memory_sinks()
  end
end
