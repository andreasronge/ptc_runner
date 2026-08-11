defmodule PtcRunner.Kernel.ToolGrant do
  @moduledoc """
  Builds the capability callbacks handed to a sandboxed evaluation.

  Every callback here is copied into the sandbox process, and that copy is
  **flat** — `spawn` does not preserve sharing. A callback must therefore close
  over only what it reads. `Dispatcher.dispatch/8` resolves one name, so each
  capability callback carries one capability via
  `PtcRunner.Kernel.Environment.capability_view/2`; only the runtime discovery
  routes carry the whole map, via `capability_view/1`.

  The cost of getting this wrong is not linear. A term every callback captures
  is copied once per callback, so capturing anything environment-sized makes
  the hand-over `O(capabilities²)` — enough for a tool-rich MCP environment to
  blow the sandbox setup ceiling before the program runs, and enough for a
  modest environment to eat the program's whole heap budget through the
  measured baseline. `PtcRunner.Sandbox` documents how that baseline is billed.

  Size a grant with `:erts_debug.flat_size` (plus referenced binaries for byte
  units); that is what the sandbox's own baseline measurement bills.
  """

  alias PtcRunner.Kernel.Dispatcher
  alias PtcRunner.Kernel.Environment
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.RuntimeTools

  @doc """
  Returns the capability dispatch callbacks plus reserved runtime routes for
  one environment.

  Callers add their own environment-specific routes (`kernel-eval`, the
  workflow inventory routes, `TrustedTool` wrapping) to the result.
  """
  @spec capability_callbacks(
          term(),
          :workflow | :mission,
          map(),
          %{
            timeout_ms: non_neg_integer(),
            validation_heap_words: pos_integer(),
            evaluation_lease: reference() | nil,
            validation_deadline_ms: integer() | nil
          },
          term(),
          term()
        ) :: %{binary() => (map() -> map())}
  def capability_callbacks(
        state,
        kind,
        environment,
        dispatch_context,
        event_sink,
        inspection_sink
      )
      when kind in [:workflow, :mission] and is_map(dispatch_context) do
    build_callbacks(
      state,
      kind,
      environment,
      dispatch_context,
      event_sink,
      inspection_sink
    )
  end

  @doc false
  def capability_callbacks(
        state,
        kind,
        environment,
        timeout_ms,
        event_sink,
        inspection_sink
      )
      when kind in [:workflow, :mission] and is_integer(timeout_ms) do
    capability_callbacks(state, kind, environment, timeout_ms, event_sink, inspection_sink, [])
  end

  @doc false
  def capability_callbacks(
        state,
        kind,
        environment,
        timeout_ms,
        event_sink,
        inspection_sink,
        opts
      )
      when kind in [:workflow, :mission] and is_integer(timeout_ms) and is_list(opts) do
    # Mission grants carry the lease of the evaluation constructing them, so
    # a call surviving that evaluation's death is rejected as stale instead
    # of being attributed to the next admitted evaluation.
    lease = Keyword.get(opts, :lease)
    limits = RunState.limits(state)

    build_callbacks(
      state,
      kind,
      environment,
      %{
        timeout_ms: timeout_ms,
        validation_heap_words: validation_heap_words(limits, kind),
        evaluation_lease: lease,
        validation_deadline_ms: nil
      },
      event_sink,
      inspection_sink
    )
  end

  defp build_callbacks(
         state,
         kind,
         environment,
         dispatch_context,
         event_sink,
         inspection_sink
       ) do
    environment.capabilities
    |> Map.new(fn {name, capability} ->
      view = Environment.capability_view(name, capability)

      callback = fn arguments ->
        Dispatcher.dispatch(
          state,
          kind,
          view,
          name,
          arguments,
          dispatch_context,
          event_sink,
          inspection_sink
        )
      end

      {name, callback}
    end)
    |> Map.merge(
      RuntimeTools.tools(state, environment, event_sink, kind,
        lease: dispatch_context.evaluation_lease
      )
    )
  end

  defp validation_heap_words(limits, :workflow), do: limits.workflow_heap_words
  defp validation_heap_words(limits, :mission), do: limits.evaluation_heap_words
end
