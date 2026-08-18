defmodule PtcRunner.Kernel.RuntimeToolsTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Direct coverage of the trusted runtime-limit callback.

  The route is private to the shipped `agent.core` namespace, so a component
  test cannot reach the argument validation — the grant refuses the call before
  the arguments are read. These exercise the closed reason set itself.
  """

  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.RuntimeLimitDiagnostic
  alias PtcRunner.Kernel.RuntimeTools
  alias PtcRunner.Lisp.TrustedError

  setup do
    {:ok, limits} = Limits.new()
    # The run state is linked to the test process, so it goes away with it.
    {:ok, state} = RunState.start(limits)
    %{callback: RuntimeTools.runtime_limit_failure(state, limits)}
  end

  test "every closed reason mints its own turn-limit detail", %{callback: callback} do
    for {name, reason} <- [
          {"turn-limit-exceeded", :turn_limit_exceeded},
          {"intermediate-result", :intermediate_result},
          {"evaluation-error", :evaluation_error},
          {"protocol-error", :protocol_error},
          {"terminal-source-required", :terminal_source_required}
        ] do
      assert %TrustedError{
               reason: :runtime_limit_exceeded,
               details: %{limit: :agent_turns, limit_value: 8, limit_reason: ^reason}
             } = callback.(%{"agent_turns" => 8, "reason" => name})

      assert {:ok, _message} = RuntimeLimitDiagnostic.agent_turns_message(8, reason)
    end
  end

  test "a reason outside the closed set is refused rather than defaulted", %{callback: callback} do
    # Silently falling back to ordinary exhaustion would put the wrong
    # explanation in front of the reader, which costs more than none.
    for reason <- [
          "raise-max-turns-please",
          "protocol_error",
          "PROTOCOL-ERROR",
          "",
          :protocol_error,
          nil,
          7
        ] do
      assert %{status: :error, kind: :protocol_error, reason: :invalid_runtime_limit_failure} =
               callback.(%{"agent_turns" => 8, "reason" => reason}),
             "accepted #{inspect(reason)}"
    end
  end

  test "the reason is required, and so are the bounds on the turn count", %{callback: callback} do
    invalid = [
      %{"agent_turns" => 8},
      %{"agent_turns" => 0, "reason" => "protocol-error"},
      %{"agent_turns" => 129, "reason" => "protocol-error"},
      %{"agent_turns" => "8", "reason" => "protocol-error"},
      %{"agent_turns" => 8, "reason" => "protocol-error", "extra" => true},
      %{"reason" => "protocol-error"}
    ]

    for arguments <- invalid do
      assert %{status: :error, kind: :protocol_error, reason: :invalid_runtime_limit_failure} =
               callback.(arguments),
             "accepted #{inspect(arguments)}"
    end
  end

  test "an unproven subordinate-evaluation claim is still refused", %{callback: callback} do
    assert %{status: :error, kind: :protocol_error, reason: :invalid_runtime_limit_failure} =
             callback.(%{"proof" => "forged-without-a-refusal"})
  end
end
