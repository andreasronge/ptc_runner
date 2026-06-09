defmodule PtcRunner.Upstream.SideEffectGuard do
  @moduledoc false

  alias PtcRunner.Step
  alias PtcRunner.SubAgent.Loop.StepAssembler
  alias PtcRunner.Upstream.Effect

  @spec default(struct() | pid()) ::
          (PtcRunner.Turn.t(), struct(), struct() -> :continue | {:stop, {:error, Step.t()}})
  def default(runtime) do
    fn turn, _state, next_state ->
      case non_read_upstream_calls(runtime, turn.tool_calls || []) do
        [] ->
          :continue

        [%{server: server, tool: tool, effect: effect} | _] = matched_calls ->
          duration_ms = System.monotonic_time(:millisecond) - next_state.start_time

          message =
            "stopped before continuation after upstream tool #{server}/#{tool} " <>
              "reported #{effect} side-effect classification"

          step =
            :partial_side_effects
            |> Step.error(message, next_state.memory, %{matched_calls: matched_calls})
            |> StepAssembler.finalize(next_state,
              duration_ms: duration_ms,
              turn_offset: -1,
              is_error: true,
              journal: next_state.journal,
              child_steps: next_state.child_steps
            )

          {:stop, {:error, step}}
      end
    end
  end

  defp non_read_upstream_calls(runtime, tool_calls) do
    Enum.flat_map(tool_calls, fn
      %{name: "call", args: args} when is_map(args) ->
        server = string_key(args, "server")
        tool = string_key(args, "tool")
        effect = Effect.classify(runtime, server, tool)

        if effect == :read do
          []
        else
          [%{server: server, tool: tool, effect: effect}]
        end

      _other ->
        []
    end)
  end

  defp string_key(map, "server"), do: Map.get(map, "server") || Map.get(map, :server)
  defp string_key(map, "tool"), do: Map.get(map, "tool") || Map.get(map, :tool)
end
