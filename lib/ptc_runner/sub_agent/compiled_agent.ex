defmodule PtcRunner.SubAgent.CompiledAgent do
  @moduledoc """
  A compiled SubAgent that executes without LLM calls.

  Created by `SubAgent.compile/2`, a CompiledAgent stores the PTC-Lisp program
  derived once by an LLM and can execute it many times without further LLM calls.

  ## Use Case

  Useful for agents with deterministic tools that process many items identically:
  - Data validation (run LLM once to derive rules, validate thousands of records)
  - Batch processing (compile logic once, process entire dataset)
  - High-throughput scenarios where LLM cost/latency is prohibitive

  ## Compilation Flow

  1. Call `SubAgent.compile/2` with sample data
  2. LLM runs once to derive PTC-Lisp logic
  3. Program is extracted and stored in `source`
  4. Execute via `compiled.execute(args)` - no LLM needed

  ## Limitations

  - Only agents with pure (non-LLM) tools can be compiled
  - Compiled programs are not serializable to disk
  - No automatic recompilation when tools change
  - Compilation uses LLM once; execution never uses LLM

  ## Fields

  - `source` - The PTC-Lisp program as a string
  - `signature` - Type signature from the original agent
  - `execute` - Function `(map() -> {:ok, Step.t()} | {:error, Step.t()})` that runs the program
  - `metadata` - Compilation metrics and provenance

  ## Examples

      # Compile an agent once
      agent = SubAgent.new(
        prompt: "Score {{report}} for anomalies",
        signature: "(report :map) -> {score :float}",
        tools: %{"threshold" => &lookup_threshold/1}
      )

      {:ok, compiled} = SubAgent.compile(agent,
        llm: :sonnet,
        llm_registry: registry,
        sample: %{report: sample_data}
      )

      # Inspect the derived program
      IO.puts(compiled.source)
      #=> (let [t (call "threshold" {:type ctx/report.type})]
      #=>   {:score (if (> ctx/report.value t) 0.9 0.1)})

      # Execute many times without LLM
      results = Enum.map(reports, fn r ->
        compiled.execute(%{report: r})
      end)
  """

  alias PtcRunner.Step

  defstruct [:source, :signature, :execute, :metadata]

  @typedoc """
  Compilation metadata for debugging and tracking.

  Fields:
  - `compiled_at` - When compilation occurred
  - `tokens_used` - Total tokens from compilation LLM call
  - `turns` - Number of LLM turns during compilation
  - `llm_model` - LLM model name if available
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
  - `signature` - Type signature (nil if not provided)
  - `execute` - Function that runs the program: `(map() -> {:ok, Step.t()} | {:error, Step.t()})`
  - `metadata` - Compilation provenance and metrics
  """
  @type t :: %__MODULE__{
          source: String.t(),
          signature: String.t() | nil,
          execute: (map() -> {:ok, Step.t()} | {:error, Step.t()}),
          metadata: metadata()
        }

  @doc """
  Wraps a CompiledAgent as a tool callable by other agents.

  The returned tool can be included in parent agents' tool maps. When called,
  it executes the compiled program directly without any LLM calls.

  ## Returns

  A map with:
  - `type: :compiled` - Marker for compiled agent tools
  - `execute` - Function that executes the compiled program
  - `signature` - Type signature from the original agent

  ## Examples

  See test/ptc_runner/sub_agent/compiled_agent_test.exs for usage examples.

  """
  @spec as_tool(t()) :: %{type: :compiled, execute: function(), signature: String.t() | nil}
  def as_tool(%__MODULE__{execute: execute, signature: signature}) do
    %{
      type: :compiled,
      execute: execute,
      signature: signature
    }
  end
end
