defmodule PtcRunner.Kernel.LLMRouterTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.CapabilityInvocation
  alias PtcRunner.Kernel.Dispatcher
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.LLMCapability
  alias PtcRunner.Kernel.LLMRouter
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.RoutedCapability
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.TraceCapability
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.TestSupport.TestHelpers

  test "routes by alias, uses the declared default, and strips model before invocation" do
    parent = self()

    fast = capability(parent, :fast, %{content: "fast", tokens: %{input: 2, output: 1}})
    strong = capability(parent, :strong, %{content: "strong", tokens: %{input: 7, output: 3}})

    assert {:ok, router} =
             LLMRouter.new([
               route("fast", "llm_replay", "fast-v1", true, fast),
               route("strong", "llm", "strong-v2", false, strong)
             ])

    assert {:ok, explicit_config} = config(router, "routing-explicit")

    assert {:ok, %{value: %{"content" => "strong"}}} =
             Kernel.run(
               ~S|(return (llm/request {"model" "strong" "messages" []}))|,
               explicit_config
             )

    assert_receive {:strong, %{"messages" => []}}

    assert {:ok, default_config} = config(router, "routing-default")

    assert {:ok, %{value: %{"content" => "fast"}}} =
             Kernel.run(~S|(return (llm/request {"messages" []}))|, default_config)

    assert_receive {:fast, %{"messages" => []}}
  end

  test "routing failures are exact pre-reservation protocol errors" do
    leaf = capability(self(), :unused, %{content: "unused", tokens: %{}})

    assert {:ok, router} =
             LLMRouter.new([
               route("deepseek", "llm", "deepseek-v1", false, leaf),
               route("sonnet", "llm", "sonnet-v1", false, leaf)
             ])

    assert {:ok, workflow} = WorkflowEnvironment.new(capabilities: [router])
    assert {:ok, limits} = Limits.new()
    assert {:ok, state} = RunState.start(limits)
    assert {:ok, sink} = EventSink.start(:normal, limits, run_id: "routing-errors")

    cases = [
      {%{"messages" => []}, :model_alias_required,
       "2 model aliases selected (deepseek, sonnet) and no default declared; this call must name one"},
      {%{"model" => "opus", "messages" => []}, :unknown_model_alias,
       ~s(unknown model alias "opus"; selected aliases are: deepseek, sonnet)},
      {%{"model" => nil, "messages" => []}, :invalid_model_alias,
       "model alias must be a string; null does not mean omitted"}
    ]

    for {arguments, reason, details} <- cases do
      assert %{status: :error, kind: :protocol_error, reason: ^reason, details: ^details} =
               Dispatcher.dispatch(
                 state,
                 :workflow,
                 workflow,
                 "llm-request",
                 arguments,
                 TestHelpers.dispatch_context(state, :workflow, 1_000),
                 sink,
                 nil
               )
    end

    usage = RunState.usage(state)
    assert usage.protocol_errors == 3
    assert usage.capability_calls.workflow == %{}

    refute Enum.any?(EventSink.events(sink), fn event ->
             event.type in ["capability-started", "capability-stopped"]
           end)
  end

  test "maximum-size alias sets return a bounded protocol error" do
    leaf = capability(self(), :unused, %{content: "unused", tokens: %{}})

    routes =
      for index <- 1..32 do
        prefix = "a" <> String.pad_leading(Integer.to_string(index), 2, "0")
        route(prefix <> String.duplicate("x", 128 - byte_size(prefix)), "llm", "v1", false, leaf)
      end

    assert {:ok, router} = LLMRouter.new(routes)
    assert {:ok, workflow} = WorkflowEnvironment.new(capabilities: [router])
    assert {:ok, limits} = Limits.new()
    assert {:ok, state} = RunState.start(limits)

    assert %{
             status: :error,
             kind: :protocol_error,
             reason: :model_alias_required,
             details: details
           } =
             Dispatcher.dispatch(
               state,
               :workflow,
               workflow,
               "llm-request",
               %{},
               TestHelpers.dispatch_context(state, :workflow, 1_000),
               nil,
               nil
             )

    assert byte_size(details) <= 4_096
    assert details =~ "32 model aliases selected ("
    assert RunState.usage(state).capability_calls.workflow == %{}
  end

  test "a malformed resolver result fails closed without raising" do
    assert {:ok, leaf} =
             Capability.new(
               name: "leaf",
               input_schema: %{"type" => "object"},
               callback: fn _arguments -> {:ok, %{}} end
             )

    assert {:ok, routed} =
             RoutedCapability.new(
               name: "route",
               input_schema: %{"type" => "object"},
               routes: %{"leaf" => leaf},
               resolve: fn _arguments -> :malformed end
             )

    assert {:ok, workflow} = WorkflowEnvironment.new(capabilities: [routed])
    assert {:ok, limits} = Limits.new()
    assert {:ok, state} = RunState.start(limits)

    assert %{
             status: :error,
             kind: :capability_unavailable,
             reason: :resolver_unavailable,
             retryable?: false
           } =
             Dispatcher.dispatch(
               state,
               :workflow,
               workflow,
               "route",
               %{},
               TestHelpers.dispatch_context(state, :workflow, 1_000),
               nil,
               nil
             )

    assert RunState.usage(state).capability_calls.workflow == %{}
  end

  test "reserved or colliding routed metadata fails before reservation and events" do
    assert {:ok, leaf} =
             Capability.new(
               name: "leaf",
               input_schema: %{"type" => "object"},
               callback: fn _arguments -> {:ok, %{}} end
             )

    invocation = %CapabilityInvocation{
      capability: leaf,
      arguments: %{},
      route_key: "leaf",
      event_attributes: %{
        capability_id: "forged",
        environment: :mission,
        name: "forged",
        status: :error,
        duration_ms: -1,
        outcome: :error
      },
      error_attributes: %{},
      usage_projection: nil
    }

    assert {:ok, reserved} =
             RoutedCapability.new(
               name: "public-route",
               input_schema: %{"type" => "object"},
               routes: %{"leaf" => leaf},
               resolve: fn _arguments -> {:ok, invocation} end
             )

    collision = %{
      invocation
      | event_attributes: %{"alias" => "string-alias", alias: "atom-alias"}
    }

    assert {:error, :resolver_unavailable} = RoutedCapability.resolve(reserved, %{})

    assert {:ok, colliding} =
             RoutedCapability.new(
               name: "colliding-route",
               input_schema: %{"type" => "object"},
               routes: %{"leaf" => leaf},
               resolve: fn _arguments -> {:ok, collision} end
             )

    assert {:error, :resolver_unavailable} = RoutedCapability.resolve(colliding, %{})

    assert {:ok, workflow} = WorkflowEnvironment.new(capabilities: [reserved])
    assert {:ok, limits} = Limits.new()
    assert {:ok, state} = RunState.start(limits)
    assert {:ok, sink} = EventSink.start(:normal, limits, run_id: "canonical-route-events")

    assert %{
             status: :error,
             kind: :capability_unavailable,
             reason: :resolver_unavailable,
             retryable?: false
           } =
             Dispatcher.dispatch(
               state,
               :workflow,
               workflow,
               "public-route",
               %{},
               TestHelpers.dispatch_context(state, :workflow, 1_000),
               sink,
               nil
             )

    assert EventSink.events(sink) == []
    assert RunState.usage(state).capability_calls.workflow == %{}
  end

  test "bounded resolver details are detached from a larger parent binary" do
    assert {:ok, leaf} =
             Capability.new(
               name: "leaf",
               input_schema: %{"type" => "object"},
               callback: fn _arguments -> {:ok, %{}} end
             )

    parent = String.duplicate("detail", 10_000)
    details = binary_part(parent, 0, 100)
    assert :binary.referenced_byte_size(details) > byte_size(details)

    assert {:ok, routed} =
             RoutedCapability.new(
               name: "route",
               input_schema: %{"type" => "object"},
               routes: %{"leaf" => leaf},
               resolve: fn _arguments -> {:error, :route_error, details} end
             )

    assert {:error, :route_error, detached} = RoutedCapability.resolve(routed, %{})
    assert detached == details
    assert :binary.referenced_byte_size(detached) == byte_size(detached)
  end

  test "router safely augments empty schemas and rejects schemas with no property capacity" do
    assert {:ok, empty} =
             Capability.new(
               name: "llm-request",
               input_schema: %{"type" => "object"},
               callback: fn _arguments -> {:ok, %{}} end
             )

    assert {:ok, router} = LLMRouter.new([route("empty", "custom", "v1", false, empty)])
    assert router.input_schema["properties"]["model"]["type"] == "string"

    properties =
      Map.new(1..128, fn index -> {"field_#{index}", %{"type" => "string"}} end)

    assert {:ok, full} =
             Capability.new(
               name: "llm-request",
               input_schema: %{"type" => "object", "properties" => properties},
               callback: fn _arguments -> {:ok, %{}} end
             )

    assert {:error, :invalid_llm_router} =
             LLMRouter.new([route("full", "custom", "v1", false, full)])
  end

  test "router rejects aliases with incompatible request schemas" do
    assert {:ok, first} =
             Capability.new(
               name: "llm-request",
               input_schema: %{
                 "type" => "object",
                 "properties" => %{"first" => %{"type" => "string"}}
               },
               callback: fn _arguments -> {:ok, %{}} end
             )

    assert {:ok, second} =
             Capability.new(
               name: "llm-request",
               input_schema: %{
                 "type" => "object",
                 "properties" => %{"second" => %{"type" => "string"}}
               },
               callback: fn _arguments -> {:ok, %{}} end
             )

    assert {:error, :invalid_llm_router} =
             LLMRouter.new([
               route("first", "custom", "v1", false, first),
               route("second", "custom", "v1", false, second)
             ])
  end

  test "routed events carry immutable alias, revision, and closed usage" do
    leaf = capability(self(), :metered, %{content: "answer", tokens: %{input: 4, output: 2}})
    assert {:ok, router} = LLMRouter.new([route("metered", "llm", "metered-v3", false, leaf)])
    assert {:ok, config} = config(router, "routing-events")

    assert {:ok, %{value: %{"content" => "answer"}}} =
             Kernel.run(~S|(return (llm/request {"messages" []}))|, config)

    events =
      config.event_sink
      |> EventSink.events()
      |> Enum.filter(&(&1.type in ["capability-started", "capability-stopped"]))

    assert [started, stopped] = events
    assert started.data.alias == "metered"
    assert started.data.installation_revision == "metered-v3"
    assert stopped.data.alias == "metered"
    assert stopped.data.installation_revision == "metered-v3"
    assert stopped.data.usage == %{"input" => 4, "output" => 2}
    refute Map.has_key?(started.data, :resolved_model)
    refute Map.has_key?(stopped.data, :resolved_model)
    refute inspect(events) =~ "answer"

    assert {:ok, trace_capabilities} =
             TraceCapability.new(source: config.event_sink, max_result_bytes: 100_000)

    counters = Enum.find(trace_capabilities, &(&1.name == "trace-counters"))

    assert {:ok,
            %{
              "errors" => 0,
              "llm_usage" => [
                %{
                  "alias" => "metered",
                  "installation_revision" => "metered-v3",
                  "calls" => 1,
                  "successful_calls" => 1,
                  "usage_calls" => 1,
                  "missing_usage_calls" => 0,
                  "usage" => %{"input" => 4, "output" => 2}
                }
              ],
              "llm_usage_by_model" => [],
              "unattributed_model_calls" => 1
            }} = counters.callback.(%{"run_id" => "routing-events"})
  end

  test "capability discovery names aliases and the default" do
    leaf = capability(self(), :discover, %{content: "unused", tokens: %{}})

    assert {:ok, router} =
             LLMRouter.new([
               route("deepseek", "llm_replay", "deepseek-v1", true, leaf),
               route("sonnet", "llm", "sonnet-v2", false, leaf)
             ])

    assert {:ok, config} = config(router, "routing-discovery")

    assert {:ok, %{value: metadata}} =
             Kernel.run(~S|(return (cap/describe "llm-request"))|, config)

    assert metadata["model_aliases"] == [
             %{
               "alias" => "deepseek",
               "source" => "llm_replay",
               "installation_revision" => "deepseek-v1",
               "default" => true
             },
             %{
               "alias" => "sonnet",
               "source" => "llm",
               "installation_revision" => "sonnet-v2",
               "default" => false
             }
           ]
  end

  test "malformed token usage cannot cross the LLM response boundary" do
    assert {:ok, capability} =
             LLMCapability.new(
               requester: fn _request ->
                 {:ok, %{content: "secret", tokens: %{content: "must-not-be-published"}}}
               end
             )

    assert {:error, error} = capability.callback.(%{"messages" => []})
    assert error.kind == :invalid_request
  end

  defp capability(parent, tag, response) do
    {:ok, capability} =
      LLMCapability.new(
        requester: fn request ->
          send(parent, {tag, request})
          {:ok, response}
        end
      )

    capability
  end

  defp route(alias_name, source, revision, default?, capability) do
    %{
      alias: alias_name,
      source: source,
      installation_revision: revision,
      default?: default?,
      capability: capability
    }
  end

  defp config(router, run_id) do
    {:ok, components} = Library.resolve_components([{:library, "llm"}, {:library, "cap"}])
    {:ok, bundle} = Kernel.compile_bundle(components)
    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle, capabilities: [router])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: run_id)

    RunConfig.new(
      workflow_environment: workflow,
      missions: %{"default" => mission},
      input: %{},
      limits: limits,
      event_sink: sink
    )
  end
end
