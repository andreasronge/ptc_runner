defmodule PtcRunner.Lisp.Result do
  @moduledoc """
  Native continuation result returned by the neutral PTC-Lisp evaluator.

  Evaluation-local tool cache entries are private evaluator state and are not
  retained in this result. `Inspect` reports only the outcome, bounded field
  counts, and retained memory size; it never renders return/failure values,
  memory, prompts, messages, tool records, or child steps.
  """

  defstruct [
    :return,
    :fail,
    :memory,
    :signature,
    :usage,
    :turns,
    :trace_id,
    :parent_trace_id,
    :name,
    :field_descriptions,
    :failure_origin,
    :prints,
    :tool_calls,
    :pmap_calls,
    :child_traces,
    :child_steps,
    :messages,
    :prompt,
    :original_prompt,
    :tools,
    :prelude_trace,
    prelude_call_counts: %{}
  ]

  @type t :: %__MODULE__{
          return: term() | nil,
          fail: map() | nil,
          memory: map(),
          signature: String.t() | nil,
          usage: map() | nil,
          turns: [term()] | nil,
          trace_id: String.t() | nil,
          parent_trace_id: String.t() | nil,
          field_descriptions: map() | nil,
          failure_origin: :capability | nil,
          prints: [String.t()],
          tool_calls: [map()],
          pmap_calls: [map()],
          child_traces: [String.t()],
          child_steps: [t()],
          messages: [map()] | nil,
          prompt: String.t() | nil,
          tools: map() | nil,
          prelude_trace: PtcRunner.Lisp.Prelude.trace_summary() | nil,
          prelude_call_counts: %{optional(String.t()) => non_neg_integer()}
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
      child_traces: [],
      child_steps: []
    }
  end

  @spec error(atom(), String.t(), map()) :: t()
  def error(reason, message, memory), do: error(reason, message, memory, %{})

  @spec error(atom(), String.t(), map(), map()) :: t()
  def error(reason, message, memory, details) do
    %__MODULE__{
      return: nil,
      fail: %{reason: reason, message: message, details: details},
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
      child_traces: [],
      child_steps: []
    }
  end
end
