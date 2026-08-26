defmodule PtcRunner.Kernel.DispatcherStructuredOutputTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel.Dispatcher
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.LLMCapability
  alias PtcRunner.Kernel.LLMRouter
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.TestSupport.TestHelpers

  @schema %{
    "type" => "object",
    "properties" => %{"ok" => %{"type" => "boolean"}},
    "required" => ["ok"]
  }

  test "json_schema success returns structured_output without encoded content" do
    parent = self()

    {result, state, sink} =
      dispatch_structured(
        parent,
        :json_schema,
        %{object: %{"ok" => true}, tokens: %{input: 2, output: 1}}
      )

    assert %{
             status: :ok,
             value: %{
               "structured_output" => %{"ok" => true},
               "tokens" => tokens,
               "model" => "model"
             }
           } = result

    assert tokens["input"] == 2
    refute Map.has_key?(result.value, "content")
    refute Map.has_key?(result.value, "object")
    assert_received {:called, %{"schema" => _schema}}
    assert RunState.usage(state).capability_calls.workflow["llm-request"] == 1
    assert Enum.any?(EventSink.events(sink), &(&1.type == "capability-started"))
  end

  test "json_object success decodes provider JSON and validates the object" do
    {result, _state, _sink} =
      dispatch_structured(
        self(),
        :json_object,
        %{json: ~s({"ok":true}), tokens: %{input: 1, output: 1}}
      )

    assert %{status: :ok, value: %{"structured_output" => %{"ok" => true}}} = result
    refute Map.has_key?(result.value, "json")
    refute Map.has_key?(result.value, "content")
  end

  test "replay structured_output fixtures are validated against the request schema" do
    {result, _state, _sink} =
      dispatch_structured(
        self(),
        nil,
        %{"structured_output" => %{"ok" => true}, "tokens" => %{"input" => 1, "output" => 1}}
      )

    assert %{status: :ok, value: %{"structured_output" => %{"ok" => true}}} = result
  end

  test "tools together with schema are invalid_arguments before dispatch" do
    parent = self()

    {result, state, sink} =
      dispatch_structured(
        parent,
        :json_schema,
        %{object: %{"ok" => true}, tokens: %{}},
        %{
          "schema" => @schema,
          "tools" => [%{"name" => "lookup", "description" => "x", "parameters" => %{}}]
        }
      )

    assert %{
             status: :error,
             kind: :protocol_error,
             reason: :invalid_arguments,
             retryable?: false
           } = result

    refute_received {:called, _}
    assert RunState.usage(state).protocol_errors == 1
    assert RunState.usage(state).capability_calls.workflow == %{}

    refute Enum.any?(EventSink.events(sink), fn event ->
             event.type in ["capability-started", "capability-stopped"]
           end)
  end

  test "unsupported structured output refuses schema requests before dispatch" do
    parent = self()

    {result, state, sink} =
      dispatch_structured(
        parent,
        :unsupported,
        %{object: %{"ok" => true}, tokens: %{}}
      )

    assert %{
             status: :error,
             kind: :provider_error,
             reason: :structured_output_unsupported,
             retryable?: false,
             model: "model"
           } = result

    refute_received {:called, _}
    assert RunState.usage(state).protocol_errors == 0
    assert RunState.usage(state).capability_calls.workflow == %{}

    refute Enum.any?(EventSink.events(sink), fn event ->
             event.type in ["capability-started", "capability-stopped"]
           end)
  end

  test "an invalid schema is invalid_arguments even under unsupported mode" do
    parent = self()

    {result, state, sink} =
      dispatch_structured(
        parent,
        :unsupported,
        %{object: %{"ok" => true}, tokens: %{}},
        %{"schema" => %{"type" => "array"}}
      )

    assert %{
             status: :error,
             kind: :protocol_error,
             reason: :invalid_arguments,
             retryable?: false
           } = result

    refute_received {:called, _}
    assert RunState.usage(state).protocol_errors == 1
    assert RunState.usage(state).capability_calls.workflow == %{}

    refute Enum.any?(EventSink.events(sink), fn event ->
             event.type in ["capability-started", "capability-stopped"]
           end)
  end

  test "tools with schema stay invalid_arguments under unsupported mode" do
    parent = self()

    {result, _state, _sink} =
      dispatch_structured(
        parent,
        :unsupported,
        %{object: %{"ok" => true}, tokens: %{}},
        %{
          "schema" => %{"type" => "array"},
          "tools" => [%{"name" => "lookup", "description" => "x", "parameters" => %{}}]
        }
      )

    assert %{
             status: :error,
             kind: :protocol_error,
             reason: :invalid_arguments,
             retryable?: false
           } = result

    refute_received {:called, _}
  end

  test "encoded structured content is dropped from a json_schema success" do
    {result, _state, _sink} =
      dispatch_structured(
        self(),
        :json_schema,
        %{object: %{"ok" => true}, content: ~s({"ok":true}), tokens: %{}}
      )

    assert %{status: :ok, value: %{"structured_output" => %{"ok" => true}}} = result
    refute Map.has_key?(result.value, "content")
    refute Map.has_key?(result.value, "object")
  end

  test "empty tools with schema remain valid" do
    {result, _state, _sink} =
      dispatch_structured(
        self(),
        :json_schema,
        %{object: %{"ok" => true}, tokens: %{}},
        %{"schema" => @schema, "tools" => []}
      )

    assert %{status: :ok, value: %{"structured_output" => %{"ok" => true}}} = result
  end

  test "malformed json_object output is output_schema_mismatch" do
    parent = self()

    {result, state, sink} =
      dispatch_structured(parent, :json_object, %{json: "not-json", tokens: %{}})

    assert_received {:called, _}

    assert %{
             status: :error,
             kind: :invalid_result,
             reason: :output_schema_mismatch,
             retryable?: false
           } = result

    assert RunState.usage(state).capability_calls.workflow["llm-request"] == 1

    assert Enum.any?(EventSink.events(sink), fn event ->
             event.type == "capability-stopped" and event.data.reason == :output_schema_mismatch
           end)
  end

  test "non-object json_object output is output_schema_mismatch" do
    {result, _state, _sink} =
      dispatch_structured(self(), :json_object, %{json: "[true]", tokens: %{}})

    assert %{
             status: :error,
             kind: :invalid_result,
             reason: :output_schema_mismatch
           } = result
  end

  test "returning the wrong structured branch is output_schema_mismatch" do
    {result, _state, _sink} =
      dispatch_structured(self(), :json_schema, %{json: ~s({"ok":true}), tokens: %{}})

    assert %{
             status: :error,
             kind: :invalid_result,
             reason: :output_schema_mismatch
           } = result
  end

  test "schema-invalid structured object is output_schema_mismatch" do
    {result, _state, _sink} =
      dispatch_structured(self(), :json_schema, %{object: %{"ok" => "no"}, tokens: %{}})

    assert %{
             status: :error,
             kind: :invalid_result,
             reason: :output_schema_mismatch
           } = result
  end

  test "missing structured output is output_schema_mismatch" do
    parent = self()

    {result, state, sink} =
      dispatch_structured(parent, :json_schema, %{tokens: %{}})

    assert_received {:called, _}

    assert %{
             status: :error,
             kind: :invalid_result,
             reason: :output_schema_mismatch,
             retryable?: false
           } = result

    assert RunState.usage(state).capability_calls.workflow["llm-request"] == 1

    assert Enum.any?(EventSink.events(sink), fn event ->
             event.type == "capability-stopped" and event.data.reason == :output_schema_mismatch
           end)
  end

  test "a non-map json_schema object is output_schema_mismatch" do
    {result, _state, _sink} =
      dispatch_structured(self(), :json_schema, %{object: "not-an-object", tokens: %{}})

    assert %{
             status: :error,
             kind: :invalid_result,
             reason: :output_schema_mismatch
           } = result
  end

  test "json_object decode unavailability is distinct from invalid provider JSON" do
    parent = self()
    deadline_ms = System.monotonic_time(:millisecond) + 200

    {:ok, capability} =
      LLMCapability.new(
        requester: fn _request ->
          send(parent, {:in_callback, self()})

          receive do
            :continue -> {:ok, %{json: ~s({"ok":true}), tokens: %{}}}
          end
        end
      )

    assert {:ok, router} =
             LLMRouter.new([
               %{
                 alias: "model",
                 source: "llm",
                 installation_revision: "model-v1",
                 default?: true,
                 capability: capability,
                 max_calls: nil,
                 structured_output_mode: :json_object
               }
             ])

    task =
      Task.async(fn ->
        dispatch_router(router, %{"schema" => @schema}, validation_deadline_ms: deadline_ms)
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

    assert %{
             status: :error,
             kind: :capability_unavailable,
             reason: :output_validation_unavailable,
             retryable?: false
           } = result
  end

  defp dispatch_structured(
         parent,
         mode,
         response,
         arguments \\ %{"schema" => @schema},
         opts \\ []
       ) do
    {:ok, capability} =
      LLMCapability.new(
        requester: fn request ->
          send(parent, {:called, request})
          {:ok, response}
        end
      )

    route = %{
      alias: "model",
      source: "llm",
      installation_revision: "model-v1",
      default?: true,
      capability: capability,
      max_calls: nil
    }

    route =
      if mode,
        do: Map.put(route, :structured_output_mode, mode),
        else: route

    assert {:ok, router} = LLMRouter.new([route])
    {:ok, environment} = WorkflowEnvironment.new(capabilities: [router])
    {:ok, limits} = Limits.new()
    {:ok, state} = RunState.start(limits)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "structured-output")
    timeout_ms = Keyword.get(opts, :timeout_ms, 1_000)

    result =
      Dispatcher.dispatch(
        state,
        :workflow,
        environment,
        "llm-request",
        arguments,
        TestHelpers.dispatch_context(state, :workflow, timeout_ms, opts),
        sink,
        nil
      )

    {result, state, sink}
  end

  defp dispatch_router(router, arguments, opts) do
    {:ok, environment} = WorkflowEnvironment.new(capabilities: [router])
    {:ok, limits} = Limits.new()
    {:ok, state} = RunState.start(limits)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "structured-output")
    timeout_ms = Keyword.get(opts, :timeout_ms, 1_000)

    result =
      Dispatcher.dispatch(
        state,
        :workflow,
        environment,
        "llm-request",
        arguments,
        TestHelpers.dispatch_context(state, :workflow, timeout_ms, opts),
        sink,
        nil
      )

    {result, state, sink}
  end
end
