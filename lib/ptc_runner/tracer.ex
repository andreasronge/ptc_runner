defmodule PtcRunner.Tracer do
  @moduledoc """
  Immutable trace recorder for SubAgent execution.

  Traces are built by prepending entries for efficiency, then reversed on finalize.
  Each Tracer has a unique trace_id for correlation in parallel/nested execution.

  ## Design Goals

  1. **Immutable traces** - No shared mutable state
  2. **Correlation IDs** - Link parent and child executions
  3. **Timestamp ordering** - Reconstruct parallel timelines
  4. **Process isolation** - Each SubAgent owns its trace
  5. **Safe aggregation** - Merge traces without race conditions

  ## Usage

      tracer = Tracer.new()
      tracer = Tracer.add_entry(tracer, %{type: :llm_call, data: %{turn: 1}})
      tracer = Tracer.add_entry(tracer, %{type: :llm_response, data: %{tokens: 100}})
      result = Tracer.finalize(tracer)

  ## Parallel Traces

  When SubAgents run in parallel via `Task.async_stream`, their traces are
  generated concurrently. Use `merge_parallel/2` to combine child traces
  into a unified timeline sorted by timestamp:

      parent = Tracer.new()
      children = [child1, child2, child3]  # finalized tracers
      merged = Tracer.merge_parallel(parent, children)
      usage = Tracer.aggregate_usage(merged)

  > **Note:** `Step.turns` is always a list of `Turn` structs. The merged map
  > structure returned by `merge_parallel/2` is a **separate aggregation result**,
  > not a replacement for `Step.turns`.

  ## Nested Traces

  For SubAgents calling other SubAgents via tools, use `record_nested_call/3`:

      tracer = Tracer.record_nested_call(tracer, tool_call, child_step)

  ## Trace ID Generation

  Trace IDs are 32-character hex strings generated from cryptographically
  secure random bytes. No external dependencies required.
  """

  defstruct [
    :trace_id,
    :parent_id,
    :started_at,
    :finalized_at,
    :max_entries,
    entries: [],
    entry_count: 0
  ]

  @typedoc """
  Tracer struct for recording execution traces.

  Fields:
  - `trace_id`: Unique 32-character hex ID for this execution
  - `parent_id`: Parent trace ID for nested agent calls (nil for root)
  - `started_at`: When the tracer was created
  - `entries`: List of trace entries (prepended for efficiency, reversed on finalize)
  - `finalized_at`: When `finalize/1` was called (nil until finalized)
  - `max_entries`: Maximum number of entries to keep (nil = unlimited)
  - `entry_count`: Current number of entries (tracked to avoid `length/1` calls)
  """
  @type t :: %__MODULE__{
          trace_id: String.t(),
          parent_id: String.t() | nil,
          started_at: DateTime.t(),
          entries: [entry()],
          finalized_at: DateTime.t() | nil,
          max_entries: non_neg_integer() | nil,
          entry_count: non_neg_integer()
        }

  @typedoc """
  A single trace entry.

  Fields:
  - `type`: The type of event being traced
  - `timestamp`: When the entry was recorded
  - `data`: Additional data for this entry
  """
  @type entry :: %{
          type: entry_type(),
          timestamp: DateTime.t(),
          data: map()
        }

  @typedoc """
  Valid trace entry types.
  """
  @type entry_type ::
          :llm_call
          | :llm_response
          | :tool_call
          | :tool_result
          | :program_start
          | :program_end
          | :return
          | :fail
          | :nested_call

  @typedoc """
  Aggregated trace from parallel execution.

  Returned by `merge_parallel/2` - separate from `Tracer.t()`.
  """
  @type merged_trace :: %{
          root_trace_id: String.t(),
          entries: [entry()],
          metadata: %{
            agent_count: non_neg_integer(),
            parallel: boolean(),
            wall_time_ms: non_neg_integer(),
            total_turns: non_neg_integer()
          }
        }

  @typedoc """
  Aggregated usage statistics.

  Returned by `aggregate_usage/1`.
  """
  @type usage_stats :: %{
          total_duration_ms: non_neg_integer(),
          llm_calls: non_neg_integer(),
          tool_calls: non_neg_integer(),
          total_turns: non_neg_integer(),
          agent_count: non_neg_integer()
        }

  @doc """
  Creates a new tracer with a unique trace ID.

  ## Options

  - `:parent_id` - Parent trace ID for nested agent calls
  - `:max_entries` - Maximum number of entries to keep (nil = unlimited, default)

  ## Examples

      iex> tracer = PtcRunner.Tracer.new()
      iex> String.length(tracer.trace_id)
      32
      iex> tracer.parent_id
      nil
      iex> tracer.entries
      []
      iex> tracer.finalized_at
      nil

      iex> tracer = PtcRunner.Tracer.new(parent_id: "abc123")
      iex> tracer.parent_id
      "abc123"

      iex> tracer = PtcRunner.Tracer.new(max_entries: 100)
      iex> tracer.max_entries
      100

  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      trace_id: generate_trace_id(),
      parent_id: opts[:parent_id],
      started_at: DateTime.utc_now(),
      entries: [],
      finalized_at: nil,
      max_entries: opts[:max_entries],
      entry_count: 0
    }
  end

  @doc """
  Adds an entry to the tracer.

  Entries are prepended for efficiency and reversed on `finalize/1`.
  A timestamp is added automatically if not provided.

  When `max_entries` is set, the oldest entries (tail of the prepended list)
  are dropped to keep the total within the limit.

  Raises `FunctionClauseError` if called on a finalized tracer.

  ## Examples

      iex> tracer = PtcRunner.Tracer.new()
      iex> tracer = PtcRunner.Tracer.add_entry(tracer, %{type: :llm_call, data: %{turn: 1}})
      iex> length(tracer.entries)
      1
      iex> hd(tracer.entries).type
      :llm_call

  """
  @spec add_entry(t(), map()) :: t()
  def add_entry(%__MODULE__{finalized_at: nil} = tracer, entry) when is_map(entry) do
    timestamped = Map.put_new(entry, :timestamp, DateTime.utc_now())
    new_entries = [timestamped | tracer.entries]
    new_count = tracer.entry_count + 1

    case tracer.max_entries do
      nil ->
        %{tracer | entries: new_entries, entry_count: new_count}

      max when new_count > max ->
        %{tracer | entries: Enum.take(new_entries, max), entry_count: max}

      _ ->
        %{tracer | entries: new_entries, entry_count: new_count}
    end
  end

  @doc """
  Finalizes the tracer, reversing entries to chronological order.

  Sets the `finalized_at` timestamp. After finalization, `add_entry/2` will
  raise a `FunctionClauseError`.

  Raises `FunctionClauseError` if called on an already finalized tracer.

  ## Examples

      iex> tracer = PtcRunner.Tracer.new()
      iex> tracer = PtcRunner.Tracer.add_entry(tracer, %{type: :llm_call, data: %{}})
      iex> tracer = PtcRunner.Tracer.add_entry(tracer, %{type: :llm_response, data: %{}})
      iex> result = PtcRunner.Tracer.finalize(tracer)
      iex> hd(result.entries).type
      :llm_call
      iex> is_struct(result.finalized_at, DateTime)
      true

  """
  @spec finalize(t()) :: t()
  def finalize(%__MODULE__{finalized_at: nil} = tracer) do
    %{tracer | finalized_at: DateTime.utc_now(), entries: Enum.reverse(tracer.entries)}
  end

  @doc """
  Returns entries in chronological order.

  If the tracer is not finalized, entries are reversed to chronological order.
  If already finalized, entries are already in chronological order.

  ## Examples

      iex> tracer = PtcRunner.Tracer.new()
      iex> tracer = PtcRunner.Tracer.add_entry(tracer, %{type: :llm_call, data: %{}})
      iex> tracer = PtcRunner.Tracer.add_entry(tracer, %{type: :llm_response, data: %{}})
      iex> entries = PtcRunner.Tracer.entries(tracer)
      iex> hd(entries).type
      :llm_call

  """
  @spec entries(t()) :: [entry()]
  def entries(%__MODULE__{finalized_at: nil, entries: entries}), do: Enum.reverse(entries)
  def entries(%__MODULE__{entries: entries}), do: entries

  @doc """
  Merge multiple traces from parallel execution.

  Returns a merged trace map (not a `Tracer.t()`) with all entries sorted by timestamp.
  The parent tracer provides the root trace ID, while child tracers provide the entries.

  ## Examples

      iex> parent = PtcRunner.Tracer.new()
      iex> child1 = PtcRunner.Tracer.new(parent_id: parent.trace_id)
      iex> child1 = PtcRunner.Tracer.add_entry(child1, %{type: :llm_call, data: %{turn: 1}})
      iex> child1 = PtcRunner.Tracer.finalize(child1)
      iex> merged = PtcRunner.Tracer.merge_parallel(parent, [child1])
      iex> merged.root_trace_id == parent.trace_id
      true
      iex> merged.metadata.agent_count
      1
      iex> merged.metadata.parallel
      true

  """
  @spec merge_parallel(t(), [t()]) :: merged_trace()
  def merge_parallel(%__MODULE__{} = parent, child_tracers) when is_list(child_tracers) do
    if child_tracers == [] do
      %{
        root_trace_id: parent.trace_id,
        entries: entries(parent),
        metadata: %{
          agent_count: 0,
          parallel: false,
          wall_time_ms: 0,
          total_turns: length(entries(parent))
        }
      }
    else
      all_entries =
        child_tracers
        |> Enum.flat_map(&entries/1)
        |> Enum.sort_by(& &1.timestamp, DateTime)

      start_times = Enum.map(child_tracers, & &1.started_at)

      end_times =
        Enum.map(child_tracers, fn t ->
          t.finalized_at || DateTime.utc_now()
        end)

      %{
        root_trace_id: parent.trace_id,
        entries: all_entries,
        metadata: %{
          agent_count: length(child_tracers),
          parallel: true,
          wall_time_ms:
            DateTime.diff(
              Enum.max(end_times, DateTime),
              Enum.min(start_times, DateTime),
              :millisecond
            ),
          total_turns: length(all_entries)
        }
      }
    end
  end

  @doc """
  Record a nested SubAgent execution within a tool call.

  Adds a `:nested_call` entry with the tool call and child step's return value and turns.

  ## Examples

      iex> tracer = PtcRunner.Tracer.new()
      iex> tool_call = %{name: "sub_agent", args: %{mission: "test"}}
      iex> child_step = %{return: "result", turns: [%{turn: 1}]}
      iex> tracer = PtcRunner.Tracer.record_nested_call(tracer, tool_call, child_step)
      iex> [entry] = PtcRunner.Tracer.entries(tracer)
      iex> entry.type
      :nested_call
      iex> entry.data.result.return
      "result"

  """
  @spec record_nested_call(t(), map(), map()) :: t()
  def record_nested_call(%__MODULE__{finalized_at: nil} = tracer, tool_call, child_step) do
    nested_tool_call =
      Map.put(tool_call, :result, %{
        return: child_step.return || child_step[:return],
        nested_turns: child_step.turns || child_step[:turns]
      })

    add_entry(tracer, %{
      type: :nested_call,
      data: nested_tool_call
    })
  end

  @doc """
  Aggregate usage statistics from a tracer or merged trace.

  Works on both `Tracer.t()` and `merged_trace()` maps.

  ## Examples

      iex> tracer = PtcRunner.Tracer.new()
      iex> tracer = PtcRunner.Tracer.add_entry(tracer, %{type: :llm_call, data: %{}})
      iex> tracer = PtcRunner.Tracer.add_entry(tracer, %{type: :tool_call, data: %{}})
      iex> tracer = PtcRunner.Tracer.finalize(tracer)
      iex> usage = PtcRunner.Tracer.aggregate_usage(tracer)
      iex> usage.llm_calls
      1
      iex> usage.tool_calls
      1

  """
  @spec aggregate_usage(t() | merged_trace()) :: usage_stats()
  def aggregate_usage(%__MODULE__{} = tracer) do
    tracer_entries = entries(tracer)

    duration_ms =
      if tracer.finalized_at && tracer.started_at do
        DateTime.diff(tracer.finalized_at, tracer.started_at, :millisecond)
      else
        0
      end

    %{
      total_duration_ms: duration_ms,
      llm_calls: count_type(tracer_entries, :llm_call),
      tool_calls: count_type(tracer_entries, :tool_call),
      total_turns: length(tracer_entries),
      agent_count: 1
    }
  end

  def aggregate_usage(%{entries: entries, metadata: metadata}) do
    %{
      total_duration_ms: metadata.wall_time_ms,
      llm_calls: count_type(entries, :llm_call),
      tool_calls: count_type(entries, :tool_call),
      total_turns: metadata.total_turns,
      agent_count: metadata.agent_count
    }
  end

  @doc """
  Total duration in milliseconds from started_at to finalized_at.

  Returns 0 if the tracer is not finalized or timestamps are nil.

  ## Examples

      iex> tracer = %PtcRunner.Tracer{
      ...>   trace_id: "test",
      ...>   parent_id: nil,
      ...>   started_at: ~U[2024-01-15 10:00:00Z],
      ...>   entries: [],
      ...>   finalized_at: ~U[2024-01-15 10:00:02Z]
      ...> }
      iex> PtcRunner.Tracer.total_duration(tracer)
      2000

      iex> tracer = PtcRunner.Tracer.new()
      iex> PtcRunner.Tracer.total_duration(tracer)
      0

  """
  @spec total_duration(t()) :: non_neg_integer()
  def total_duration(%__MODULE__{started_at: start, finalized_at: finish})
      when not is_nil(start) and not is_nil(finish) do
    DateTime.diff(finish, start, :millisecond)
  end

  def total_duration(%__MODULE__{}), do: 0

  @doc """
  Returns all entries with type `:llm_call`.

  ## Examples

      iex> tracer = PtcRunner.Tracer.new()
      iex> tracer = PtcRunner.Tracer.add_entry(tracer, %{type: :llm_call, data: %{turn: 1}})
      iex> tracer = PtcRunner.Tracer.add_entry(tracer, %{type: :tool_call, data: %{name: "search"}})
      iex> PtcRunner.Tracer.llm_calls(tracer) |> length()
      1

  """
  @spec llm_calls(t()) :: [entry()]
  def llm_calls(tracer), do: find_by_type(tracer, :llm_call)

  @doc """
  Returns all entries with type `:tool_call`.

  ## Examples

      iex> tracer = PtcRunner.Tracer.new()
      iex> tracer = PtcRunner.Tracer.add_entry(tracer, %{type: :llm_call, data: %{turn: 1}})
      iex> tracer = PtcRunner.Tracer.add_entry(tracer, %{type: :tool_call, data: %{name: "search"}})
      iex> PtcRunner.Tracer.tool_calls(tracer) |> length()
      1

  """
  @spec tool_calls(t()) :: [entry()]
  def tool_calls(tracer), do: find_by_type(tracer, :tool_call)

  @doc """
  Returns entries matching the given type.

  ## Examples

      iex> tracer = PtcRunner.Tracer.new()
      iex> tracer = PtcRunner.Tracer.add_entry(tracer, %{type: :llm_call, data: %{turn: 1}})
      iex> tracer = PtcRunner.Tracer.add_entry(tracer, %{type: :tool_call, data: %{name: "search"}})
      iex> tracer = PtcRunner.Tracer.add_entry(tracer, %{type: :llm_call, data: %{turn: 2}})
      iex> entries = PtcRunner.Tracer.find_by_type(tracer, :llm_call)
      iex> length(entries)
      2
      iex> Enum.all?(entries, & &1.type == :llm_call)
      true

  """
  @spec find_by_type(t(), entry_type()) :: [entry()]
  def find_by_type(%__MODULE__{} = tracer, type) do
    tracer
    |> entries()
    |> Enum.filter(&(&1.type == type))
  end

  @doc """
  Returns entries with `duration_ms` in data, sorted by duration descending.

  Only includes entries that have a `:duration_ms` key in their data map.

  ## Examples

      iex> tracer = PtcRunner.Tracer.new()
      iex> tracer = PtcRunner.Tracer.add_entry(tracer, %{type: :llm_call, data: %{duration_ms: 100}})
      iex> tracer = PtcRunner.Tracer.add_entry(tracer, %{type: :tool_call, data: %{duration_ms: 50}})
      iex> tracer = PtcRunner.Tracer.add_entry(tracer, %{type: :llm_call, data: %{duration_ms: 200}})
      iex> [slowest | _] = PtcRunner.Tracer.slowest_entries(tracer, 1)
      iex> slowest.data.duration_ms
      200

  """
  @spec slowest_entries(t(), non_neg_integer()) :: [entry()]
  def slowest_entries(%__MODULE__{} = tracer, n) when is_integer(n) and n >= 0 do
    tracer
    |> entries()
    |> Enum.filter(&Map.has_key?(&1.data, :duration_ms))
    |> Enum.sort_by(& &1.data.duration_ms, :desc)
    |> Enum.take(n)
  end

  @doc """
  Enhanced usage summary with duration breakdown.

  Includes total duration, LLM and tool call durations (summed from entries with
  `duration_ms` in their data), and counts.

  ## Examples

      iex> tracer = PtcRunner.Tracer.new()
      iex> tracer = PtcRunner.Tracer.add_entry(tracer, %{type: :llm_call, data: %{duration_ms: 100}})
      iex> tracer = PtcRunner.Tracer.add_entry(tracer, %{type: :tool_call, data: %{duration_ms: 50}})
      iex> tracer = PtcRunner.Tracer.finalize(tracer)
      iex> summary = PtcRunner.Tracer.usage_summary(tracer)
      iex> summary.llm_duration_ms
      100
      iex> summary.tool_duration_ms
      50
      iex> summary.llm_call_count
      1
      iex> summary.tool_call_count
      1

  """
  @spec usage_summary(t()) :: map()
  def usage_summary(%__MODULE__{} = tracer) do
    all_entries = entries(tracer)

    %{
      total_duration_ms: total_duration(tracer),
      llm_duration_ms: sum_duration_by_type(all_entries, :llm_call),
      tool_duration_ms: sum_duration_by_type(all_entries, :tool_call),
      llm_call_count: count_type(all_entries, :llm_call),
      tool_call_count: count_type(all_entries, :tool_call),
      total_entries: length(all_entries)
    }
  end

  defp sum_duration_by_type(entries, type) do
    entries
    |> Enum.filter(&(&1.type == type))
    |> Enum.map(&Map.get(&1.data, :duration_ms, 0))
    |> Enum.sum()
  end

  defp count_type(entries, type) do
    Enum.count(entries, &(&1.type == type))
  end

  defp generate_trace_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
