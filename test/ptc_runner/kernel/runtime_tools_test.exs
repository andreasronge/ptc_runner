defmodule PtcRunner.Kernel.RuntimeToolsTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Direct coverage of trusted runtime-tool callbacks.

  The runtime-limit route is private to the shipped `agent.core` namespace, so a
  component test cannot reach the argument validation — the grant refuses the
  call before the arguments are read. Those cases exercise the closed reason
  set itself. Instrumented capability events are the public evidence for
  reserved routes such as `workflow-annotate`.
  """

  alias PtcRunner.Kernel.AgentConfigDiagnostic
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.RuntimeLimitDiagnostic
  alias PtcRunner.Kernel.RuntimeTools
  alias PtcRunner.Kernel.SafeMetadata
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

  test "a rejected instrumented call records the closed class on capability-stopped" do
    secret = "PRIVATE_ANNOTATION_DETAIL"

    {_result, stopped} =
      instrumented_call(fn _ ->
        %{
          status: :error,
          kind: :invalid_annotation,
          reason: :invalid_workflow_annotation,
          details: secret
        }
      end)

    assert %{
             name: "workflow-annotate",
             status: :error,
             kind: :invalid_annotation,
             reason: :invalid_workflow_annotation
           } = stopped.data

    refute Map.has_key?(stopped.data, :details)
    refute inspect(stopped) =~ secret
  end

  test "a successful instrumented call does not invent a rejection class" do
    {_result, stopped} = instrumented_call(fn _ -> %{status: :ok} end)

    assert %{name: "workflow-annotate", status: :ok} = stopped.data
    refute Map.has_key?(stopped.data, :kind)
    refute Map.has_key?(stopped.data, :reason)
  end

  test "non-atom rejection fields stay off the canonical capability-stopped event" do
    {_result, stopped} =
      instrumented_call(fn _ ->
        %{status: :error, kind: "PRIVATE_KIND", reason: "PRIVATE_REASON"}
      end)

    assert %{name: "workflow-annotate", status: :error} = stopped.data
    refute Map.has_key?(stopped.data, :kind)
    refute Map.has_key?(stopped.data, :reason)
    refute inspect(stopped) =~ "PRIVATE"
  end

  test "unrecognized envelope atoms are fingerprinted rather than copied" do
    {_result, stopped} =
      instrumented_call(fn _ ->
        %{status: :error, kind: :secret_rejection_kind, reason: :secret_rejection_reason}
      end)

    assert %{name: "workflow-annotate", status: :error} = stopped.data
    refute Map.has_key?(stopped.data, :kind)
    refute Map.has_key?(stopped.data, :reason)

    assert stopped.data.kind_fingerprint ==
             SafeMetadata.fingerprint("capability-kind:secret_rejection_kind")

    assert stopped.data.reason_fingerprint ==
             SafeMetadata.fingerprint("capability-reason:secret_rejection_reason")

    refute inspect(stopped) =~ "secret_rejection"
  end

  test "kernel-agent-config-failure authors the integer and type payloads" do
    callback = RuntimeTools.agent_config_failure()

    assert %TrustedError{
             reason: :invalid_agent_config,
             details: %{option: "max_turns", min: 1, max: 128, value: 129}
           } = callback.(%{"option" => "max_turns", "min" => 1, "max" => 128, "value" => 129})

    assert %TrustedError{
             reason: :invalid_agent_config,
             details: %{option: "max_turns", min: 1, max: 128, type: :string}
           } = callback.(%{"option" => "max_turns", "min" => 1, "max" => 128, "type" => "string"})

    assert %{status: :error, reason: :invalid_agent_config_failure} =
             callback.(%{"option" => "max_turns", "min" => 1, "max" => 128, "value" => 4})

    assert %{status: :error, reason: :invalid_agent_config_failure} =
             callback.(%{"option" => "not_an_option", "min" => 1, "max" => 128, "value" => 129})

    assert {:ok, _} = AgentConfigDiagnostic.integer_message("max_turns", 1, 128, 129)
  end

  test "kernel-agent-protocol-error increments a non-limiting counter" do
    {:ok, limits} = Limits.new(protocol_errors: 2)
    {:ok, state} = RunState.start(limits)
    callback = RuntimeTools.agent_protocol_error(state)

    for _count <- 1..5 do
      assert true = callback.(%{})
    end

    usage = RunState.usage(state)
    assert usage.agent_protocol_errors == 5
    assert usage.protocol_errors == 0
    assert usage.closed? == false

    assert %{status: :error, reason: :invalid_agent_protocol_error} =
             callback.(%{"extra" => true})

    assert RunState.usage(state).agent_protocol_errors == 5
  end

  defp instrumented_call(callback) do
    {:ok, limits} = Limits.new()
    {:ok, state} = RunState.start(limits)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "runtime-tools-instrument")

    result = RuntimeTools.instrument(state, sink, :workflow, "workflow-annotate", callback).(%{})

    stopped =
      sink
      |> EventSink.events()
      |> Enum.find(&(&1.type == "capability-stopped"))

    {result, stopped}
  end
end
