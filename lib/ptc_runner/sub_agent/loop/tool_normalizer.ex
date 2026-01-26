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

  ## Trace Propagation

  When trace_context is present in state, child SubAgentTool executions receive
  a child trace context with:
  - New unique trace_id for the child's trace file
  - Parent's current span_id as parent_span_id
  - Incremented depth for visualization
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
  - Creates a child trace file when parent has tracing enabled
  - Returns the child agent's return value or raises on failure

  When trace_context is present in state, the wrapped function:
  1. Starts a new TraceLog session for the child (creating a physical trace file)
  2. Returns a special map with `__child_trace_id__` so callers can collect trace IDs
  """
  @spec wrap_sub_agent_tool(String.t(), SubAgentTool.t(), map()) :: function()
  def wrap_sub_agent_tool(name, %SubAgentTool{} = tool, state) do
    fn args ->
      # Resolve LLM in priority order: agent.llm > bound_llm > parent's llm
      resolved_llm = tool.agent.llm || tool.bound_llm || state.llm

      unless resolved_llm do
        raise ArgumentError, "No LLM available for SubAgentTool execution"
      end

      # Build run options (without trace_context - that's handled by TraceLog)
      run_opts = [
        llm: resolved_llm,
        llm_registry: state.llm_registry,
        context: args,
        _nesting_depth: state.nesting_depth + 1,
        _remaining_turns: state.remaining_turns,
        _mission_deadline: state.mission_deadline
      ]

      # If parent has tracing enabled, create a child trace file
      if has_trace_context?(state) do
        execute_with_trace(name, tool.agent, run_opts, state)
      else
        execute_without_trace(name, tool.agent, run_opts)
      end
    end
  end

  # Execute SubAgentTool with tracing - creates a child trace file
  defp execute_with_trace(name, agent, run_opts, state) do
    alias PtcRunner.TraceLog

    # Generate trace ID and determine trace file path
    child_trace_id = generate_trace_id()
    parent_trace_id = state.trace_context[:trace_id]
    trace_dir = state.trace_context[:trace_dir]
    depth = (state.trace_context[:depth] || 0) + 1

    # Build child trace path in same directory as parent
    child_path =
      if trace_dir do
        Path.join(trace_dir, "trace_#{child_trace_id}.jsonl")
      else
        nil
      end

    # Build trace options - use same directory as parent if possible
    trace_opts =
      [
        trace_id: child_trace_id,
        meta: %{
          parent_trace_id: parent_trace_id,
          depth: depth,
          tool_name: name
        }
      ]
      |> then(fn opts -> if child_path, do: Keyword.put(opts, :path, child_path), else: opts end)

    # Build child trace_context for the nested agent
    child_trace_context = %{
      trace_id: child_trace_id,
      parent_span_id: Telemetry.current_span_id(),
      depth: depth,
      trace_dir: trace_dir
    }

    run_opts_with_trace = Keyword.put(run_opts, :trace_context, child_trace_context)

    # Execute within a new trace session - this creates the physical trace file
    {:ok, result, _trace_path} =
      TraceLog.with_trace(
        fn -> SubAgent.run(agent, run_opts_with_trace) end,
        trace_opts
      )

    case result do
      {:ok, step} ->
        # Return wrapper with trace_id so callers can collect it
        %{__child_trace_id__: child_trace_id, value: step.return}

      {:error, step} ->
        # Propagate child agent failure
        raise PtcRunner.Lisp.ExecutionError,
          reason: :tool_error,
          message: name,
          data: step.fail.message
    end
  end

  # Execute SubAgentTool without tracing
  defp execute_without_trace(name, agent, run_opts) do
    case SubAgent.run(agent, run_opts) do
      {:ok, step} ->
        step.return

      {:error, step} ->
        raise PtcRunner.Lisp.ExecutionError,
          reason: :tool_error,
          message: name,
          data: step.fail.message
    end
  end

  # Check if parent state has trace_context enabled
  defp has_trace_context?(%{trace_context: %{trace_id: _}}), do: true
  defp has_trace_context?(_), do: false

  @doc """
  Build a child trace context from the parent state.

  Returns `{child_trace_context, child_trace_id}` or `{nil, nil}` if tracing
  is not enabled.

  The child trace context includes:
  - `trace_id`: New unique ID for this child's trace
  - `parent_span_id`: Current span ID from the parent (via Telemetry)
  - `depth`: Parent's depth + 1
  """
  @spec build_child_trace_context(map()) :: {map() | nil, String.t() | nil}
  def build_child_trace_context(%{trace_context: nil}), do: {nil, nil}

  def build_child_trace_context(%{trace_context: %{} = parent_ctx}) do
    child_trace_id = generate_trace_id()

    child_ctx = %{
      trace_id: child_trace_id,
      parent_span_id: Telemetry.current_span_id(),
      depth: (parent_ctx[:depth] || 0) + 1
    }

    {child_ctx, child_trace_id}
  end

  def build_child_trace_context(_state), do: {nil, nil}

  # Generate a 32-character hex trace ID
  defp generate_trace_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
