defmodule PtcRunner.Kernel.DispatcherBoundedSchemaTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.Dispatcher
  alias PtcRunner.Kernel.Evaluation
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.TestSupport.TestHelpers

  @request_schema %{
    "type" => "object",
    "properties" => %{"ok" => %{"type" => "boolean"}},
    "required" => ["ok"]
  }

  test "compiles a request schema before dispatch and admits matching output" do
    parent = self()

    {result, state, sink, _capability} =
      dispatch_request_schema(
        %{"schema" => @request_schema},
        fn arguments ->
          send(parent, {:called, arguments})
          {:ok, %{"ok" => true}}
        end
      )

    assert %{status: :ok, value: %{"ok" => true}} = result
    assert_received {:called, %{"schema" => normalized}}
    assert normalized["additionalProperties"] == false
    assert normalized["properties"]["ok"]["additionalProperties"] == nil

    assert RunState.usage(state).capability_calls.workflow[request_schema_name()] == 1

    events = EventSink.events(sink)
    assert Enum.any?(events, &(&1.type == "capability-started"))
    refute inspect(events) =~ "request_validator"
    refute Enum.any?(events, fn event -> Map.has_key?(event.data, :request_schema) end)
  end

  test "non-llm capabilities do not compile an arguments schema key" do
    parent = self()

    {:ok, capability} =
      Capability.new(
        name: "write-schema",
        effect: :read,
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "schema" => %{"type" => "object", "additionalProperties" => true}
          },
          "required" => ["schema"]
        },
        callback: fn arguments ->
          send(parent, {:called, arguments})
          {:ok, %{"ok" => true}}
        end
      )

    {result, _state, _sink} =
      dispatch_capability(capability, %{
        "schema" => %{"type" => "object", "$ref" => "#/$defs/value"}
      })

    assert %{status: :ok, value: %{"ok" => true}} = result
    assert_received {:called, %{"schema" => %{"$ref" => "#/$defs/value"}}}
  end

  test "a proven invalid request schema is invalid_arguments without dispatch" do
    parent = self()

    {result, state, sink, _capability} =
      dispatch_request_schema(
        %{"schema" => %{"type" => "object", "$ref" => "#/$defs/value"}},
        fn arguments ->
          send(parent, {:unexpected_callback, arguments})
          {:ok, %{"ok" => true}}
        end
      )

    assert %{
             status: :error,
             kind: :protocol_error,
             reason: :invalid_arguments,
             retryable?: false
           } = result

    refute_received {:unexpected_callback, _}
    assert RunState.usage(state).protocol_errors == 1
    assert RunState.usage(state).capability_calls.workflow == %{}

    refute Enum.any?(EventSink.events(sink), fn event ->
             event.type in ["capability-started", "capability-stopped"]
           end)
  end

  test "request-schema output mismatch is invalid_result after the callback" do
    parent = self()

    {result, state, sink, _capability} =
      dispatch_request_schema(
        %{"schema" => @request_schema},
        fn _arguments ->
          send(parent, :called)
          {:ok, %{"ok" => "not-boolean"}}
        end
      )

    assert_received :called

    assert %{
             status: :error,
             kind: :invalid_result,
             reason: :output_schema_mismatch,
             retryable?: false
           } = result

    assert RunState.usage(state).capability_calls.workflow[request_schema_name()] == 1

    assert Enum.any?(EventSink.events(sink), fn event ->
             event.type == "capability-stopped" and event.data.reason == :output_schema_mismatch
           end)
  end

  test "valid output is admitted after the shared validation deadline" do
    parent = self()
    deadline_ms = System.monotonic_time(:millisecond) + 200

    {:ok, capability} =
      Capability.new(
        name: "checked-output",
        effect: :read,
        input_schema: %{"type" => "object"},
        output_schema: %{
          "type" => "object",
          "properties" => %{"ok" => %{"type" => "boolean"}},
          "required" => ["ok"]
        },
        callback: fn _arguments ->
          send(parent, {:in_callback, self()})

          receive do
            :continue -> {:ok, %{"ok" => true}}
          end
        end
      )

    task =
      Task.async(fn ->
        dispatch_capability(capability, %{}, validation_deadline_ms: deadline_ms)
      end)

    assert_receive {:in_callback, worker}

    wait_ms = max(deadline_ms - System.monotonic_time(:millisecond) + 1, 0)

    if wait_ms > 0 do
      receive do
      after
        wait_ms -> :ok
      end
    end

    send(worker, :continue)

    assert {result, _state, _sink} = Task.await(task)
    assert %{status: :ok, value: %{"ok" => true}} = result
  end

  test "output validator unavailability is distinct from invalid provider output" do
    parent = self()

    capability =
      unavailable_output_capability(fn arguments ->
        send(parent, {:called, arguments})
        {:ok, %{"ok" => true}}
      end)

    {result, state, sink} = dispatch_capability(capability, %{})

    assert_received {:called, %{}}

    assert %{
             status: :error,
             kind: :capability_unavailable,
             reason: :output_validation_unavailable,
             retryable?: false
           } = result

    assert RunState.usage(state).capability_calls.workflow["checked-output"] == 1
    assert RunState.usage(state).protocol_errors == 0

    events = EventSink.events(sink)

    assert Enum.any?(events, fn event ->
             event.type == "capability-stopped" and
               event.data.reason == :output_validation_unavailable
           end)
  end

  test "mission output validator unavailability marks terminal host failure" do
    capability = unavailable_output_capability(fn _ -> {:ok, %{"ok" => true}} end)
    {:ok, environment} = MissionEnvironment.new(capabilities: [capability])
    {:ok, limits} = Limits.new()
    {:ok, state} = RunState.start(limits)
    {:ok, _memory, _history, lease} = RunState.reserve_evaluation(state, "reader", :fail_fast)

    result =
      Dispatcher.dispatch(
        state,
        :mission,
        environment,
        capability.name,
        %{},
        TestHelpers.dispatch_context(state, :mission, 100, lease: lease, mission_name: "reader"),
        nil,
        nil
      )

    assert %{
             status: :error,
             kind: :capability_unavailable,
             reason: :output_validation_unavailable
           } = result

    assert {:ok, %{terminal_host_failure?: true}} =
             RunState.release_evaluation_status(state, lease)
  end

  test "evaluation surfaces output validation unavailability on the host-failure reason" do
    capability = unavailable_output_capability(fn _ -> {:ok, %{"ok" => true}} end)
    {:ok, environment} = MissionEnvironment.new(capabilities: [capability])
    {:ok, state} = RunState.start(Limits.defaults())

    result =
      Evaluation.evaluate_source(
        state,
        "default",
        environment,
        ~S|(tool/checked-output {})|,
        500
      )

    assert %{
             terminal_host_failure?: true,
             terminal_host_failure_reason: :output_validation_unavailable
           } = result
  end

  defp unavailable_output_capability(callback) do
    {:ok, capability} =
      Capability.new(
        name: "checked-output",
        effect: :read,
        input_schema: %{"type" => "object"},
        output_schema: %{
          "type" => "object",
          "properties" => %{"ok" => %{"type" => "boolean"}},
          "required" => ["ok"]
        },
        callback: callback
      )

    %{capability | output_validator: :forced_validator_failure}
  end

  defp dispatch_request_schema(arguments, callback) do
    {:ok, capability} =
      Capability.new(
        name: request_schema_name(),
        effect: :read,
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "schema" => %{"type" => "object", "additionalProperties" => true}
          },
          "required" => ["schema"]
        },
        callback: callback
      )

    {result, state, sink} = dispatch_capability(capability, arguments)
    {result, state, sink, capability}
  end

  defp dispatch_capability(capability, arguments, opts \\ []) do
    {:ok, environment} = WorkflowEnvironment.new(capabilities: [capability])
    {:ok, limits} = Limits.new()
    {:ok, state} = RunState.start(limits)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "bounded-schema")
    timeout_ms = Keyword.get(opts, :timeout_ms, 1_000)

    result =
      Dispatcher.dispatch(
        state,
        :workflow,
        environment,
        capability.name,
        arguments,
        TestHelpers.dispatch_context(state, :workflow, timeout_ms, opts),
        sink,
        nil
      )

    {result, state, sink}
  end

  defp request_schema_name, do: "llm-request"
end
