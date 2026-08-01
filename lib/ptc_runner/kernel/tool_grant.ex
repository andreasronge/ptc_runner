defmodule PtcRunner.Kernel.ToolGrant do
  @moduledoc """
  Builds the capability callbacks handed to a sandboxed evaluation.

  Every callback here is copied into the sandbox process, and that copy is
  **flat** — `spawn` does not preserve sharing. A callback must therefore close
  over only what it reads. `Dispatcher.dispatch/7` resolves one name, so each
  capability callback carries one capability; only the two discovery routes
  carry the whole map.

  The cost of getting this wrong is not linear. A term every callback captures
  is copied once per callback, so capturing anything environment-sized makes
  the hand-over `O(capabilities²)` — enough for a tool-rich MCP environment to
  blow the sandbox setup ceiling before the program runs, and enough for a
  modest environment to eat the program's whole heap budget through the
  measured baseline. `PtcRunner.Sandbox` documents how that baseline is billed.

  Size the grant with `PtcRunner.Lisp.RetainedSize.bytes/1`; it counts flat
  heap words plus referenced binaries, which is what the sandbox bills.
  """

  alias PtcRunner.Kernel.Dispatcher
  alias PtcRunner.Kernel.Environment
  alias PtcRunner.Kernel.RuntimeTools

  @typedoc "Per-evaluation capture wiring shared by every callback in a grant."
  @type context :: %{
          required(:event_sink) => term(),
          required(:inspection_sink) => term(),
          required(:evaluation_id) => binary() | nil
        }

  @doc """
  Returns the capability callbacks plus reserved runtime routes for one
  environment.

  Callers add their own environment-specific routes (`kernel-eval` and the
  workflow inventory routes) to the result.
  """
  @spec capability_callbacks(
          term(),
          :workflow | :mission,
          map(),
          non_neg_integer(),
          context()
        ) :: %{binary() => (map() -> map())}
  def capability_callbacks(state, kind, environment, timeout_ms, context)
      when kind in [:workflow, :mission] and is_integer(timeout_ms) and is_map(context) do
    environment.capabilities
    |> Map.new(fn {name, capability} ->
      view = Environment.capability_view(name, capability)

      {name,
       fn arguments ->
         Dispatcher.dispatch(state, kind, view, name, arguments, timeout_ms, context)
       end}
    end)
    |> Map.merge(
      RuntimeTools.tools(
        state,
        Environment.capability_view(environment),
        context.event_sink,
        kind,
        context.evaluation_id
      )
    )
  end
end
