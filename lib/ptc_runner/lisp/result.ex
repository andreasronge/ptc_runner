defmodule PtcRunner.Lisp.Result do
  @moduledoc false

  defstruct [
    :return,
    :fail,
    :memory,
    :journal,
    :signature,
    :usage,
    :turns,
    :trace_id,
    :parent_trace_id,
    :name,
    :field_descriptions,
    :prints,
    :tool_calls,
    :pmap_calls,
    :catalog_ops,
    :child_traces,
    :child_steps,
    :messages,
    :prompt,
    :original_prompt,
    :tools,
    :prelude_trace,
    prelude_call_counts: %{},
    summaries: %{},
    tool_cache: %{}
  ]

  @type t :: %__MODULE__{
          return: term() | nil,
          fail: map() | nil,
          memory: map(),
          journal: map() | nil,
          signature: String.t() | nil,
          usage: map() | nil,
          turns: [term()] | nil,
          trace_id: String.t() | nil,
          parent_trace_id: String.t() | nil,
          field_descriptions: map() | nil,
          prints: [String.t()],
          tool_calls: [map()],
          pmap_calls: [map()],
          catalog_ops: [map()],
          child_traces: [String.t()],
          child_steps: [t()],
          messages: [map()] | nil,
          prompt: String.t() | nil,
          tools: map() | nil,
          prelude_trace: PtcRunner.Lisp.Prelude.trace_summary() | nil,
          prelude_call_counts: %{optional(String.t()) => non_neg_integer()},
          summaries: %{String.t() => String.t()},
          tool_cache: map()
        }

  @spec ok(term(), map()) :: t()
  def ok(return, memory) do
    %__MODULE__{
      return: return,
      fail: nil,
      memory: memory,
      signature: nil,
      usage: nil,
      turns: nil,
      trace_id: nil,
      parent_trace_id: nil,
      field_descriptions: nil,
      prints: [],
      tool_calls: [],
      pmap_calls: [],
      catalog_ops: [],
      child_traces: [],
      child_steps: []
    }
  end

  @spec error(atom(), String.t(), map()) :: t()
  def error(reason, message, memory), do: error(reason, message, memory, %{})

  @spec error(atom(), String.t(), map(), map()) :: t()
  def error(reason, message, memory, details), do: error(reason, message, memory, details, [])

  @spec error(atom(), String.t(), map(), map(), keyword()) :: t()
  def error(reason, message, memory, details, opts) do
    %__MODULE__{
      return: nil,
      fail: %{reason: reason, message: message, details: details},
      memory: memory,
      journal: Keyword.get(opts, :journal),
      tool_cache: Keyword.get(opts, :tool_cache, %{}),
      signature: nil,
      usage: nil,
      turns: nil,
      trace_id: nil,
      parent_trace_id: nil,
      field_descriptions: nil,
      prints: [],
      tool_calls: [],
      pmap_calls: [],
      catalog_ops: [],
      child_traces: [],
      child_steps: []
    }
  end
end
