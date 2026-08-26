defmodule PtcRunner.Kernel.ExecutionOutcomeTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.CommandPath
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.Error
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.ExecutionOutcome
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.Result
  alias PtcRunner.Kernel.ValueContract
  alias PtcRunner.Lisp.Format.SymbolRef
  alias PtcRunner.TestSupport.StreamingInspection

  setup do
    {:ok, limits} = Limits.new([])
    {:ok, authority} = PublicationAuthority.new([])
    {:ok, limits: limits, authority: authority}
  end

  test "captures normal and private publication authority", %{
    limits: limits,
    authority: authority
  } do
    for policy <- [:normal, :private] do
      {:ok, sink} = EventSink.start(policy, limits)

      assert {:ok, outcome} =
               ExecutionOutcome.capture(result(), {:ok, []}, sink, nil, nil, nil, authority)

      assert ExecutionOutcome.valid?(outcome)
      assert open!(outcome, authority).result_class == policy
      assert open!(outcome, authority).inspection == :disabled
      assert :ok = EventSink.stop(sink)
    end
  end

  test "an unreachable event sink fails closed", %{limits: limits, authority: authority} do
    {:ok, sink} = EventSink.start(:normal, limits)
    assert :ok = EventSink.stop(sink)

    assert {:ok, outcome} =
             ExecutionOutcome.capture(
               error_result(),
               {:error, :event_sink_error},
               sink,
               nil,
               nil,
               nil,
               authority
             )

    assert open!(outcome, authority).result_class == :private
  end

  test "rejects a successful result with a failed terminal event batch", %{
    limits: limits,
    authority: authority
  } do
    {:ok, sink} = EventSink.start(:normal, limits)

    assert {:error, :invalid_execution_outcome} =
             ExecutionOutcome.capture(
               result(),
               {:error, :event_sink_error},
               sink,
               nil,
               nil,
               nil,
               authority
             )

    assert :ok = EventSink.stop(sink)
  end

  test "seals inspection evidence while its sink is live", %{
    limits: limits,
    authority: authority
  } do
    {:ok, sink} = EventSink.start(:private, limits)

    {:ok, inspection} =
      StreamingInspection.start(
        run_id: "outcome-inspection",
        trace_id: "outcome-inspection"
      )

    assert {:ok, outcome} =
             ExecutionOutcome.capture(result(), {:ok, []}, sink, inspection, nil, nil, authority)

    assert {:ok, %{record_count: 0}} = open!(outcome, authority).inspection
    assert :ok = InspectionSink.stop(inspection)
    assert :ok = EventSink.stop(sink)
    assert {:ok, %{record_count: 0}} = open!(outcome, authority).inspection
  end

  test "captures one strict-JSON terminal result in the inspection sink", %{
    limits: limits,
    authority: authority
  } do
    value = %{"answer" => 42}
    result_hash = result_hash(value)
    {:ok, sink} = EventSink.start(:private, limits)

    {:ok, inspection} =
      StreamingInspection.start(
        run_id: "outcome-result",
        trace_id: "trace-outcome-result"
      )

    terminal_batch =
      {:ok,
       [
         %{
           "run_id" => "outcome-result",
           "trace_id" => "trace-outcome-result",
           "type" => "run-stopped",
           "data" => %{"outcome" => "ok", "result_hash" => result_hash}
         }
       ]}

    assert {:ok, outcome} =
             ExecutionOutcome.capture(
               result(value),
               terminal_batch,
               sink,
               inspection,
               nil,
               nil,
               authority
             )

    assert {:ok, %{record_count: 1}} = open!(outcome, authority).inspection
    assert {:ok, [record]} = StreamingInspection.records(inspection)
    assert record["record_type"] == "run-result"
    assert record["correlation"] == %{}
    assert record["payload"] == %{"result_hash" => result_hash, "value" => value}

    assert :ok = InspectionSink.stop(inspection)
    assert :ok = EventSink.stop(sink)
  end

  test "does not emit run results for hashable native non-JSON values", %{
    limits: limits,
    authority: authority
  } do
    value = %SymbolRef{name: "answer"}
    result_hash = result_hash(value)
    {:ok, sink} = EventSink.start(:private, limits)

    {:ok, inspection} =
      StreamingInspection.start(
        run_id: "outcome-native",
        trace_id: "trace-outcome-native"
      )

    terminal_batch =
      {:ok,
       [
         %{
           "type" => "run-stopped",
           "data" => %{"outcome" => "ok", "result_hash" => result_hash}
         }
       ]}

    assert {:ok, outcome} =
             ExecutionOutcome.capture(
               result(value),
               terminal_batch,
               sink,
               inspection,
               nil,
               nil,
               authority
             )

    assert {:ok, %{record_count: 0}} = open!(outcome, authority).inspection
    assert :ok = InspectionSink.stop(inspection)
    assert :ok = EventSink.stop(sink)
  end

  test "captures result-contract decisions", %{limits: limits, authority: authority} do
    {:ok, sink} = EventSink.start(:normal, limits)

    {:ok, contract} =
      ValueContract.compile(%{
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["answer"],
        "properties" => %{"answer" => %{"type" => "integer"}}
      })

    assert {:ok, accepted} =
             ExecutionOutcome.capture(
               result(%{"answer" => 42}),
               {:ok, []},
               sink,
               nil,
               contract,
               "result.schema.json",
               authority
             )

    assert open!(accepted, authority).result_contract == :ok

    assert {:ok, rejected} =
             ExecutionOutcome.capture(
               result(%{"answer" => "wrong"}),
               {:ok, []},
               sink,
               nil,
               contract,
               "result.schema.json",
               authority
             )

    assert {:error, {:result_contract_failed, details}} =
             open!(rejected, authority).result_contract

    assert details.contract_source == "result.schema.json"
    assert [%{kind: :type, path: path}] = details.violations
    assert CommandPath.to_pointer(path) == "/answer"
    assert :ok = EventSink.stop(sink)
  end

  test "rejects a non-portable result-contract source", %{
    limits: limits,
    authority: authority
  } do
    {:ok, sink} = EventSink.start(:normal, limits)

    {:ok, contract} =
      ValueContract.compile(%{
        "type" => "object",
        "properties" => %{"answer" => %{"type" => "integer"}}
      })

    assert {:error, :invalid_execution_outcome} =
             ExecutionOutcome.capture(
               result(),
               {:ok, []},
               sink,
               nil,
               contract,
               "../private/result.schema.json",
               authority
             )

    assert :ok = EventSink.stop(sink)
  end

  test "rejects field and nested evidence mutation", %{limits: limits, authority: authority} do
    {:ok, sink} = EventSink.start(:private, limits)

    assert {:ok, outcome} =
             ExecutionOutcome.capture(
               result(),
               {:ok, [%{sequence: 1}]},
               sink,
               nil,
               nil,
               nil,
               authority
             )

    refute ExecutionOutcome.valid?(Map.put(outcome, :result_class, :normal))
    refute ExecutionOutcome.valid?(Map.put(outcome, :unexpected, true))

    tampered_events =
      outcome
      |> open!(authority)
      |> Map.fetch!(:terminal_batch)
      |> then(fn {:ok, events} -> {:ok, [%{sequence: 2} | events]} end)

    refute ExecutionOutcome.valid?(Map.put(outcome, :terminal_batch, tampered_events))
    assert :ok = EventSink.stop(sink)
  end

  test "opens all authorized publication evidence with one outcome validation", %{
    limits: limits,
    authority: authority
  } do
    {:ok, sink} = EventSink.start(:normal, limits)

    assert {:ok, outcome} =
             ExecutionOutcome.capture(
               result(),
               {:ok, [%{sequence: 1}]},
               sink,
               nil,
               nil,
               nil,
               authority
             )

    Code.ensure_loaded!(ExecutionOutcome)
    assert :erlang.trace_pattern({ExecutionOutcome, :valid?, 1}, true, [:local]) == 1
    test = self()
    tracer = spawn_link(fn -> validation_trace_loop(test, 0) end)
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      assert {:ok,
              %{
                result: {:ok, %Result{value: %{"answer" => 42}}},
                result_class: :normal,
                result_contract: :ok,
                terminal_batch: {:ok, [%{sequence: 1}]},
                inspection: :disabled
              }} = ExecutionOutcome.open(outcome, authority)

      tracee = self()
      reference = :erlang.trace_delivered(tracee)
      assert_receive {:trace_delivered, ^tracee, ^reference}
      send(tracer, :count)
      assert_receive {:validation_call_count, 1}
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({ExecutionOutcome, :valid?, 1}, false, [:local])
      send(tracer, :stop)
      EventSink.stop(sink)
    end
  end

  test "publication authority rejects malformed keyword lists" do
    assert {:error, :invalid_publication_authority} = PublicationAuthority.new([:trace])
    assert {:error, :invalid_publication_authority} = PublicationAuthority.new([1])
  end

  defp validation_trace_loop(test, count) do
    receive do
      {:trace, _pid, :call, {ExecutionOutcome, :valid?, [_outcome]}} ->
        validation_trace_loop(test, count + 1)

      :count ->
        send(test, {:validation_call_count, count})
        validation_trace_loop(test, count)

      :stop ->
        :ok
    end
  end

  defp open!(outcome, authority) do
    {:ok, evidence} = ExecutionOutcome.open(outcome, authority)
    evidence
  end

  defp result(value \\ %{"answer" => 42}) do
    {:ok, %Result{value: value, usage: %{}, evaluation_memory: %{}}}
  end

  defp error_result do
    {:error, %Error{kind: :event_sink_error, reason: :event_sink_error, details: %{}, usage: %{}}}
  end

  defp result_hash(value) do
    {:ok, encoded} = DeterministicJSON.encode(value)
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, encoded), case: :lower)
  end
end
