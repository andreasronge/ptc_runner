defmodule PtcRunner.SubAgent.Loop.ToolNormalizer do
  @moduledoc """
  Tool preparation and wrapping for SubAgent execution.

  This module normalizes tools from various formats into executable functions
  and wraps them with telemetry events for observability.

  ## Tool Types

  - `SubAgentTool` - Wrapped child agents that inherit context and limits
  - Function/1 - Direct tool functions that receive args map
  - Other values - Passed through unchanged

  ## Wrapping Behavior

  Tool functions are wrapped to:
  1. Handle return value normalization (`{:ok, value}`, `{:error, reason}`, or raw values)
  2. Emit telemetry events on tool start/stop
  3. Inherit runtime context for nested SubAgents
  """

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.{SubAgentTool, Telemetry}

  @doc """
  Normalize tools map to convert SubAgentTool instances into executable functions.

  Each tool is wrapped with telemetry events and return value normalization.

  ## Parameters

  - `tools` - Map of tool name to tool definition
  - `state` - Current loop state (for context inheritance)
  - `agent` - Parent agent (for telemetry metadata)

  ## Returns

  Map of tool names to wrapped executable functions.
  """
  @spec normalize(map(), map(), SubAgent.t()) :: map()
  def normalize(tools, state, agent) when is_map(tools) do
    Map.new(tools, fn
      {name, %SubAgentTool{} = tool} ->
        wrapped = wrap_sub_agent_tool(tool, state)
        {name, wrap_with_telemetry(name, wrapped, agent)}

      {name, func} when is_function(func, 1) ->
        wrapped = wrap_return(func)
        {name, wrap_with_telemetry(name, wrapped, agent)}

      {name, other} ->
        {name, other}
    end)
  end

  @doc """
  Wrap a tool function with telemetry events.

  Emits `[:sub_agent, :tool, :start]` and `[:sub_agent, :tool, :stop]` events.
  """
  @spec wrap_with_telemetry(String.t(), function(), SubAgent.t()) :: function()
  def wrap_with_telemetry(name, func, agent) do
    fn args ->
      start_meta = %{agent: agent, tool_name: name, args: args}

      Telemetry.span([:tool], start_meta, fn ->
        result = func.(args)
        {result, %{agent: agent, tool_name: name, result: result}}
      end)
    end
  end

  @doc """
  Wrap a regular tool function to handle various return formats.

  Converts:
  - `{:ok, value}` -> `value`
  - `{:error, reason}` -> raises with error message
  - `value` -> `value` (pass-through)
  """
  @spec wrap_return(function()) :: function()
  def wrap_return(func) do
    fn args ->
      case func.(args) do
        {:ok, value} -> value
        {:error, reason} -> raise "Tool error: #{inspect(reason)}"
        value -> value
      end
    end
  end

  @doc """
  Wrap a SubAgentTool in a function closure that executes the child agent.

  The wrapped function:
  - Resolves LLM in priority order: agent.llm > bound_llm > parent's llm
  - Inherits llm_registry, nesting_depth, remaining_turns, and mission_deadline
  - Returns the child agent's return value or raises on failure
  """
  @spec wrap_sub_agent_tool(SubAgentTool.t(), map()) :: function()
  def wrap_sub_agent_tool(%SubAgentTool{} = tool, state) do
    fn args ->
      # Resolve LLM in priority order: agent.llm > bound_llm > parent's llm
      resolved_llm = tool.agent.llm || tool.bound_llm || state.llm

      unless resolved_llm do
        raise ArgumentError, "No LLM available for SubAgentTool execution"
      end

      # Execute the wrapped agent with inherited context
      case SubAgent.run(tool.agent,
             llm: resolved_llm,
             llm_registry: state.llm_registry,
             context: args,
             _nesting_depth: state.nesting_depth + 1,
             _remaining_turns: state.remaining_turns,
             _mission_deadline: state.mission_deadline
           ) do
        {:ok, step} ->
          step.return

        {:error, step} ->
          # Propagate child agent failure
          raise RuntimeError,
                "SubAgent tool failed: #{step.fail.message}"
      end
    end
  end
end
