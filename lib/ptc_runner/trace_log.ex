defmodule PtcRunner.TraceLog do
  @moduledoc """
  Captures SubAgent execution events to JSONL files for offline analysis.

  TraceLog attaches to SubAgent telemetry events and writes them to a JSONL file,
  enabling detailed debugging and performance analysis of agent executions.

  ## Usage

  The simplest way to capture a trace is with `with_trace/2`:

      {:ok, step, trace_path} = TraceLog.with_trace(fn ->
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

  When execution spans multiple processes (e.g., PlanRunner parallel tasks), use
  `join/2` to propagate trace context to child processes:

      collectors = TraceLog.active_collectors()
      parent_span = PtcRunner.SubAgent.Telemetry.current_span_id()

      Task.async(fn ->
        TraceLog.join(collectors, parent_span)
        # Events from this process are now captured AND linked to parent
      end)

  PlanRunner automatically propagates trace context to parallel task workers.

  **Note:** Tool telemetry events (`tool.start`, `tool.stop`) are currently
  re-emitted by SubAgent.Loop after sandbox execution returns, as the sandbox
  process doesn't inherit trace collectors.

  ## See Also

  - `PtcRunner.TraceLog.Analyzer` - Load and analyze trace files
  - `PtcRunner.TraceLog.Collector` - Low-level file writing
  - `PtcRunner.TraceLog.Handler` - Telemetry handler
  """

  alias PtcRunner.SubAgent.Telemetry
  alias PtcRunner.TraceLog.{Collector, Handler}

  @doc """
  Starts trace collection for the current process.

  Returns a collector process that will capture all SubAgent telemetry events
  from this process until `stop/1` is called.

  ## Options

    * `:path` - File path for the JSONL output. Defaults to a timestamped file.
    * `:trace_id` - Custom trace identifier. Defaults to a random hex string.
    * `:meta` - Additional metadata to include in the trace header.

  ## Examples

      {:ok, collector} = TraceLog.start()
      {:ok, step} = SubAgent.run(agent, llm: my_llm())
      {:ok, path, errors} = TraceLog.stop(collector)

      # With custom path
      {:ok, collector} = TraceLog.start(path: "/tmp/debug.jsonl")
  """
  @spec start(keyword()) :: {:ok, pid()}
  def start(opts \\ []) do
    {:ok, collector} = Collector.start_link(opts)

    trace_id = Collector.trace_id(collector)
    handler_id = "trace-log-#{System.unique_integer([:positive])}"
    meta = Keyword.get(opts, :meta, %{})

    Handler.attach(handler_id, collector, trace_id, meta)

    # Push collector onto stack (supports nested traces)
    existing_collectors = Process.get(:ptc_trace_collectors, [])
    existing_handlers = Process.get(:ptc_trace_handler_ids, [])
    Process.put(:ptc_trace_collectors, [collector | existing_collectors])
    Process.put(:ptc_trace_handler_ids, [handler_id | existing_handlers])

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
    # Pop collector from stack (supports nested traces)
    collectors = Process.get(:ptc_trace_collectors, [])
    handlers = Process.get(:ptc_trace_handler_ids, [])

    {handler_id, found} =
      case {collectors, handlers} do
        {[^collector | rest_collectors], [h | rest_handlers]} ->
          Process.put(:ptc_trace_collectors, rest_collectors)
          Process.put(:ptc_trace_handler_ids, rest_handlers)
          {h, true}

        _ ->
          # Collector not at top of stack - find and remove it
          idx = Enum.find_index(collectors, &(&1 == collector))

          if idx do
            {new_collectors, _} = List.pop_at(collectors, idx)
            {handler, _new_handlers} = List.pop_at(handlers, idx)
            Process.put(:ptc_trace_collectors, new_collectors)
            Process.put(:ptc_trace_handler_ids, List.delete_at(handlers, idx))
            {handler, true}
          else
            {nil, false}
          end
      end

    if handler_id do
      Handler.detach(handler_id)
    end

    # Only call Collector.stop if we found the collector (idempotent)
    if found do
      Collector.stop(collector)
    else
      # Collector already stopped, return a default result
      {:ok, "unknown", 0}
    end
  end

  @doc """
  Executes a function while capturing a trace.

  This is the recommended way to capture traces. It ensures the trace is
  properly started and stopped, even if the function raises an exception.

  ## Options

    * `:path` - File path for the JSONL output
    * `:trace_id` - Custom trace identifier
    * `:meta` - Additional metadata

  ## Examples

      {:ok, step, trace_path} = TraceLog.with_trace(fn ->
        SubAgent.run(agent, llm: my_llm())
      end)

      # With options
      {:ok, step, path} = TraceLog.with_trace(
        fn -> SubAgent.run(agent, llm: my_llm()) end,
        path: "/tmp/trace.jsonl",
        meta: %{user: "test"}
      )
  """
  @spec with_trace((-> result), keyword()) :: {:ok, result, String.t()} when result: term()
  def with_trace(fun, opts \\ []) when is_function(fun, 0) do
    {:ok, collector} = start(opts)

    try do
      result = fun.()
      {:ok, path, _errors} = stop(collector)
      {:ok, result, path}
    after
      stop(collector)
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
    case Process.get(:ptc_trace_collectors, []) do
      [collector | _] -> collector
      [] -> nil
    end
  end

  @doc """
  Returns all active collectors for the current process.

  The list is ordered from innermost (most recent) to outermost.
  """
  @spec active_collectors() :: [pid()]
  def active_collectors do
    Process.get(:ptc_trace_collectors, [])
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
    # Filter to only alive collectors (in case parent stopped tracing)
    alive_collectors = Enum.filter(collectors, &Process.alive?/1)

    if alive_collectors != [] do
      # Merge with any existing collectors in this process
      existing = Process.get(:ptc_trace_collectors, [])
      # Deduplicate while preserving order (existing first, then new)
      merged = Enum.uniq(existing ++ alive_collectors)
      Process.put(:ptc_trace_collectors, merged)
    end

    # Set up span hierarchy for proper parent-child relationships
    Telemetry.set_parent_span(parent_span_id)

    :ok
  end

  def join(_, _), do: :ok
end
