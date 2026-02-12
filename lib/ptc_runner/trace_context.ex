defmodule PtcRunner.TraceContext do
  @moduledoc """
  Centralizes process dictionary access for tracing context.

  All tracing-related process dictionary keys are managed through this module,
  providing a single point of access for collector stacks, span stacks, and
  child step pass-through data.

  ## Collector Stack

  Supports nested trace collection. Each `TraceLog.start/1` pushes a collector
  onto the stack, and `TraceLog.stop/1` pops it. Events are routed to all
  active collectors.

  ## Span Stack

  Maintains parent-child span relationships for telemetry correlation.
  Used by `PtcRunner.SubAgent.Telemetry` to track nested spans.

  ## Cross-Process Propagation

  Use `capture/0` and `attach/1` to propagate trace context across process
  boundaries (e.g., `Task.async_stream/3`).

  ## Child Step Pass-Through

  Used by `PtcRunner.Lisp.Eval` to smuggle child execution metadata through
  the process dictionary without polluting the Lisp value space.

  ## See Also

  - [Observability Guide](subagent-observability.md) — cross-process tracing section
  - `PtcRunner.TraceLog` — JSONL trace capture
  - `PtcRunner.SubAgent.Telemetry` — telemetry event emission
  """

  @collector_key :ptc_trace_collectors
  @handler_key :ptc_trace_handler_ids
  @span_stack_key :ptc_telemetry_span_stack
  @child_trace_key :last_child_trace_id
  @child_step_key :last_child_step

  # --- Collector Stack ---

  @doc """
  Pushes a collector and its handler ID onto the stack.
  """
  @spec push_collector(pid(), String.t()) :: :ok
  def push_collector(collector, handler_id) when is_pid(collector) and is_binary(handler_id) do
    existing_collectors = Process.get(@collector_key, [])
    existing_handlers = Process.get(@handler_key, [])
    Process.put(@collector_key, [collector | existing_collectors])
    Process.put(@handler_key, [handler_id | existing_handlers])
    :ok
  end

  @doc """
  Pops the innermost collector and handler ID from the stack.

  Returns `{collector, handler_id}` or `nil` if the stack is empty.
  """
  @spec pop_collector() :: {pid(), String.t()} | nil
  def pop_collector do
    case {Process.get(@collector_key, []), Process.get(@handler_key, [])} do
      {[collector | rest_collectors], [handler_id | rest_handlers]} ->
        Process.put(@collector_key, rest_collectors)
        Process.put(@handler_key, rest_handlers)
        {collector, handler_id}

      _ ->
        nil
    end
  end

  @doc """
  Removes a specific collector from the stack (not necessarily the top).

  Returns `{collector, handler_id}` if found, or `nil`.
  """
  @spec remove_collector(pid()) :: {pid(), String.t()} | nil
  def remove_collector(collector) when is_pid(collector) do
    collectors = Process.get(@collector_key, [])
    handlers = Process.get(@handler_key, [])

    case Enum.find_index(collectors, &(&1 == collector)) do
      nil ->
        nil

      idx ->
        {removed_collector, new_collectors} = List.pop_at(collectors, idx)
        {handler_id, new_handlers} = List.pop_at(handlers, idx)
        Process.put(@collector_key, new_collectors)
        Process.put(@handler_key, new_handlers)
        {removed_collector, handler_id}
    end
  end

  @doc """
  Returns all active collectors (innermost first).
  """
  @spec collectors() :: [pid()]
  def collectors do
    Process.get(@collector_key, [])
  end

  @doc """
  Returns the innermost (current) collector, or `nil`.
  """
  @spec current_collector() :: pid() | nil
  def current_collector do
    case Process.get(@collector_key, []) do
      [collector | _] -> collector
      [] -> nil
    end
  end

  @doc """
  Merges collectors from another process into the current stack.

  Filters out dead processes and deduplicates while preserving order.
  """
  @spec merge_collectors([pid()]) :: :ok
  def merge_collectors(new_collectors) when is_list(new_collectors) do
    alive = Enum.filter(new_collectors, &Process.alive?/1)

    if alive != [] do
      existing = Process.get(@collector_key, [])
      merged = Enum.uniq(existing ++ alive)
      Process.put(@collector_key, merged)
    end

    :ok
  end

  # --- Span Stack ---

  @doc """
  Pushes a span ID onto the stack. Returns the parent span ID (previous top).
  """
  @spec push_span(String.t()) :: String.t() | nil
  def push_span(span_id) when is_binary(span_id) do
    stack = Process.get(@span_stack_key, [])
    parent_span_id = List.first(stack)
    Process.put(@span_stack_key, [span_id | stack])
    parent_span_id
  end

  @doc """
  Pops the current span from the stack.
  """
  @spec pop_span() :: String.t() | nil
  def pop_span do
    case Process.get(@span_stack_key, []) do
      [current | rest] ->
        Process.put(@span_stack_key, rest)
        current

      [] ->
        nil
    end
  end

  @doc """
  Returns the current (innermost) span ID, or `nil`.
  """
  @spec current_span_id() :: String.t() | nil
  def current_span_id do
    case Process.get(@span_stack_key, []) do
      [current | _] -> current
      [] -> nil
    end
  end

  @doc """
  Returns the parent span ID (second element on the stack), or `nil`.
  """
  @spec parent_span_id() :: String.t() | nil
  def parent_span_id do
    case Process.get(@span_stack_key, []) do
      [_current, parent | _] -> parent
      _ -> nil
    end
  end

  @doc """
  Returns the span context map with `:span_id` and `:parent_span_id`.
  """
  @spec span_context() :: %{span_id: String.t() | nil, parent_span_id: String.t() | nil}
  def span_context do
    case Process.get(@span_stack_key, []) do
      [current | rest] ->
        %{span_id: current, parent_span_id: List.first(rest)}

      [] ->
        %{span_id: nil, parent_span_id: nil}
    end
  end

  @doc """
  Sets the initial parent span for this process (for cross-process propagation).

  Only sets if the span stack is empty (does not override existing context).
  """
  @spec set_parent_span(String.t() | nil) :: :ok
  def set_parent_span(nil), do: :ok

  def set_parent_span(parent_span_id) when is_binary(parent_span_id) do
    case Process.get(@span_stack_key, []) do
      [] -> Process.put(@span_stack_key, [parent_span_id])
      _ -> :ok
    end

    :ok
  end

  # --- Cross-Process Propagation ---

  @doc """
  Captures the current trace context into a portable map.

  Use with `attach/1` to propagate context to child processes.
  """
  @spec capture() :: map()
  def capture do
    %{
      collectors: Process.get(@collector_key, []),
      span_stack: Process.get(@span_stack_key, [])
    }
  end

  @doc """
  Restores trace context from a captured map in a child process.

  Merges collectors (filtering dead PIDs) and restores the span stack.
  """
  @spec attach(map()) :: :ok
  def attach(%{collectors: collectors, span_stack: span_stack}) do
    merge_collectors(collectors)

    if span_stack != [] do
      # Set the parent span from the captured context
      case span_stack do
        [parent_span_id | _] -> set_parent_span(parent_span_id)
        _ -> :ok
      end
    end

    :ok
  end

  def attach(_), do: :ok

  # --- Child Step Pass-Through ---

  @doc """
  Stores a child execution result for pass-through.
  """
  @spec put_child_result(String.t() | nil, term()) :: :ok
  def put_child_result(trace_id, step) do
    if trace_id, do: Process.put(@child_trace_key, trace_id)
    if step, do: Process.put(@child_step_key, step)
    :ok
  end

  @doc """
  Takes (gets and deletes) the child execution result. One-shot read.

  Returns `{trace_id, step}` or `nil` if no child result is stored.
  """
  @spec take_child_result() :: {String.t() | nil, term()} | nil
  def take_child_result do
    trace_id = Process.get(@child_trace_key)
    step = Process.get(@child_step_key)

    Process.delete(@child_trace_key)
    Process.delete(@child_step_key)

    if trace_id || step do
      {trace_id, step}
    else
      nil
    end
  end
end
