defmodule PtcRunner.Kernel.LLMRouterTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.ArtifactPublisher
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.CapabilityInvocation
  alias PtcRunner.Kernel.CommandRunOutcome
  alias PtcRunner.Kernel.DeterministicJSON
  alias PtcRunner.Kernel.Dispatcher
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.ExecutionOutcome
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.LLMCapability
  alias PtcRunner.Kernel.LLMRouter
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.ProviderSnapshot
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.RoutedCapability
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.RuntimeLimitDiagnostic
  alias PtcRunner.Kernel.TraceLog
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

  test "a per-alias max_calls cap leaves other aliases callable" do
    parent = self()
    expensive = capability(parent, :expensive, %{content: "paid", tokens: %{}})
    cheap = capability(parent, :cheap, %{content: "ok", tokens: %{}})

    assert {:ok, router} =
             LLMRouter.new([
               route("expensive", "llm", "expensive-v1", false, expensive, 2),
               route("cheap", "llm", "cheap-v1", true, cheap)
             ])

    assert {:ok, config} = config(router, "alias-max-calls")

    source = """
    (do
      (llm/request {"model" "expensive" "messages" []})
      (llm/request {"model" "expensive" "messages" []})
      (return (llm/request {"model" "cheap" "messages" []})))
    """

    assert {:ok, %{value: %{"content" => "ok"}}} = Kernel.run(source, config)
    assert_receive {:expensive, %{"messages" => []}}
    assert_receive {:expensive, %{"messages" => []}}
    assert_receive {:cheap, %{"messages" => []}}
    refute_receive {:expensive, _}
  end

  test "exceeding max_calls names the alias on the envelope and limit-exceeded event" do
    leaf = capability(self(), :capped, %{content: "paid", tokens: %{}})

    assert {:ok, router} =
             LLMRouter.new([route("expensive", "llm", "expensive-v1", false, leaf, 1)])

    assert {:ok, workflow} = WorkflowEnvironment.new(capabilities: [router])
    assert {:ok, limits} = Limits.new()
    assert {:ok, state} = RunState.start(limits)
    assert {:ok, sink} = EventSink.start(:normal, limits, run_id: "max-calls-event")
    context = TestHelpers.dispatch_context(state, :workflow, 1_000)
    arguments = %{"model" => "expensive", "messages" => []}

    assert %{status: :ok} =
             Dispatcher.dispatch(
               state,
               :workflow,
               workflow,
               "llm-request",
               arguments,
               context,
               sink,
               nil
             )

    assert %{
             status: :error,
             kind: :limit_exceeded,
             reason: :capability_quota,
             details: %{limit: :max_calls, alias: "expensive", limit_value: 1}
           } =
             Dispatcher.dispatch(
               state,
               :workflow,
               workflow,
               "llm-request",
               arguments,
               context,
               sink,
               nil
             )

    assert %{
             data: %{
               reason: :capability_quota,
               limit: :max_calls,
               alias: "expensive",
               limit_value: 1
             }
           } = Enum.find(EventSink.events(sink), &(&1.type == "limit-exceeded"))

    :ok = EventSink.stop(sink)
    :ok = RunState.stop(state)
  end

  test "failing a max_calls envelope names the alias on the command diagnostic" do
    run_id = "max-calls-fail"
    run_ref = "cmd-00000000000000000000000000"
    leaf = capability(self(), :capped_fail, %{content: "paid", tokens: %{}})

    assert {:ok, router} =
             LLMRouter.new([route("expensive", "llm", "expensive-v1", false, leaf, 1)])

    assert {:ok, config} = config(router, run_id)

    source =
      ~S|(do (llm/request {"model" "expensive" "messages" []}) (fail (llm/request {"model" "expensive" "messages" []})))|

    assert {:error, command_outcome, _counters, events} =
             project_run(source, config, run_id, run_ref)

    assert {:ok, expected} = RuntimeLimitDiagnostic.max_calls_message("expensive", 1)
    assert command_outcome.envelope["error"]["code"] == "runtime_limit_exceeded"
    assert command_outcome.envelope["error"]["message"] == expected

    assert command_outcome.envelope["error"]["source"] == %{
             "kind" => "runtime",
             "name" => "ptc-runtime"
           }

    assert [
             %{
               type: "limit-exceeded",
               data: %{
                 reason: :capability_quota,
                 limit: :max_calls,
                 alias: "expensive",
                 limit_value: 1
               }
             }
           ] = Enum.filter(events, &(&1.type == "limit-exceeded"))
  end

  test "an application-authored max_calls lookalike cannot claim the runtime diagnostic" do
    run_id = "max-calls-forged"
    run_ref = "cmd-00000000000000000000000000"
    leaf = capability(self(), :unused_forged, %{content: "paid", tokens: %{}})

    assert {:ok, router} =
             LLMRouter.new([route("expensive", "llm", "expensive-v1", false, leaf, 1)])

    assert {:ok, config} = config(router, run_id)

    source =
      ~S|(fail {:status :error :kind :limit-exceeded :reason :capability-quota :details {:limit :max-calls :alias "expensive" :limit_value 1}})|

    assert {:error, command_outcome, _counters, _events} =
             project_run(source, config, run_id, run_ref)

    assert command_outcome.envelope["error"]["code"] == "workflow_failed"
  end

  test "spending an alias cap without a refused call cannot claim the runtime diagnostic" do
    run_id = "max-calls-spent-not-refused"
    run_ref = "cmd-00000000000000000000000000"
    leaf = capability(self(), :spent_not_refused, %{content: "paid", tokens: %{}})

    assert {:ok, router} =
             LLMRouter.new([route("expensive", "llm", "expensive-v1", false, leaf, 1)])

    assert {:ok, config} = config(router, run_id)

    source =
      ~S|(do (llm/request {"model" "expensive" "messages" []}) (fail {:status :error :kind :limit-exceeded :reason :capability-quota :details {:limit :max-calls :alias "expensive" :limit_value 1}}))|

    assert {:error, command_outcome, _counters, _events} =
             project_run(source, config, run_id, run_ref)

    assert command_outcome.envelope["error"]["code"] == "workflow_failed"
  end

  test "a spent public quota binds before a stricter alias cap" do
    parent = self()
    expensive = capability(parent, :collision_expensive, %{content: "paid", tokens: %{}})
    cheap = capability(parent, :collision_cheap, %{content: "ok", tokens: %{}})

    assert {:ok, router} =
             LLMRouter.new([
               route("expensive", "llm", "expensive-v1", false, expensive, 2),
               route("cheap", "llm", "cheap-v1", true, cheap)
             ])

    assert {:ok, limits} =
             Limits.new(workflow_capability_calls: 8, workflow_capability_calls_per_name: 3)

    assert {:ok, workflow} = WorkflowEnvironment.new(capabilities: [router])
    assert {:ok, state} = RunState.start(limits)
    context = TestHelpers.dispatch_context(state, :workflow, 1_000)

    assert %{status: :ok} =
             Dispatcher.dispatch(
               state,
               :workflow,
               workflow,
               "llm-request",
               %{"model" => "expensive", "messages" => []},
               context,
               nil,
               nil
             )

    assert %{status: :ok} =
             Dispatcher.dispatch(
               state,
               :workflow,
               workflow,
               "llm-request",
               %{"model" => "expensive", "messages" => []},
               context,
               nil,
               nil
             )

    assert %{status: :ok} =
             Dispatcher.dispatch(
               state,
               :workflow,
               workflow,
               "llm-request",
               %{"model" => "cheap", "messages" => []},
               context,
               nil,
               nil
             )

    assert %{status: :error, kind: :limit_exceeded, reason: :capability_quota} =
             fourth =
             Dispatcher.dispatch(
               state,
               :workflow,
               workflow,
               "llm-request",
               %{"model" => "expensive", "messages" => []},
               context,
               nil,
               nil
             )

    refute match?(%{details: %{limit: :max_calls}}, fourth)
    :ok = RunState.stop(state)
  end

  test "an alias cap at the per-name budget still binds as the public quota" do
    leaf = capability(self(), :tied, %{content: "ok", tokens: %{}})

    assert {:ok, router} =
             LLMRouter.new([route("tied", "llm", "tied-v1", true, leaf, 2)])

    assert {:ok, limits} =
             Limits.new(workflow_capability_calls: 8, workflow_capability_calls_per_name: 2)

    assert {:ok, workflow} = WorkflowEnvironment.new(capabilities: [router])
    assert {:ok, state} = RunState.start(limits)
    context = TestHelpers.dispatch_context(state, :workflow, 1_000)
    arguments = %{"messages" => []}

    assert %{status: :ok} =
             Dispatcher.dispatch(
               state,
               :workflow,
               workflow,
               "llm-request",
               arguments,
               context,
               nil,
               nil
             )

    assert %{status: :ok} =
             Dispatcher.dispatch(
               state,
               :workflow,
               workflow,
               "llm-request",
               arguments,
               context,
               nil,
               nil
             )

    assert %{status: :error, kind: :limit_exceeded, reason: :capability_quota} =
             third =
             Dispatcher.dispatch(
               state,
               :workflow,
               workflow,
               "llm-request",
               arguments,
               context,
               nil,
               nil
             )

    refute match?(%{details: %{limit: :max_calls}}, third)
    :ok = RunState.stop(state)
  end

  test "omitted max_calls still binds at the public per-name quota" do
    leaf = capability(self(), :shared, %{content: "ok", tokens: %{}})

    assert {:ok, router} =
             LLMRouter.new([route("shared", "llm", "shared-v1", true, leaf)])

    assert {:ok, limits} =
             Limits.new(workflow_capability_calls: 8, workflow_capability_calls_per_name: 2)

    assert {:ok, workflow} = WorkflowEnvironment.new(capabilities: [router])
    assert {:ok, state} = RunState.start(limits)
    context = TestHelpers.dispatch_context(state, :workflow, 1_000)
    arguments = %{"messages" => []}

    assert %{status: :ok} =
             Dispatcher.dispatch(
               state,
               :workflow,
               workflow,
               "llm-request",
               arguments,
               context,
               nil,
               nil
             )

    assert %{status: :ok} =
             Dispatcher.dispatch(
               state,
               :workflow,
               workflow,
               "llm-request",
               arguments,
               context,
               nil,
               nil
             )

    assert %{status: :error, kind: :limit_exceeded, reason: :capability_quota} =
             third =
             Dispatcher.dispatch(
               state,
               :workflow,
               workflow,
               "llm-request",
               arguments,
               context,
               nil,
               nil
             )

    refute match?(%{details: %{limit: :max_calls}}, third)
    :ok = RunState.stop(state)
  end

  test "parallel callers contend for a max_calls of one" do
    assert {:ok, limits} = Limits.new()
    assert {:ok, state} = RunState.start(limits)
    route = %{route_key: "expensive", max_calls: 1}

    results =
      1..2
      |> Enum.map(fn _index ->
        Task.async(fn ->
          RunState.reserve_capability(state, :workflow, "llm-request", nil, route)
        end)
      end)
      |> Enum.map(&Task.await/1)
      |> Enum.sort()

    assert results == [:ok, {:error, :route_call_limit}]
    :ok = RunState.stop(state)
  end

  test "an incomplete route pair does not install a per-alias cap" do
    assert {:ok, limits} = Limits.new()
    assert {:ok, state} = RunState.start(limits)
    route = %{route_key: "expensive"}

    results =
      1..2
      |> Enum.map(fn _index ->
        Task.async(fn ->
          RunState.reserve_capability(state, :workflow, "llm-request", nil, route)
        end)
      end)
      |> Enum.map(&Task.await/1)
      |> Enum.sort()

    assert results == [:ok, :ok]
    :ok = RunState.stop(state)
  end

  test "llm_identity accepts a three-key legacy declaration config" do
    current = TestHelpers.llm_snapshot("writer", "stable-v1", "openrouter:writer/model")

    config = Map.delete(current["declaration"]["config"], "max_calls")
    declaration = Map.put(current["declaration"], "config", config)

    identity = %{
      "declaration" => declaration,
      "acquisition" => current["acquisition"],
      "acquisition_identity_hash" => current["acquisition_identity_hash"]
    }

    {:ok, bytes} = DeterministicJSON.encode(identity)

    snapshot =
      identity
      |> Map.put("provider", "writer")
      |> Map.put("snapshot_hash", Base.encode16(:crypto.hash(:sha256, bytes), case: :lower))

    assert {:ok,
            %{
              alias: "writer",
              installation_revision: "stable-v1",
              resolved_model: "openrouter:writer/model"
            }} = ProviderSnapshot.llm_identity(snapshot)
  end

  test "llm_identity rejects a four-key config whose max_calls is null" do
    current = TestHelpers.llm_snapshot("writer", "stable-v1", "openrouter:writer/model")
    config = Map.put(current["declaration"]["config"], "max_calls", nil)
    declaration = Map.put(current["declaration"], "config", config)

    identity = %{
      "declaration" => declaration,
      "acquisition" => current["acquisition"],
      "acquisition_identity_hash" => current["acquisition_identity_hash"]
    }

    {:ok, bytes} = DeterministicJSON.encode(identity)

    snapshot =
      identity
      |> Map.put("provider", "writer")
      |> Map.put("snapshot_hash", Base.encode16(:crypto.hash(:sha256, bytes), case: :lower))

    assert :error = ProviderSnapshot.llm_identity(snapshot)
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

    assert {:ok, trace_log} = TraceLog.new(source: config.event_sink, max_result_bytes: 100_000)

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
            }} = TraceLog.query(trace_log, :counters, %{"run_id" => "routing-events"})
  end

  test "run envelopes and trace counters project the same sealed LLM usage" do
    run_id = "routing-envelope-usage"
    run_ref = "cmd-00000000000000000000000000"

    leaf =
      capability(self(), :metered_envelope, %{
        content: "answer",
        tokens: %{input: 11, output: 5, total_cost: 0.0042}
      })

    assert {:ok, router} =
             LLMRouter.new([route("metered", "llm", "metered-v3", false, leaf)])

    snapshot = TestHelpers.llm_snapshot("metered", "metered-v3", "openrouter:metered/model")
    assert {:ok, config} = config(router, run_id, connector_snapshots: [snapshot])

    assert {:ok, command_outcome, counters, _events} =
             project_run(~S|(return (llm/request {"messages" []}))|, config, run_id, run_ref)

    envelope_usage = command_outcome.envelope["execution"]["usage"]
    assert envelope_usage["llm_usage_state"] == "available"

    assert Map.take(envelope_usage, [
             "llm_usage",
             "llm_usage_by_model",
             "unattributed_model_calls"
           ]) ==
             Map.take(counters, [
               "llm_usage",
               "llm_usage_by_model",
               "unattributed_model_calls"
             ])

    assert envelope_usage["llm_usage"] == [
             %{
               "alias" => "metered",
               "installation_revision" => "metered-v3",
               "calls" => 1,
               "successful_calls" => 1,
               "usage_calls" => 1,
               "missing_usage_calls" => 0,
               "usage" => %{"input" => 11, "output" => 5, "total_cost" => 0.0042}
             }
           ]

    assert envelope_usage["llm_usage_by_model"] == [
             %{
               "resolved_model" => "openrouter:metered/model",
               "calls" => 1,
               "successful_calls" => 1,
               "usage_calls" => 1,
               "missing_usage_calls" => 0,
               "usage" => %{"input" => 11, "output" => 5, "total_cost" => 0.0042}
             }
           ]

    assert envelope_usage["unattributed_model_calls"] == 0
  end

  test "a failed run envelope retains LLM usage completed before the execution error" do
    run_id = "routing-envelope-failure"
    run_ref = "cmd-00000000000000000000000000"
    leaf = capability(self(), :failed_envelope, %{content: "answer", tokens: %{input: 7}})
    assert {:ok, router} = LLMRouter.new([route("writer", "llm", "writer-v1", false, leaf)])

    snapshot = TestHelpers.llm_snapshot("writer", "writer-v1", "openrouter:writer/model")
    assert {:ok, config} = config(router, run_id, connector_snapshots: [snapshot])

    source = ~S|(do (llm/request {"messages" []}) (fail "after paid call"))|

    assert {:error, command_outcome, counters, _events} =
             project_run(source, config, run_id, run_ref)

    assert command_outcome.envelope["error"]["code"] == "workflow_failed"
    usage = command_outcome.envelope["execution"]["usage"]
    assert usage["llm_usage_state"] == "available"
    assert usage["llm_usage"] == counters["llm_usage"]
    assert usage["llm_usage_by_model"] == counters["llm_usage_by_model"]
    assert usage["unattributed_model_calls"] == 0
    assert get_in(usage, ["llm_usage", Access.at(0), "usage", "input"]) == 7
  end

  test "a sealed run without LLM calls publishes an available empty summary" do
    run_id = "routing-envelope-empty"
    run_ref = "cmd-00000000000000000000000000"
    leaf = capability(self(), :unused_envelope, %{content: "unused", tokens: %{}})
    assert {:ok, router} = LLMRouter.new([route("unused", "llm", "unused-v1", false, leaf)])
    assert {:ok, config} = config(router, run_id)

    assert {:ok, command_outcome, counters, _events} =
             project_run(~S|(return 42)|, config, run_id, run_ref)

    usage = command_outcome.envelope["execution"]["usage"]
    assert usage["llm_usage_state"] == "available"
    assert usage["llm_usage"] == []
    assert usage["llm_usage_by_model"] == []
    assert usage["unattributed_model_calls"] == 0

    assert Map.take(usage, ~w(llm_usage llm_usage_by_model unattributed_model_calls)) ==
             Map.take(counters, ~w(llm_usage llm_usage_by_model unattributed_model_calls))
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

  defp route(alias_name, source, revision, default?, capability, max_calls \\ nil) do
    %{
      alias: alias_name,
      source: source,
      installation_revision: revision,
      default?: default?,
      capability: capability,
      max_calls: max_calls
    }
  end

  defp config(router, run_id, opts \\ []) do
    {:ok, components} = Library.resolve_components([{:library, "llm"}, {:library, "cap"}])
    {:ok, bundle} = Kernel.compile_bundle(components)
    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle, capabilities: [router])
    {:ok, mission} = MissionEnvironment.new([])

    limits =
      case Keyword.get(opts, :limits) do
        nil ->
          {:ok, limits} = Limits.new()
          limits

        %Limits{} = limits ->
          limits
      end

    {:ok, sink} = EventSink.start(:normal, limits, run_id: run_id)

    RunConfig.new(
      workflow_environment: workflow,
      missions: %{"default" => mission},
      input: %{},
      limits: limits,
      event_sink: sink,
      connector_snapshots: Keyword.get(opts, :connector_snapshots, [])
    )
  end

  defp project_run(source, config, run_id, run_ref) do
    {result, {:ok, events} = terminal_batch} = Kernel.run_and_events(source, config)
    {:ok, authority} = PublicationAuthority.authorize(run_ref, [], :normal, :normal)

    {:ok, outcome} =
      ExecutionOutcome.capture(
        result,
        terminal_batch,
        config.event_sink,
        nil,
        nil,
        nil,
        authority
      )

    {:ok, evidence} = ExecutionOutcome.open(outcome, authority)
    settlement = ArtifactPublisher.publish(evidence, authority)
    {status, command_outcome} = CommandRunOutcome.project(evidence, settlement, run_ref, true)
    {:ok, trace_log} = TraceLog.new(source: config.event_sink, max_result_bytes: 100_000)
    {:ok, counters} = TraceLog.query(trace_log, :counters, %{"run_id" => run_id})
    ^events = EventSink.events(config.event_sink)
    :ok = PublicationAuthority.close(authority)
    :ok = EventSink.stop(config.event_sink)
    {status, command_outcome, counters, events}
  end
end
