defmodule PtcRunner.SubAgent.SubAgentTool do
  @moduledoc """
  Wraps a SubAgent as a callable tool for parent agents.

  Created via `SubAgent.as_tool/2`, this struct allows agents to be
  composed and nested. When a parent agent calls a SubAgentTool,
  the wrapped agent executes with inherited LLM and registry.

  ## LLM Resolution Order

  When a SubAgentTool is called, the LLM is resolved in this priority order:

  1. `agent.llm` - Agent's own LLM override (highest priority)
  2. `bound_llm` - LLM bound at tool creation via `as_tool/2`
  3. Parent's llm - Inherited from the calling agent at call time (lowest priority)

  This allows flexible composition where child agents can use their own LLM,
  inherit from the parent, or use a specifically bound LLM.

  ## Fields

  - `agent` - The `SubAgent.t()` to wrap as a tool
  - `bound_llm` - Optional LLM (atom or function) bound at tool creation
  - `signature` - Type signature (copied from agent.signature)
  - `description` - Optional description (defaults to agent's prompt)
  """

  defstruct [:agent, :bound_llm, :signature, :description]

  @type t :: %__MODULE__{
          agent: PtcRunner.SubAgent.t(),
          bound_llm: atom() | (map() -> {:ok, String.t()} | {:error, term()}) | nil,
          signature: String.t() | nil,
          description: String.t() | nil
        }
end
