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

  alias PtcRunner.Lisp.ExecutionError
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
        wrapped = wrap_sub_agent_tool(name, tool, state)
        {name, wrap_with_telemetry(name, wrapped, agent)}

      {name, func} when is_function(func, 1) ->
        wrapped = wrap_return(name, func)
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
      start_meta = %{agent: agent, tool_name: name, args: summarize_args(args)}

      Telemetry.span([:tool], start_meta, fn ->
        result = func.(args)
        {result, %{agent: agent, tool_name: name, result: summarize_result(result)}}
      end)
    end
  end

  # Summarize args for telemetry metadata to avoid memory bloat
  # Args are typically small maps, but values can be large
  @args_size_threshold 1000
  defp summarize_args(args) when is_map(args) do
    size = :erlang.external_size(args)

    if size > @args_size_threshold do
      Map.new(args, fn {k, v} -> {k, summarize_value(v)} end)
    else
      args
    end
  end

  defp summarize_args(args), do: summarize_value(args)

  # Summarize a single value for args
  defp summarize_value(v) when is_list(v), do: "List(#{length(v)})"

  defp summarize_value(v) when is_binary(v) and byte_size(v) > 200,
    do: "String(#{byte_size(v)} bytes)"

  defp summarize_value(v) when is_map(v) and map_size(v) > 10, do: "Map(#{map_size(v)})"
  defp summarize_value(v), do: v

  # Result summarizer to avoid memory bloat in telemetry metadata
  defp summarize_result(result) when is_list(result) do
    "List(#{length(result)})"
  end

  defp summarize_result(result) when is_map(result) do
    "Map(#{map_size(result)})"
  end

  defp summarize_result(result) when is_binary(result) do
    "String(#{byte_size(result)} bytes)"
  end

  defp summarize_result(result) do
    inspect(result, limit: 3, printable_limit: 100)
  end

  @doc """
  Wrap a regular tool function to handle various return formats.

  Converts:
  - `{:ok, value}` -> `value`
  - `{:error, reason}` -> raises with error message
  - `value` -> `value` (pass-through)
  """
  @spec wrap_return(String.t(), function()) :: function()
  def wrap_return(name, func) do
    fn args ->
      case func.(args) do
        {:ok, value} ->
          value

        {:error, reason} ->
          raise ExecutionError,
            reason: :tool_error,
            message: name,
            data: reason

        value ->
          value
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
  @spec wrap_sub_agent_tool(String.t(), SubAgentTool.t(), map()) :: function()
  def wrap_sub_agent_tool(name, %SubAgentTool{} = tool, state) do
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
          raise PtcRunner.Lisp.ExecutionError,
            reason: :tool_error,
            message: name,
            data: step.fail.message
      end
    end
  end
end
