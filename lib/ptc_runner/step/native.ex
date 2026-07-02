defmodule PtcRunner.Step.Native do
  @moduledoc false

  alias PtcRunner.Step

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
    summaries: %{},
    tool_cache: %{}
  ]

  @type t :: %__MODULE__{
          return: term() | nil,
          fail: Step.fail() | nil,
          memory: map(),
          journal: map() | nil,
          signature: String.t() | nil,
          usage: Step.usage() | nil,
          turns: [PtcRunner.Turn.t()] | nil,
          trace_id: String.t() | nil,
          parent_trace_id: String.t() | nil,
          field_descriptions: map() | nil,
          prints: [String.t()],
          tool_calls: [Step.tool_call()],
          pmap_calls: [Step.pmap_call()],
          catalog_ops: [Step.catalog_op()],
          child_traces: [String.t()],
          child_steps: [t()],
          messages: [Step.message()] | nil,
          prompt: String.t() | nil,
          tools: map() | nil,
          prelude_trace: PtcRunner.Lisp.Prelude.trace_summary() | nil,
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

  @doc false
  @spec from_public(Step.t()) :: t()
  def from_public(%Step{} = step) do
    %__MODULE__{
      return: step.return,
      fail: step.fail,
      memory: step.memory,
      journal: step.journal,
      signature: step.signature,
      usage: step.usage,
      turns: step.turns,
      trace_id: step.trace_id,
      parent_trace_id: step.parent_trace_id,
      name: step.name,
      field_descriptions: step.field_descriptions,
      prints: step.prints,
      tool_calls: step.tool_calls,
      pmap_calls: step.pmap_calls,
      catalog_ops: step.catalog_ops,
      child_traces: step.child_traces,
      child_steps: step.child_steps,
      messages: step.messages,
      prompt: step.prompt,
      original_prompt: step.original_prompt,
      tools: step.tools,
      prelude_trace: step.prelude_trace,
      summaries: step.summaries,
      tool_cache: step.tool_cache
    }
  end
end
