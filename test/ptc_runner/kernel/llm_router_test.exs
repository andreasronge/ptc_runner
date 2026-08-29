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
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.LLMCapability
  alias PtcRunner.Kernel.LLMReplay
  alias PtcRunner.Kernel.LLMRouter
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.ProviderSnapshot
  alias PtcRunner.Kernel.PublicationAuthority
  alias PtcRunner.Kernel.RoutedCapability
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.RunState
  alias PtcRunner.Kernel.RuntimeLimitDiagnostic
  alias PtcRunner.Kernel.TraceLog
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.Lisp.RetainedSize
  alias PtcRunner.TestSupport.StreamingInspection
  alias PtcRunner.TestSupport.TestHelpers

  test "routes by alias, uses the declared default, and strips model before invocation" do
    parent = self()

    fast = capability(parent, :fast, %{content: "fast", tokens: %{input: 2, output: 1}})

    strong =
      capability(parent, :strong, %{
        content: "strong",
        model: "adapter-spoof",
        tokens: %{input: 7, output: 3}
      })

    assert {:ok, router} =
             LLMRouter.new([
               route("fast", "llm_replay", "fast-v1", true, fast),
               route("strong", "llm", "strong-v2", false, strong)
             ])

    assert {:ok, explicit_config} = config(router, "routing-explicit")

    assert {:ok, %{value: %{"content" => "strong", "model" => "strong"}}} =
             Kernel.run(
               ~S|(return (llm/request {"model" "strong" "messages" []}))|,
               explicit_config
             )

    assert_receive {:strong, %{"messages" => []}}

    assert {:ok, default_config} = config(router, "routing-default")

    assert {:ok, %{value: %{"content" => "fast", "model" => "fast"}}} =
             Kernel.run(~S|(return (llm/request {"messages" []}))|, default_config)

    assert_receive {:fast, %{"messages" => []}}
  end

  test "custom workflow LLM retains its replay hash under private inspection" do
    leaf = capability(self(), :custom, %{content: "custom", tokens: %{input: 1, output: 1}})
    assert {:ok, router} = LLMRouter.new([route("custom", "custom", "custom-v1", true, leaf)])

    assert {:ok, inspection} =
             StreamingInspection.start(
               run_id: "routing-custom-inspection",
               trace_id: "routing-custom-inspection-trace"
             )

    assert {:ok, config} =
             config(router, "routing-custom-inspection", inspection_sink: inspection)

    assert {:ok, %{value: %{"content" => "custom"}}} =
             Kernel.run(~S|(return (llm/request {"messages" []}))|, config)

    assert_receive {:custom, %{"messages" => []}}
    assert {:ok, request_hash} = LLMReplay.request_hash(%{"messages" => []})
    assert {:ok, records} = StreamingInspection.records(inspection)

    assert input =
             Enum.find(records, fn record ->
               record["record_type"] == "capability-input" and
                 record["payload"]["name"] == "llm-request"
             end)

    assert input["payload"]["request_hash"] == request_hash
    assert :ok = InspectionSink.stop(inspection)
  end

  test "agent executes a complete tool call even when the provider reports length" do
    response =
      truncated_response(%{
        content: nil,
        tool_calls: [
          %{id: "complete", name: "run_ptc_lisp", args: %{"program" => "(return 42)"}}
        ],
        tokens: %{input: 10, output: 4_096}
      })

    leaf = capability(self(), :length_with_call, response)
    assert {:ok, router} = LLMRouter.new([route("hy3", "llm", "hy3-v1", true, leaf)])
    assert {:ok, config} = agent_router_config(router, "length-with-complete-call")

    assert {:ok, %{value: %{"ok" => true, "value" => 42}, usage: usage}} =
             Kernel.run(~S|(agent.core/run "Task" {"max_turns" 2})|, config)

    assert usage.protocol_errors == 0
  end

  test "agent fails an unusable length response with a branchable truncation diagnostic" do
    run_id = "model-output-truncated"
    run_ref = "cmd-00000000000000000000000000"

    response =
      truncated_response(%{
        content: "",
        tokens: %{input: 1_304, output: 4_096, total_cost: 0.002335}
      })

    leaf = capability(self(), :truncated, response)
    assert {:ok, router} = LLMRouter.new([route("hy3", "llm", "hy3-v1", true, leaf)])

    assert {:ok, inspection} =
             StreamingInspection.start(
               run_id: run_id,
               trace_id: "#{run_id}-inspection"
             )

    assert {:ok, config} = agent_router_config(router, run_id, inspection_sink: inspection)

    assert {:error, command_outcome, counters, events} =
             project_run(~S|(agent.core/run "Task" {"max_turns" 2})|, config, run_id, run_ref)

    assert command_outcome.exit_status == 6
    assert command_outcome.envelope["error"]["code"] == "model_output_truncated"
    assert command_outcome.envelope["error"]["retryable"] == false

    assert command_outcome.envelope["error"]["subject"] == %{
             "kind" => "provider",
             "name" => "hy3",
             "operation" => "execution",
             "occurrence" => nil
           }

    assert command_outcome.envelope["error"]["message"] =~
             "the request used configured max_tokens 4096"

    assert counters["llm_usage"] == [
             %{
               "alias" => "hy3",
               "installation_revision" => "hy3-v1",
               "calls" => 1,
               "successful_calls" => 1,
               "usage_calls" => 1,
               "missing_usage_calls" => 0,
               "usage_overflow" => false,
               "usage" => %{
                 "input" => 1_304,
                 "output" => 4_096,
                 "total_cost" => %{"currency" => "USD", "microunits" => 2_335}
               }
             }
           ]

    assert command_outcome.envelope["execution"]["usage"]["protocol_errors"] == 0

    assert %{data: stopped_data} =
             Enum.find(events, fn event ->
               event.type == "capability-stopped" and event.data.name == "llm-request"
             end)

    assert stopped_data.finish_reason == :length

    assert stopped_data.output_limit == %{
             "name" => "max_tokens",
             "value" => 4_096,
             "bindings" => ["configured"]
           }

    assert %{data: run_stopped} = Enum.find(events, &(&1.type == "run-stopped"))
    assert run_stopped.reason == :model_output_truncated
    assert run_stopped.limit == :max_tokens
    assert run_stopped.limit_value == 4_096
    assert run_stopped.limit_bindings == [:configured]
    assert run_stopped.alias == "hy3"

    assert {:ok, records} = StreamingInspection.records(inspection)

    assert output =
             Enum.find(records, fn record ->
               record["record_type"] == "capability-output" and
                 get_in(record, ["payload", "name"]) == "llm-request"
             end)

    assert get_in(output, ["payload", "result", "value", "model"]) == "hy3"
    assert get_in(output, ["payload", "result", "value", "finish_reason"]) == "length"

    assert get_in(output, ["payload", "result", "value", "output_limit"]) == %{
             "name" => "max_tokens",
             "value" => 4_096,
             "bindings" => ["configured"]
           }

    assert error = Enum.find(records, &(&1["record_type"] == "execution-error"))

    assert error["payload"]["details"] == %{
             "limit" => "max_tokens",
             "limit_value" => 4_096,
             "limit_bindings" => ["configured"],
             "alias" => "hy3"
           }

    assert :ok = InspectionSink.stop(inspection)
  end

  test "agent fails fast when length is proven but request-cap provenance is unavailable" do
    run_id = "model-output-truncated-no-cap"

    response = %{
      content: "",
      finish_reason: :length,
      tokens: %{input: 1_304, output: 4_096, total_cost: 0.002335}
    }

    leaf = capability(self(), :truncated_without_cap, response)
    assert {:ok, router} = LLMRouter.new([route("hy3", "llm", "hy3-v1", true, leaf)])

    assert {:ok, inspection} =
             StreamingInspection.start(
               run_id: run_id,
               trace_id: "#{run_id}-inspection"
             )

    assert {:ok, config} = agent_router_config(router, run_id, inspection_sink: inspection)

    assert {:error, command_outcome, counters, events} =
             project_run(
               ~S|(agent.core/run "Task" {"max_turns" 2})|,
               config,
               run_id,
               "cmd-00000000000000000000000000"
             )

    assert command_outcome.exit_status == 6
    assert command_outcome.envelope["error"]["code"] == "model_output_truncated"

    assert command_outcome.envelope["error"]["message"] ==
             "model output was truncated before producing a usable agent action"

    assert command_outcome.envelope["error"]["subject"]["name"] == "hy3"
    assert command_outcome.envelope["execution"]["usage"]["protocol_errors"] == 0
    assert hd(counters["llm_usage"])["successful_calls"] == 1

    assert %{data: stopped_data} =
             Enum.find(events, fn event ->
               event.type == "capability-stopped" and event.data.name == "llm-request"
             end)

    assert stopped_data.finish_reason == :length
    refute Map.has_key?(stopped_data, :output_limit)

    assert %{data: run_stopped} = Enum.find(events, &(&1.type == "run-stopped"))
    assert run_stopped.reason == :model_output_truncated
    assert run_stopped.alias == "hy3"
    refute Map.has_key?(run_stopped, :limit)

    assert {:ok, records} = StreamingInspection.records(inspection)
    assert error = Enum.find(records, &(&1["record_type"] == "execution-error"))
    assert error["payload"]["details"] == %{"alias" => "hy3"}
    assert :ok = InspectionSink.stop(inspection)
  end

  test "an oversized replay truncation cap cannot break command outcome sealing" do
    run_id = "oversized-model-output-limit"

    response = %{
      content: "",
      finish_reason: :length,
      output_limit: %{
        name: :max_tokens,
        value: Integer.pow(10, 1_024),
        bindings: [:configured]
      },
      tokens: %{input: 1, output: 1}
    }

    leaf = capability(self(), :oversized_truncation, response)
    assert {:ok, router} = LLMRouter.new([route("hy3", "llm_replay", "hy3-v1", true, leaf)])
    assert {:ok, config} = agent_router_config(router, run_id)

    assert {:error, command_outcome, _counters, _events} =
             project_run(
               ~S|(agent.core/run "Task" {"max_turns" 1})|,
               config,
               run_id,
               "cmd-00000000000000000000000000"
             )

    assert command_outcome.envelope["status"] == "error"
    refute command_outcome.envelope["error"]["code"] == "model_output_truncated"
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
             model: "expensive",
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

  test "post-resolution LLM failures carry the resolved installation alias" do
    timeout = ProviderError.new(:timeout, "provider timed out", retryable?: true)

    {:ok, failing} =
      LLMCapability.new(requester: fn _request -> {:error, timeout} end)

    {:ok, unused} =
      LLMCapability.new(requester: fn _request -> flunk("wrong model alias invoked") end)

    assert {:ok, explicit_router} =
             LLMRouter.new([
               route("chosen", "llm_replay", "chosen-v1", true, unused),
               route("other", "llm_replay", "other-v1", false, failing)
             ])

    assert {:ok, explicit_workflow} = WorkflowEnvironment.new(capabilities: [explicit_router])
    assert {:ok, limits} = Limits.new()
    assert {:ok, state} = RunState.start(limits)
    context = TestHelpers.dispatch_context(state, :workflow, 1_000)

    assert %{
             status: :error,
             kind: :provider_error,
             reason: :timeout,
             retryable?: true,
             model: "other"
           } =
             Dispatcher.dispatch(
               state,
               :workflow,
               explicit_workflow,
               "llm-request",
               %{"model" => "other", "messages" => []},
               context,
               nil,
               nil
             )

    assert {:ok, default_router} =
             LLMRouter.new([
               route("chosen", "llm_replay", "chosen-v1", true, failing),
               route("other", "llm_replay", "other-v1", false, unused)
             ])

    assert {:ok, default_workflow} = WorkflowEnvironment.new(capabilities: [default_router])

    assert %{
             status: :error,
             kind: :provider_error,
             reason: :timeout,
             retryable?: true,
             model: "chosen"
           } =
             Dispatcher.dispatch(
               state,
               :workflow,
               default_workflow,
               "llm-request",
               %{"messages" => []},
               context,
               nil,
               nil
             )

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
    assert command_outcome.envelope["error"]["code"] == "capability_quota_exceeded"
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

    assert command_outcome.envelope["error"]["code"] == "explicit_failure"
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

    assert command_outcome.envelope["error"]["code"] == "explicit_failure"
  end

  test "agent.core exhausts a per-alias cap as the named runtime diagnostic" do
    run_id = "max-calls-agent"
    run_ref = "cmd-00000000000000000000000000"

    continue = %{
      content: nil,
      tool_calls: [
        %{id: "continue", name: "run_ptc_lisp", args: %{"program" => "(def committed 42)"}}
      ]
    }

    leaf = capability(self(), :agent_capped, continue)

    assert {:ok, router} =
             LLMRouter.new([route("expensive", "llm", "expensive-v1", true, leaf, 1)])

    cases = [
      ~S|(agent.core/run "Task" {"max_turns" 2})|,
      ~S|(pmap (fn [_] (agent.core/run "Task" {"max_turns" 2})) [1])|,
      ~S|(pcalls #(agent.core/run "Task" {"max_turns" 2}))|
    ]

    for source <- cases do
      assert {:ok, fresh} = agent_router_config(router, run_id)

      assert {:error, command_outcome, _counters, events} =
               project_run(source, fresh, run_id, run_ref)

      assert {:ok, expected} = RuntimeLimitDiagnostic.max_calls_message("expensive", 1)
      assert command_outcome.envelope["error"]["code"] == "capability_quota_exceeded"
      assert command_outcome.envelope["error"]["message"] == expected

      assert Enum.any?(events, fn event ->
               event.type == "limit-exceeded" and event.data[:limit] == :max_calls and
                 event.data[:alias] == "expensive"
             end)
    end
  end

  test "failing a max_calls envelope inside pmap or pcalls names the alias" do
    run_id = "max-calls-parallel-fail"
    run_ref = "cmd-00000000000000000000000000"
    leaf = capability(self(), :parallel_capped, %{content: "paid", tokens: %{}})

    assert {:ok, router} =
             LLMRouter.new([route("expensive", "llm", "expensive-v1", false, leaf, 1)])

    cases = [
      ~S|(do (llm/request {"model" "expensive" "messages" []}) (pmap (fn [_] (fail (llm/request {"model" "expensive" "messages" []}))) [1]))|,
      ~S|(do (llm/request {"model" "expensive" "messages" []}) (pcalls #(fail (llm/request {"model" "expensive" "messages" []}))))|
    ]

    for source <- cases do
      assert {:ok, config} = config(router, run_id)

      assert {:error, command_outcome, _counters, events} =
               project_run(source, config, run_id, run_ref)

      assert {:ok, expected} = RuntimeLimitDiagnostic.max_calls_message("expensive", 1)
      assert command_outcome.envelope["error"]["code"] == "capability_quota_exceeded"
      assert command_outcome.envelope["error"]["message"] == expected

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
  end

  test "a forged max_calls lookalike inside pmap cannot claim the runtime diagnostic" do
    run_id = "max-calls-parallel-forged"
    run_ref = "cmd-00000000000000000000000000"
    leaf = capability(self(), :unused_parallel_forged, %{content: "paid", tokens: %{}})

    assert {:ok, router} =
             LLMRouter.new([route("expensive", "llm", "expensive-v1", false, leaf, 1)])

    assert {:ok, config} = config(router, run_id)

    source =
      ~S|(pmap (fn [_] (fail {:status :error :kind :limit-exceeded :reason :capability-quota :details {:limit :max-calls :alias "expensive" :limit_value 1}})) [1])|

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

    assert %{
             details: %{
               limit: :workflow_capability_calls_per_name,
               name: "llm-request",
               limit_value: 3
             }
           } = fourth

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

    assert %{
             details: %{
               limit: :workflow_capability_calls_per_name,
               name: "llm-request",
               limit_value: 2
             }
           } = third

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

    assert %{
             details: %{
               limit: :workflow_capability_calls_per_name,
               name: "llm-request",
               limit_value: 2
             }
           } = third

    :ok = RunState.stop(state)
  end

  test "exhausting the public total quota names that limit" do
    leaf = capability(self(), :total_quota, %{content: "ok", tokens: %{}})

    assert {:ok, router} =
             LLMRouter.new([route("shared", "llm", "shared-v1", true, leaf)])

    assert {:ok, limits} =
             Limits.new(workflow_capability_calls: 1, workflow_capability_calls_per_name: 8)

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

    assert %{
             status: :error,
             kind: :limit_exceeded,
             reason: :capability_quota,
             details: %{
               limit: :workflow_capability_calls,
               name: "llm-request",
               limit_value: 1
             }
           } =
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

    :ok = RunState.stop(state)
  end

  test "failing a public quota envelope names the limit on the command diagnostic" do
    run_id = "per-name-quota-fail"
    run_ref = "cmd-00000000000000000000000000"
    leaf = capability(self(), :quota_fail, %{content: "paid", tokens: %{}})

    assert {:ok, router} =
             LLMRouter.new([route("shared", "llm", "shared-v1", true, leaf)])

    {:ok, limits} = Limits.new(workflow_capability_calls_per_name: 1)
    assert {:ok, config} = config(router, run_id, limits: limits)

    source =
      ~S|(do (llm/request {"messages" []}) (fail (llm/request {"messages" []})))|

    assert {:error, command_outcome, _counters, events} =
             project_run(source, config, run_id, run_ref)

    assert {:ok, expected} =
             RuntimeLimitDiagnostic.capability_quota_message(
               :workflow_capability_calls_per_name,
               "llm-request",
               1
             )

    assert command_outcome.envelope["error"]["code"] == "capability_quota_exceeded"
    assert command_outcome.envelope["error"]["message"] == expected

    assert [
             %{
               type: "limit-exceeded",
               data: %{
                 reason: :capability_quota,
                 limit: :workflow_capability_calls_per_name,
                 name: "llm-request",
                 limit_value: 1
               }
             }
           ] = Enum.filter(events, &(&1.type == "limit-exceeded"))
  end

  test "an application-authored public quota lookalike cannot claim the runtime diagnostic" do
    run_id = "per-name-quota-forged"
    run_ref = "cmd-00000000000000000000000000"
    leaf = capability(self(), :unused_quota_forged, %{content: "paid", tokens: %{}})

    assert {:ok, router} =
             LLMRouter.new([route("shared", "llm", "shared-v1", true, leaf)])

    assert {:ok, config} = config(router, run_id)

    source =
      ~S|(fail {:status :error :kind :limit-exceeded :reason :capability-quota :details {:limit :workflow-capability-calls-per-name :name "llm-request" :limit_value 1}})|

    assert {:error, command_outcome, _counters, _events} =
             project_run(source, config, run_id, run_ref)

    assert command_outcome.envelope["error"]["code"] == "explicit_failure"
  end

  test "agent.core exhausts a public per-name quota as the named runtime diagnostic" do
    run_id = "per-name-quota-agent"
    run_ref = "cmd-00000000000000000000000000"

    continue = %{
      content: nil,
      tool_calls: [
        %{id: "continue", name: "run_ptc_lisp", args: %{"program" => "(def committed 42)"}}
      ]
    }

    leaf = capability(self(), :agent_quota, continue)

    assert {:ok, router} =
             LLMRouter.new([route("shared", "llm", "shared-v1", true, leaf)])

    {:ok, limits} = Limits.new(workflow_capability_calls_per_name: 1)

    {:ok, components} =
      Library.components(
        ~w(agent.core agent.failure agent.feedback agent.machine agent.native agent.prompt agent.retry kernel llm result workflow.event)
      )

    assert {:ok, config} = run_config(router, run_id, components, limits: limits)

    assert {:error, command_outcome, _counters, events} =
             project_run(~S|(agent.core/run "Task" {"max_turns" 2})|, config, run_id, run_ref)

    assert {:ok, expected} =
             RuntimeLimitDiagnostic.capability_quota_message(
               :workflow_capability_calls_per_name,
               "llm-request",
               1
             )

    assert command_outcome.envelope["error"]["code"] == "capability_quota_exceeded"
    assert command_outcome.envelope["error"]["message"] == expected

    assert Enum.any?(events, fn event ->
             event.type == "limit-exceeded" and
               event.data[:limit] == :workflow_capability_calls_per_name and
               event.data[:name] == "llm-request"
           end)
  end

  test "failing an aggregate token-budget envelope names the reservation on the command diagnostic" do
    run_id = "token-budget-fail"
    run_ref = "cmd-00000000000000000000000000"
    leaf = capability(self(), :token_budget_fail, %{content: "paid", tokens: %{}})

    assert {:ok, router} =
             LLMRouter.new([route("primary", "llm", "primary-v1", true, leaf)])

    {:ok, limits} = Limits.new(llm_total_tokens: 1)
    assert {:ok, config} = config(router, run_id, limits: limits)

    assert {:error, command_outcome, _counters, events} =
             project_run(
               ~S|(fail (llm/request {"messages" []}))|,
               config,
               run_id,
               run_ref
             )

    assert {:ok, expected} = RuntimeLimitDiagnostic.budget_message(:llm_total_tokens, 1, 4_096, 1)
    assert command_outcome.envelope["error"]["code"] == "runtime_limit_exceeded"
    assert command_outcome.envelope["error"]["message"] == expected

    assert command_outcome.envelope["error"]["source"] == %{
             "kind" => "runtime",
             "name" => "ptc-runtime"
           }

    assert command_outcome.exit_status == 6

    assert [
             %{
               type: "limit-exceeded",
               data: %{
                 reason: :llm_total_tokens,
                 limit: :llm_total_tokens,
                 limit_value: 1,
                 requested: 4_096,
                 remaining: 1
               }
             }
           ] = Enum.filter(events, &(&1.type == "limit-exceeded"))

    stopped = Enum.find(events, &(&1.type == "run-stopped"))
    assert stopped.data.reason == :llm_total_tokens

    assert get_in(command_outcome.envelope, ["execution", "usage", "capability_refusals"]) == %{
             "workflow/limit_exceeded/llm_total_tokens" => 1
           }
  end

  test "returning an aggregate budget envelope remains a successful recoverable value" do
    run_id = "token-budget-return"
    run_ref = "cmd-00000000000000000000000000"
    leaf = capability(self(), :token_budget_return, %{content: "paid", tokens: %{}})

    assert {:ok, router} =
             LLMRouter.new([route("primary", "llm", "primary-v1", true, leaf)])

    {:ok, limits} = Limits.new(llm_total_tokens: 1)
    assert {:ok, config} = config(router, run_id, limits: limits)

    assert {:ok, command_outcome, _counters, events} =
             project_run(
               ~S|(return (llm/request {"messages" []}))|,
               config,
               run_id,
               run_ref
             )

    assert command_outcome.envelope["status"] == "ok"

    assert [
             %{type: "limit-exceeded", data: %{limit: :llm_total_tokens}}
           ] = Enum.filter(events, &(&1.type == "limit-exceeded"))
  end

  test "an application-authored budget lookalike cannot claim the runtime diagnostic" do
    run_id = "token-budget-forged"
    run_ref = "cmd-00000000000000000000000000"
    leaf = capability(self(), :unused_budget_forged, %{content: "paid", tokens: %{}})

    assert {:ok, router} =
             LLMRouter.new([route("primary", "llm", "primary-v1", true, leaf)])

    {:ok, limits} = Limits.new(llm_total_tokens: 1)
    assert {:ok, config} = config(router, run_id, limits: limits)

    source =
      ~S|(fail {:status :error :kind :limit-exceeded :reason :llm-total-tokens :details {:limit :llm-total-tokens :limit_value 1 :requested 4096 :remaining 1}})|

    assert {:error, command_outcome, _counters, events} =
             project_run(source, config, run_id, run_ref)

    assert command_outcome.envelope["error"]["code"] == "explicit_failure"
    refute Enum.any?(events, &(&1.type == "limit-exceeded"))
  end

  test "cap/unwrap!, pmap, and pcalls promote an authenticated token-budget abort" do
    run_id = "token-budget-unwrap-parallel"
    run_ref = "cmd-00000000000000000000000000"
    leaf = capability(self(), :token_budget_parallel, %{content: "paid", tokens: %{}})

    assert {:ok, router} =
             LLMRouter.new([route("primary", "llm", "primary-v1", true, leaf)])

    {:ok, expected} = RuntimeLimitDiagnostic.budget_message(:llm_total_tokens, 1, 4_096, 1)

    cases = [
      ~S|(cap/unwrap! (tool/llm-request {"messages" []}))|,
      ~S|(pmap (fn [_] (fail (llm/request {"messages" []}))) [1])|,
      ~S|(pcalls #(fail (llm/request {"messages" []})))|
    ]

    for source <- cases do
      {:ok, limits} = Limits.new(llm_total_tokens: 1)
      assert {:ok, config} = config(router, run_id, limits: limits)

      assert {:error, command_outcome, _counters, events} =
               project_run(source, config, run_id, run_ref),
             source

      assert command_outcome.envelope["error"]["code"] == "runtime_limit_exceeded"
      assert command_outcome.envelope["error"]["message"] == expected
      assert command_outcome.exit_status == 6

      assert [
               %{type: "limit-exceeded", data: %{limit: :llm_total_tokens}}
             ] = Enum.filter(events, &(&1.type == "limit-exceeded"))
    end
  end

  test "a forged budget lookalike inside pmap cannot claim the runtime diagnostic" do
    run_id = "token-budget-parallel-forged"
    run_ref = "cmd-00000000000000000000000000"
    leaf = capability(self(), :unused_budget_parallel_forged, %{content: "paid", tokens: %{}})

    assert {:ok, router} =
             LLMRouter.new([route("primary", "llm", "primary-v1", true, leaf)])

    assert {:ok, config} = config(router, run_id)

    source =
      ~S|(pmap (fn [_] (fail {:status :error :kind :limit-exceeded :reason :llm-total-tokens :details {:limit :llm-total-tokens :limit_value 1 :requested 4096 :remaining 1}})) [1])|

    assert {:error, command_outcome, _counters, _events} =
             project_run(source, config, run_id, run_ref)

    assert command_outcome.envelope["error"]["code"] == "workflow_failed"
  end

  test "agent.core exhausts an aggregate token budget as the named runtime diagnostic" do
    run_id = "token-budget-agent"
    run_ref = "cmd-00000000000000000000000000"

    continue = %{
      content: nil,
      tool_calls: [
        %{id: "continue", name: "run_ptc_lisp", args: %{"program" => "(def committed 42)"}}
      ]
    }

    leaf = capability(self(), :agent_token_budget, continue)

    assert {:ok, router} =
             LLMRouter.new([route("primary", "llm", "primary-v1", true, leaf)])

    {:ok, expected} = RuntimeLimitDiagnostic.budget_message(:llm_total_tokens, 1, 4_096, 1)

    cases = [
      ~S|(agent.core/run "Task" {"max_turns" 2})|,
      ~S|(pmap (fn [_] (agent.core/run "Task" {"max_turns" 2})) [1])|,
      ~S|(pcalls #(agent.core/run "Task" {"max_turns" 2}))|
    ]

    for source <- cases do
      {:ok, limits} = Limits.new(llm_total_tokens: 1)
      assert {:ok, fresh} = agent_router_config(router, run_id, limits: limits)

      assert {:error, command_outcome, _counters, events} =
               project_run(source, fresh, run_id, run_ref),
             source

      assert command_outcome.envelope["error"]["code"] == "runtime_limit_exceeded"
      assert command_outcome.envelope["error"]["message"] == expected
      assert command_outcome.exit_status == 6

      assert Enum.any?(events, fn event ->
               event.type == "limit-exceeded" and event.data[:limit] == :llm_total_tokens
             end)

      stopped = Enum.find(events, &(&1.type == "run-stopped"))
      assert stopped.data.reason == :llm_total_tokens
    end
  end

  test "failing an aggregate cost-budget envelope names the reservation on the command diagnostic" do
    run_id = "cost-budget-fail"
    run_ref = "cmd-00000000000000000000000000"
    leaf = priced_capability(self(), :cost_budget_fail, %{content: "paid", tokens: %{}})

    assert {:ok, router} =
             LLMRouter.new([cost_route("primary", true, leaf)])

    {:ok, limits} = Limits.new(llm_cost_microusd: 2_400)
    assert {:ok, config} = config(router, run_id, limits: limits)

    assert {:error, command_outcome, _counters, events} =
             project_run(
               ~S|(fail (llm/request {"messages" []}))|,
               config,
               run_id,
               run_ref
             )

    assert {:ok, expected} =
             RuntimeLimitDiagnostic.budget_message(:llm_cost_microusd, 2_400, 2_419, 2_400)

    assert command_outcome.envelope["error"]["code"] == "runtime_limit_exceeded"
    assert command_outcome.envelope["error"]["message"] == expected
    assert command_outcome.exit_status == 6

    assert [
             %{
               type: "limit-exceeded",
               data: %{
                 reason: :llm_cost_microusd,
                 limit: :llm_cost_microusd,
                 limit_value: 2_400,
                 requested: 2_419,
                 remaining: 2_400
               }
             }
           ] = Enum.filter(events, &(&1.type == "limit-exceeded"))

    stopped = Enum.find(events, &(&1.type == "run-stopped"))
    assert stopped.data.reason == :llm_cost_microusd
  end

  test "exhausting protocol_errors names the limit on the command diagnostic" do
    run_id = "protocol-errors-named"
    run_ref = "cmd-00000000000000000000000000"
    leaf = capability(self(), :unused_protocol, %{content: "unused", tokens: %{}})

    assert {:ok, router} =
             LLMRouter.new([route("shared", "llm", "shared-v1", true, leaf)])

    {:ok, limits} = Limits.new(protocol_errors: 1)

    {:ok, components} = Library.components(~w(llm cap workflow.event))
    assert {:ok, config} = run_config(router, run_id, components, limits: limits)

    source = """
    (do
      (workflow.event/annotate 1 {"n" 1})
      (workflow.event/annotate 2 {"n" 1})
      (return true))
    """

    assert {:error, command_outcome, _counters, events} =
             project_run(source, config, run_id, run_ref)

    assert {:ok, expected} = RuntimeLimitDiagnostic.protocol_errors_message(1)
    assert command_outcome.envelope["error"]["code"] == "runtime_limit_exceeded"
    assert command_outcome.envelope["error"]["message"] == expected

    assert [
             %{
               data: %{
                 reason: :protocol_errors,
                 limit: :protocol_errors,
                 limit_value: 1
               }
             }
           ] = Enum.filter(events, &(&1.type == "limit-exceeded"))
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

    assert Enum.count(
             results,
             &match?({:ok, reservation_id} when is_reference(reservation_id), &1)
           ) ==
             1

    assert Enum.count(results, &(&1 == {:error, :route_call_limit})) == 1
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

    assert Enum.all?(
             results,
             &match?({:ok, reservation_id} when is_reference(reservation_id), &1)
           )

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
      result_attributes: %{},
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

    assert {:ok, forged_result} =
             RoutedCapability.new(
               name: "forged-result-route",
               input_schema: %{"type" => "object"},
               routes: %{"leaf" => leaf},
               resolve: fn _arguments ->
                 {:ok, %{invocation | event_attributes: %{}, result_attributes: %{model: "hy3"}}}
               end
             )

    assert {:error, :resolver_unavailable} = RoutedCapability.resolve(forged_result, %{})

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

  test "live routes reject malformed reservation tariffs" do
    leaf = capability(self(), :unused, %{content: "unused"})
    valid = route("primary", "llm", "v1", true, leaf)

    for tariff <- [
          %{},
          %{currency: "EUR", id: "v1"},
          %{currency: "USD", id: ""},
          %{currency: "USD", id: String.duplicate("x", 129)},
          %{currency: "USD", id: "v1", extra: true}
        ] do
      assert {:error, :invalid_llm_router} =
               LLMRouter.new([Map.put(valid, :reservation_tariff, tariff)])
    end
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

    assert {:ok, command_outcome, counters, events} =
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
               "usage_overflow" => false,
               "usage" => %{
                 "input" => 11,
                 "output" => 5,
                 "total_cost" => %{"currency" => "USD", "microunits" => 4_200}
               }
             }
           ]

    assert envelope_usage["llm_usage_by_model"] == [
             %{
               "resolved_model" => "openrouter:metered/model",
               "calls" => 1,
               "successful_calls" => 1,
               "usage_calls" => 1,
               "missing_usage_calls" => 0,
               "usage_overflow" => false,
               "usage" => %{
                 "input" => 11,
                 "output" => 5,
                 "total_cost" => %{"currency" => "USD", "microunits" => 4_200}
               }
             }
           ]

    assert envelope_usage["unattributed_model_calls"] == 0

    assert_spend_matches(events, envelope_usage, %{
      "state" => "available",
      "input" => 11,
      "output" => 5,
      "total_cost" => %{"currency" => "USD", "microunits" => 4_200}
    })
  end

  test "a failed run envelope retains LLM usage completed before the execution error" do
    run_id = "routing-envelope-failure"
    run_ref = "cmd-00000000000000000000000000"
    leaf = capability(self(), :failed_envelope, %{content: "answer", tokens: %{input: 7}})
    assert {:ok, router} = LLMRouter.new([route("writer", "llm", "writer-v1", false, leaf)])

    snapshot = TestHelpers.llm_snapshot("writer", "writer-v1", "openrouter:writer/model")
    assert {:ok, config} = config(router, run_id, connector_snapshots: [snapshot])

    source = ~S|(do (llm/request {"messages" []}) (fail "after paid call"))|

    assert {:error, command_outcome, counters, events} =
             project_run(source, config, run_id, run_ref)

    assert command_outcome.envelope["error"]["code"] == "explicit_failure"
    usage = command_outcome.envelope["execution"]["usage"]
    assert usage["llm_usage_state"] == "available"
    assert usage["llm_usage"] == counters["llm_usage"]
    assert usage["llm_usage_by_model"] == counters["llm_usage_by_model"]
    assert usage["unattributed_model_calls"] == 0
    assert get_in(usage, ["llm_usage", Access.at(0), "usage", "input"]) == 7
    assert_spend_matches(events, usage, %{"state" => "incomplete"})
  end

  test "an unpriced run envelope retains tokens without inventing zero cost" do
    run_id = "routing-envelope-unpriced"
    run_ref = "cmd-00000000000000000000000000"

    leaf =
      capability(self(), :unpriced_envelope, %{
        content: "answer",
        tokens: %{input: 13, output: 8}
      })

    assert {:ok, router} = LLMRouter.new([route("writer", "llm", "writer-v1", false, leaf)])
    assert {:ok, config} = config(router, run_id)

    assert {:ok, command_outcome, _counters, events} =
             project_run(~S|(return (llm/request {"messages" []}))|, config, run_id, run_ref)

    usage = command_outcome.envelope["execution"]["usage"]

    assert_spend_matches(events, usage, %{
      "state" => "unpriced",
      "input" => 13,
      "output" => 8
    })

    refute Map.has_key?(usage["llm_spend"], "total_cost")
  end

  test "a sealed run without LLM calls publishes an available empty summary" do
    run_id = "routing-envelope-empty"
    run_ref = "cmd-00000000000000000000000000"
    leaf = capability(self(), :unused_envelope, %{content: "unused", tokens: %{}})
    assert {:ok, router} = LLMRouter.new([route("unused", "llm", "unused-v1", false, leaf)])
    assert {:ok, config} = config(router, run_id)

    assert {:ok, command_outcome, counters, events} =
             project_run(~S|(return 42)|, config, run_id, run_ref)

    usage = command_outcome.envelope["execution"]["usage"]
    assert usage["llm_usage_state"] == "available"
    assert usage["llm_usage"] == []
    assert usage["llm_usage_by_model"] == []
    assert usage["unattributed_model_calls"] == 0

    assert Map.take(usage, ~w(llm_usage llm_usage_by_model unattributed_model_calls)) ==
             Map.take(counters, ~w(llm_usage llm_usage_by_model unattributed_model_calls))

    assert_spend_matches(events, usage, %{"state" => "empty"})
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
    assert error.kind == :usage_unavailable
  end

  test "the response boundary measures the final fixed-point usage object" do
    raw = %{
      "content" => "answer",
      "tokens" => %{"input" => 1, "output" => 2, "total_cost" => 0}
    }

    normalized =
      put_in(raw, ["tokens", "total_cost"], %{
        "currency" => "USD",
        "microunits" => 0
      })

    raw_bytes = RetainedSize.bytes_with_cap(raw, 10_000)
    normalized_bytes = RetainedSize.bytes_with_cap(normalized, 10_000)
    assert normalized_bytes > raw_bytes

    assert {:ok, capability} =
             LLMCapability.new(
               requester: fn _request -> {:ok, raw} end,
               max_response_bytes: raw_bytes
             )

    assert {:error, error} = capability.callback.(%{"messages" => []})
    assert error.kind == :invalid_request
    assert error.details == "LLM response exceeded its boundary"
  end

  test "an oversized response sub-binary is rejected before retention" do
    parent = String.duplicate("x", 4_096)
    content = binary_part(parent, 0, 2_048)
    assert :binary.referenced_byte_size(content) == byte_size(parent)

    assert {:ok, capability} =
             LLMCapability.new(
               requester: fn _request -> {:ok, %{content: content}} end,
               max_response_bytes: 512
             )

    assert {:error, error} = capability.callback.(%{"messages" => []})
    assert error.kind == :invalid_request
    assert error.details == "LLM response exceeded its boundary"
  end

  test "missing promised usage is a non-retryable dispatched usage failure" do
    assert {:ok, capability} =
             LLMCapability.new(
               requester: fn _request -> {:ok, %{content: "answer"}} end,
               usage_guarantees: %{tokens: true, cost_currency: "USD"}
             )

    assert {:error, error} = capability.callback.(%{"messages" => []})
    assert error.kind == :usage_unavailable
    assert error.retryable? == false
    assert error.dispatch_provenance == :dispatched

    assert {:ok, unpriced} =
             LLMCapability.new(
               requester: fn _request ->
                 {:ok, %{content: "answer", tokens: %{input: 1, output: 2}}}
               end,
               usage_guarantees: %{tokens: true, cost_currency: nil}
             )

    assert {:ok, %{"tokens" => %{"input" => 1, "output" => 2}}} =
             unpriced.callback.(%{"messages" => []})
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

  defp priced_capability(parent, tag, response) do
    {:ok, capability} =
      LLMCapability.new(
        requester: fn request ->
          send(parent, {tag, request})
          {:ok, response}
        end,
        usage_guarantees: %{tokens: true, cost_currency: "USD"}
      )

    capability
  end

  defp route(alias_name, source, revision, default?, capability, max_calls \\ nil) do
    route = %{
      alias: alias_name,
      source: source,
      installation_revision: revision,
      default?: default?,
      capability: capability,
      max_calls: max_calls
    }

    if source == "llm" do
      Map.merge(route, %{
        output_tokens: 4_096,
        reservation_bound: fn _request, _tariff ->
          {:ok, %{total_tokens: 4_096, cost: nil}}
        end
      })
    else
      route
    end
  end

  defp cost_route(alias_name, default?, capability) do
    %{
      alias: alias_name,
      source: "llm",
      installation_revision: alias_name <> "-v1",
      default?: default?,
      capability: capability,
      max_calls: nil,
      output_tokens: 4_096,
      reservation_tariff: %{currency: "USD", id: "t1"},
      reservation_bound: fn _request, tariff ->
        {:ok,
         %{
           total_tokens: 4_096,
           cost: %{currency: "USD", microunits: 2_419, tariff_id: tariff.id}
         }}
      end
    }
  end

  defp truncated_response(response) do
    Map.merge(response, %{
      finish_reason: :length,
      output_limit: %{
        name: :max_tokens,
        value: 4_096,
        bindings: [:configured]
      }
    })
  end

  defp config(router, run_id, opts \\ []) do
    {:ok, components} = Library.resolve_components([{:library, "llm"}, {:library, "cap"}])
    run_config(router, run_id, components, opts)
  end

  defp agent_router_config(router, run_id, opts \\ []) do
    {:ok, components} =
      Library.components(
        ~w(agent.core agent.failure agent.feedback agent.machine agent.native agent.prompt agent.retry kernel llm result workflow.event)
      )

    run_config(router, run_id, components, opts)
  end

  defp run_config(router, run_id, components, opts) do
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
      inspection_sink: Keyword.get(opts, :inspection_sink),
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

  defp assert_spend_matches(events, envelope_usage, expected) do
    stopped = Enum.find(events, &(&1.type == "run-stopped"))
    trace_spend = stopped.data.usage.llm_spend
    assert trace_spend == expected
    assert envelope_usage["llm_spend"] == expected
    assert DeterministicJSON.encode(trace_spend) == DeterministicJSON.encode(expected)
  end
end
