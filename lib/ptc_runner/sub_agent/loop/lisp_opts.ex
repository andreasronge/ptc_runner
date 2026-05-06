defmodule PtcRunner.SubAgent.Loop.LispOpts do
  @moduledoc """
  Shared builder for `PtcRunner.Lisp.run/2` opts across every loop transport.

  Single source of truth: all three transports — the `:content` path in
  `PtcRunner.SubAgent.Loop`, the `:tool_call` path in
  `PtcRunner.SubAgent.Loop.PtcToolCall`, and combined-mode
  `ptc_lisp_execute` dispatch in `PtcRunner.SubAgent.Loop.TextMode` —
  build their `Lisp.run/2` opts here. Past divergence between the
  copies (see issue #874) was a real bug class; resolving it requires
  one builder, not coordinated edits across three.

  Per-transport defaults that don't fit the universal shape
  (e.g. combined mode wanting `memory` and `tool_cache` to default to
  `%{}` rather than `nil`) belong in the call site — normalize the
  `state` you pass in, don't fork the builder.
  """

  alias PtcRunner.SubAgent.Loop.Budget

  @doc """
  Build the `Lisp.run/2` opts list.

  Reads from `agent` and `state` and emits the canonical 14-key
  keyword list, optionally appending `:max_heap` and `:max_tool_calls`
  when set.
  """
  @spec build(agent :: map(), state :: map(), exec_context :: map(), tools :: term()) ::
          keyword()
  def build(agent, state, exec_context, tools) do
    [
      context: exec_context,
      memory: state.memory,
      tools: tools,
      turn_history: state.turn_history,
      float_precision: agent.float_precision,
      max_print_length: Keyword.get(agent.format_options, :max_print_length),
      timeout: agent.timeout,
      pmap_timeout: agent.pmap_timeout,
      pmap_max_concurrency: agent.pmap_max_concurrency,
      budget: Budget.build_introspection_map(agent, state),
      trace_context: state.trace_context,
      journal: state.journal,
      tool_cache: state.tool_cache
    ]
    |> maybe_put(:max_heap, state.max_heap)
    |> maybe_put(:max_tool_calls, agent.max_tool_calls)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
