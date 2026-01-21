defmodule PtcRunner.SubAgent.CompiledAgent do
  @moduledoc """
  A compiled SubAgent with pre-derived PTC-Lisp logic.

  Created via `SubAgent.compile/2`, this struct stores PTC-Lisp code derived
  once by an LLM. The compiled agent can then be executed many times without
  further LLM calls, making it efficient for processing many items with
  deterministic logic.

  ## Use Cases

  - Processing batch data with consistent logic (e.g., scoring reports)
  - Orchestrating SubAgentTools with deterministic control flow
  - Workflows where the logic is derived once and reused many times

  ## Tool Support

  - Pure Elixir tools - Supported, executed directly
  - `LLMTool` - NOT supported (raises ArgumentError at compile time)
  - `SubAgentTool` - Supported, requires `llm` option at execute time

  When executing a compiled agent with SubAgentTools, pass the LLM at runtime:

      compiled.execute.(%{topic: "cats"}, llm: runtime_llm)

  ## Runtime Options

  The `execute` function accepts optional keyword arguments:

  - `llm` - Required if agent has SubAgentTools. LLM for child agents.
  - `llm_registry` - Map of atom to LLM functions (if SubAgentTools use atom LLMs)
  - `_nesting_depth` - Inherited context depth (used when nested in another agent)
  - `_remaining_turns` - Inherited turn budget
  - `_mission_deadline` - Inherited mission deadline

  See `SubAgent.compile/2` for compilation details.

  ## Fields

  - `source` - Inspectable PTC-Lisp source code (String)
  - `signature` - Functional contract copied from agent (String)
  - `execute` - Pre-bound executor function `(map(), keyword() -> result)`
  - `metadata` - Compilation metadata (see `t:metadata/0`)
  - `field_descriptions` - Descriptions for signature fields (Map, optional)
  - `llm_required?` - Whether the agent requires an LLM at runtime

  ## Examples

  Compile and execute:

      iex> tools = %{"double" => fn %{"n" => n} -> n * 2 end}
      iex> agent = PtcRunner.SubAgent.new(
      ...>   prompt: "Double the input number {{n}}",
      ...>   signature: "(n :int) -> {result :int}",
      ...>   tools: tools,
      ...>   max_turns: 1
      ...> )
      iex> mock_llm = fn _ -> {:ok, ~S|(return {:result (tool/double {:n data/n})})|} end
      iex> {:ok, compiled} = PtcRunner.SubAgent.compile(agent, llm: mock_llm, sample: %{n: 5})
      iex> compiled.signature
      "(n :int) -> {result :int}"
      iex> compiled.source
      ~S|(return {:result (tool/double {:n data/n})})|
      iex> compiled.llm_required?
      false
      iex> result = compiled.execute.(%{n: 10}, [])
      iex> result.return.result
      20
  """

  @typedoc """
  Metadata captured during compilation.

  Fields:
  - `compiled_at` - UTC timestamp when compilation completed
  - `tokens_used` - Total tokens consumed during compilation
  - `turns` - Number of LLM turns used during compilation
  - `llm_model` - Model identifier if available from LLM response
  """
  @type metadata :: %{
          compiled_at: DateTime.t(),
          tokens_used: non_neg_integer(),
          turns: pos_integer(),
          llm_model: String.t() | nil
        }

  @typedoc """
  CompiledAgent struct.

  Fields:
  - `source` - PTC-Lisp program source code
  - `signature` - Type signature for inputs/outputs
  - `execute` - Function that executes the program `(map(), keyword() -> Step.t())`
  - `metadata` - Compilation metadata
  - `field_descriptions` - Descriptions for signature fields
  - `llm_required?` - Whether the agent requires an LLM at runtime
  """
  @type t :: %__MODULE__{
          source: String.t(),
          signature: String.t() | nil,
          execute: (map(), keyword() -> PtcRunner.Step.t()),
          metadata: metadata(),
          field_descriptions: map() | nil,
          llm_required?: boolean()
        }

  defstruct [
    :source,
    :signature,
    :execute,
    :metadata,
    :field_descriptions,
    llm_required?: false
  ]

  @doc """
  Wraps a compiled agent as a callable tool.

  The resulting tool can be used in parent agents. When called, it executes
  the compiled PTC-Lisp program without making any LLM calls.

  Note: The returned tool has a 1-arity execute function for compatibility with
  dynamic agents. Compiled agents with SubAgentTools should not be used as tools
  in dynamic agents (they require runtime LLM options that can't be passed through
  the 1-arity interface).

  ## Examples

      iex> tools = %{"double" => fn %{"n" => n} -> n * 2 end}
      iex> agent = PtcRunner.SubAgent.new(
      ...>   prompt: "Double {{n}}",
      ...>   signature: "(n :int) -> {result :int}",
      ...>   tools: tools,
      ...>   max_turns: 1
      ...> )
      iex> mock_llm = fn _ -> {:ok, ~S|(return {:result (tool/double {:n data/n})})|} end
      iex> {:ok, compiled} = PtcRunner.SubAgent.compile(agent, llm: mock_llm, sample: %{n: 1})
      iex> tool = PtcRunner.SubAgent.CompiledAgent.as_tool(compiled)
      iex> tool.type
      :compiled
      iex> result = tool.execute.(%{n: 5})
      iex> result.return.result
      10
  """
  @spec as_tool(t()) :: %{
          type: :compiled,
          execute: (map() -> PtcRunner.Step.t()),
          signature: String.t() | nil
        }
  def as_tool(%__MODULE__{execute: execute, signature: signature, llm_required?: llm_required}) do
    # Wrap 2-arity execute in 1-arity for compatibility with dynamic agents
    # Note: Compiled agents with SubAgentTools will fail if used this way
    # because they require llm option that can't be passed through 1-arity
    wrapped_execute = fn args ->
      if llm_required do
        raise ArgumentError,
              "CompiledAgent with SubAgentTools cannot be used as a tool in dynamic agents. " <>
                "Use compiled.execute.(args, llm: llm) directly or compile the parent agent too."
      end

      execute.(args, [])
    end

    %{
      type: :compiled,
      execute: wrapped_execute,
      signature: signature
    }
  end
end
