defmodule PtcRunner.Tracer do
  @moduledoc """
  Immutable trace recorder for SubAgent execution.

  Traces are built by prepending entries for efficiency, then reversed on finalize.
  Each Tracer has a unique trace_id for correlation in parallel/nested execution.

  ## Usage

      tracer = Tracer.new()
      tracer = Tracer.add_entry(tracer, %{type: :llm_call, data: %{turn: 1}})
      tracer = Tracer.add_entry(tracer, %{type: :llm_response, data: %{tokens: 100}})
      result = Tracer.finalize(tracer)

  See [parallel-trace-design.md](docs/ptc_agents/parallel-trace-design.md) for architecture.
  """

  defstruct [
    :trace_id,
    :parent_id,
    :started_at,
    :entries,
    :finalized_at
  ]

  @typedoc """
  Tracer struct for recording execution traces.

  Fields:
  - `trace_id`: Unique 32-character hex ID for this execution
  - `parent_id`: Parent trace ID for nested agent calls (nil for root)
  - `started_at`: When the tracer was created
  - `entries`: List of trace entries (prepended for efficiency, reversed on finalize)
  - `finalized_at`: When `finalize/1` was called (nil until finalized)
  """
  @type t :: %__MODULE__{
          trace_id: String.t(),
          parent_id: String.t() | nil,
          started_at: DateTime.t(),
          entries: [entry()],
          finalized_at: DateTime.t() | nil
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

  @doc """
  Creates a new tracer with a unique trace ID.

  ## Options

  - `:parent_id` - Parent trace ID for nested agent calls

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

  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      trace_id: generate_trace_id(),
      parent_id: opts[:parent_id],
      started_at: DateTime.utc_now(),
      entries: [],
      finalized_at: nil
    }
  end

  @doc """
  Adds an entry to the tracer.

  Entries are prepended for efficiency and reversed on `finalize/1`.
  A timestamp is added automatically if not provided.

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
    %{tracer | entries: [timestamped | tracer.entries]}
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

  defp generate_trace_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
