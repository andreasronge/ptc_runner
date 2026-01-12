defmodule PtcRunner.SubAgent.CompiledAgent do
  @moduledoc """
  A compiled SubAgent with pre-derived PTC-Lisp logic.

  Created via `SubAgent.compile/2`, this struct stores PTC-Lisp code derived
  once by an LLM. The compiled agent can then be executed many times without
  further LLM calls, making it efficient for processing many items with
  deterministic logic.

  ## Use Cases

  - Processing batch data with consistent logic (e.g., scoring reports)
  - Agents with pure tools that don't require LLM decisions at runtime
  - Workflows where the logic is derived once and reused many times

  ## Limitations

  CompiledAgents can only use pure Elixir tools. They cannot include:
  - `LLMTool` - requires LLM at execution time
  - `SubAgentTool` - requires LLM at execution time

  See `SubAgent.compile/2` for compilation details.

  ## Fields

  - `source` - Inspectable PTC-Lisp source code (String)
  - `signature` - Functional contract copied from agent (String)
  - `execute` - Pre-bound executor function `(map() -> result)`
  - `metadata` - Compilation metadata (see `t:metadata/0`)
  - `field_descriptions` - Descriptions for signature fields (Map, optional)

  ## Examples

  Compile and execute:

      iex> tools = %{"double" => fn %{n: n} -> n * 2 end}
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
      iex> result = compiled.execute.(%{n: 10})
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
  - `execute` - Function that executes the program `(map() -> Step.t())`
  - `metadata` - Compilation metadata
  - `field_descriptions` - Descriptions for signature fields
  """
  @type t :: %__MODULE__{
          source: String.t(),
          signature: String.t() | nil,
          execute: (map() -> PtcRunner.Step.t()),
          metadata: metadata(),
          field_descriptions: map() | nil
        }

  defstruct [:source, :signature, :execute, :metadata, :field_descriptions]

  @doc """
  Wraps a compiled agent as a callable tool.

  The resulting tool can be used in parent agents. When called, it executes
  the compiled PTC-Lisp program without making any LLM calls.

  ## Examples

      iex> tools = %{"double" => fn %{n: n} -> n * 2 end}
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
  def as_tool(%__MODULE__{execute: execute, signature: signature}) do
    %{
      type: :compiled,
      execute: execute,
      signature: signature
    }
  end
end
