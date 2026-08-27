defmodule PtcRunner.Kernel.AgentCoreCharacterizationTest do
  @moduledoc """
  Integration characterization of the shipped `agent.core` loop.

  These cases lock public outcomes, transcripts, requests, events, usage,
  inspection records, failure precedence, unsafe-closing behavior, and result
  validation before the loop is extracted into an explicit state machine.
  They are mutation-sensitive: a phase-boundary that stops transitioning, a
  dropped provider spelling, a reset `closing?` flag, or a skipped prompt
  transition fails an exact envelope or transcript assertion.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.LLMCapability
  alias PtcRunner.Kernel.LLMRouter
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.Lisp
  alias PtcRunner.Lisp.TrustedTool
  alias PtcRunner.TestSupport.StreamingInspection

  import PtcRunner.TestSupport.AgentFixtures,
    only: [mission_with_source: 2, replay_alias_route: 3, replay_alias_router: 2]

  @provider_kinds [
    :denied,
    :not_found,
    :unavailable,
    :invalid_request,
    :internal,
    :domain_error,
    :invalid_result,
    :authentication_failed,
    :payment_required,
    :rate_limited,
    :tool_calling_unsupported,
    :timeout,
    :transport_error
  ]

  @kebab_provider_reasons [
    "denied",
    "not-found",
    "unavailable",
    "invalid-request",
    "internal",
    "domain-error",
    "invalid-result",
    "authentication-failed",
    "payment-required",
    "rate-limited",
    "tool-calling-unsupported",
    "timeout",
    "transport-error"
  ]

  @kebab_protocol_reasons ["unknown-model-alias", "invalid-model-alias", "model-alias-required"]

  @underscore_protocol_reasons [
    "unknown_model_alias",
    "invalid_model_alias",
    "model_alias_required"
  ]

  @kebab_timeout_reasons ["provider-timeout", "llm-request-timeout"]

  @underscore_timeout_reasons ["provider_timeout", "llm_request_timeout"]

  describe "last turn of a non-final phase" do
    test "a protocol error transitions with correlated transcript and phase bookkeeping" do
      responses = [
        %{content: "I will explain the approach before calling.", tool_calls: []},
        tool_call("synthesize-1", "(return 42)")
      ]

      {:ok, explore} = mission_with_source("debug.explore", "(defn evidence [] 7)")
      {:ok, synthesize} = MissionEnvironment.new([])

      {:ok, config} =
        agent_config(responses,
          missions: %{"explore" => explore, "synthesize" => synthesize}
        )

      assert {:ok, %{value: 42, usage: usage}} = Kernel.run(phased_source(), config)
      assert usage.capability_calls.workflow["llm-request"] == 2
      assert usage.subordinate_evaluations == 1

      assert_receive {:agent_request, explore_request}
      assert_receive {:agent_request, synthesize_request}
      refute_receive {:agent_request, _third}

      assert explore_request["system"] =~ "debug.explore/evidence"
      refute synthesize_request["system"] =~ "debug.explore/evidence"

      assert Enum.any?(synthesize_request["messages"], fn message ->
               message["role"] == "assistant" and
                 message["content"] == "I will explain the approach before calling."
             end)

      assert Enum.any?(synthesize_request["messages"], fn message ->
               message["role"] == "user" and
                 is_binary(message["content"]) and
                 String.contains?(message["content"], "Protocol error:")
             end)

      assert List.last(synthesize_request["messages"])["content"] =~ "PHASE TRANSITION"

      assert List.last(synthesize_request["messages"])["content"] =~
               "synthesize from retained evidence"

      assert agent_actions(config) == [
               action(0, "protocol-error", 0, 0, "explore"),
               action(1, "tool-call", 1, 0, "synthesize")
             ]
    end

    test "a retryable evaluation error transitions instead of terminating the run" do
      responses = [
        tool_call("boom", ~S|(+ 1 "x")|),
        tool_call("synthesize-1", "(return 42)")
      ]

      {:ok, explore} = MissionEnvironment.new([])
      {:ok, synthesize} = MissionEnvironment.new([])

      {:ok, config} =
        agent_config(responses,
          missions: %{"explore" => explore, "synthesize" => synthesize}
        )

      assert {:ok, %{value: 42, usage: usage}} = Kernel.run(phased_source(), config)
      assert usage.capability_calls.workflow["llm-request"] == 2
      assert usage.subordinate_evaluations == 2

      assert_receive {:agent_request, _explore_request}
      assert_receive {:agent_request, synthesize_request}
      refute_receive {:agent_request, _third}

      assert Enum.any?(synthesize_request["messages"], fn message ->
               message["role"] == "tool" and message["tool_call_id"] == "boom" and
                 message["content"] =~ "did not return successfully"
             end)

      assert List.last(synthesize_request["messages"])["content"] =~ "PHASE TRANSITION"

      assert agent_actions(config) == [
               action(0, "tool-call", 0, 0, "explore"),
               action(1, "tool-call", 1, 0, "synthesize")
             ]
    end

    test "terminal_only on a non-final phase is refused before any provider request" do
      {:ok, config} = agent_config([])

      source = ~S"""
      (agent.core/run-phased-result-value
        "Decide."
        {"phases"
         [{"mission" "default" "max_turns" 1 "terminal_only" true}
          {"mission" "default" "max_turns" 1}]})
      """

      assert {:error,
              %{
                kind: :workflow_failed,
                reason: :explicit_failure,
                details: %{failure_kind: "invalid-agent-config"}
              }} = Kernel.run(source, config)

      refute_receive {:agent_request, _request}
    end

    test "a terminal-source rejection on the last turn of a final phase terminates" do
      responses = [
        tool_call("nonterminal", ~S|(doc "text containing (return 42)")|),
        tool_call("should-not-run", "(return 1)")
      ]

      {:ok, mission} = MissionEnvironment.new([])
      {:ok, config} = agent_config(responses, missions: %{"synthesize" => mission})

      source = ~S"""
      (agent.core/run-phased-result-value
        "Decide from retained evidence."
        {"phases"
         [{"mission" "synthesize" "max_turns" 1 "terminal_only" true}]})
      """

      assert {:error,
              %{
                kind: :workflow_failed,
                reason: :runtime_limit_exceeded,
                details: %{
                  limit: :agent_turns,
                  limit_value: 1,
                  limit_reason: :terminal_source_required
                }
              }} = Kernel.run(source, config)

      assert_receive {:agent_request, first}
      refute_receive {:agent_request, _second}
      assert first["system"] =~ "TERMINAL-ONLY PHASE"
    end

    test "an unsafe failure transitions with closing? preserved into the next phase" do
      parent = self()

      unsafe = tool_call("unsafe", ~S|(do (tool/commit {}) (+ {} 1))|)

      {:ok, commit} =
        Capability.new(
          name: "commit",
          effect: :write,
          input_schema: %{"type" => "object"},
          callback: fn _ ->
            send(parent, :commit_called)
            {:ok, 42}
          end
        )

      {:ok, note} =
        Capability.new(
          name: "note",
          effect: :read,
          input_schema: %{"type" => "object"},
          callback: fn _ -> {:ok, :noted} end
        )

      {:ok, explore} = MissionEnvironment.new(capabilities: [commit])
      {:ok, synthesize} = MissionEnvironment.new(capabilities: [commit, note])

      {:ok, config} =
        agent_config([unsafe, unsafe, tool_call("recovered", ~S|(return "ok")|)],
          missions: %{"explore" => explore, "synthesize" => synthesize}
        )

      source = ~S"""
      (return
        (agent.core/run-outcome
          "Close out"
          {"phases"
           [{"mission" "explore" "max_turns" 1}
            {"mission" "synthesize" "max_turns" 2 "instruction" "synthesize from retained evidence."}]}))
      """

      assert {:ok,
              %{
                value: %{
                  "status" => "subject-failure",
                  "kind" => "non-retryable-evaluation"
                },
                usage: usage
              }} = Kernel.run(source, config)

      assert usage.capability_calls.workflow["llm-request"] == 2
      assert_receive :commit_called
      assert_receive :commit_called
      refute_receive :commit_called
      assert_receive {:agent_request, first}
      assert_receive {:agent_request, second}
      refute_receive {:agent_request, _third}

      assert List.last(second["messages"])["content"] =~ "PHASE TRANSITION"

      assert Enum.any?(second["messages"], fn message ->
               is_binary(message["content"]) and
                 String.contains?(message["content"], "cannot be retried")
             end)

      assert agent_actions(config) == [
               action(0, "tool-call", 0, 0, "explore"),
               action(1, "tool-call", 1, 0, "synthesize")
             ]

      refute first["system"] =~ "(tool/note {})"
      assert second["system"] =~ "(tool/note {})"
    end
  end

  describe "provider, protocol, and timeout taxonomy" do
    for kind <- @provider_kinds do
      test "run-outcome returns authenticated #{kind} envelopes for underscore Kernel spellings" do
        assert_kernel_provider_reason(unquote(kind))
      end
    end

    test "run-outcome returns unknown_model_alias as a provider-failure" do
      {:ok, leaf} =
        LLMCapability.new(requester: fn _ -> flunk("missing alias must not dispatch") end)

      {:ok, router} = alias_router(leaf)

      {outcome, fail_fast, records, events, usage} =
        routed_pair(router, "missing", :unknown_alias)

      error = %{
        "status" => "error",
        "kind" => "protocol_error",
        "reason" => "unknown_model_alias",
        "details" => "unknown model alias \"missing\"; selected aliases are: chosen (default)",
        "retryable?" => false
      }

      assert_provider_failure_outcome(outcome, "missing", error)
      assert llm_request_output(records) == nil
      assert fail_fast_unauthenticated?(fail_fast)
      assert usage.capability_calls.workflow["llm-request"] in [nil, 0]

      refute Enum.any?(
               events,
               &(&1.type == "capability-started" and &1.data[:name] == "llm-request")
             )
    end

    test "a non-string model is a prelude contract error, not invalid_model_alias" do
      {:ok, leaf} =
        LLMCapability.new(requester: fn _ -> flunk("non-string model must not dispatch") end)

      {:ok, router} = alias_router(leaf)
      {:ok, config} = agent_router_config(router, nil, "char-invalid-alias")

      assert {:error,
              %{
                kind: :workflow_failed,
                reason: :prelude_contract_error,
                details: %{message: message}
              }} =
               Kernel.run(
                 ~S|(return (agent.core/run-outcome "Bad alias" {"model" 1 "max_turns" 1}))|,
                 config
               )

      assert message =~ "agent.core/run-outcome"
      assert message =~ "cfg.model"
      assert message =~ "expected string, got int"
      refute_receive {:agent_request, _request}
    end

    test "run-outcome returns model_alias_required as a provider-failure" do
      {:ok, leaf} =
        LLMCapability.new(requester: fn _ -> flunk("required alias must not dispatch") end)

      {:ok, router} =
        LLMRouter.new([
          replay_alias_route("one", false, leaf),
          replay_alias_route("two", false, leaf)
        ])

      {outcome, fail_fast, records, _events, _usage} =
        routed_pair(
          router,
          nil,
          :alias_required,
          ~S|(return (agent.core/run-outcome "Pick one" {"max_turns" 1}))|,
          ~S|(return (agent.core/run-value "Pick one" {"max_turns" 1}))|
        )

      error = %{
        "status" => "error",
        "kind" => "protocol_error",
        "reason" => "model_alias_required",
        "details" =>
          "2 model aliases selected (one, two) and no default declared; this call must name one",
        "retryable?" => false
      }

      assert {:ok, %{value: %{"status" => "provider-failure", "error" => ^error} = value}} =
               outcome

      refute Map.has_key?(value, "model")
      assert llm_request_output(records) == nil
      assert fail_fast_unauthenticated?(fail_fast)
    end

    test "run-outcome returns whole-call llm_request_timeout as a provider-failure" do
      {:ok, hung} =
        LLMCapability.new(
          requester: fn _request, _context ->
            receive do
              :never -> {:ok, %{content: "late", tokens: %{}}}
            end
          end
        )

      {:ok, router} =
        LLMRouter.new([
          %{
            alias: "chosen",
            source: "llm",
            installation_revision: "chosen-v1",
            default?: true,
            capability: hung,
            max_calls: nil,
            request_timeout_ms: 100
          }
        ])

      {outcome, fail_fast, records, events, usage} =
        routed_pair(router, nil, :llm_timeout)

      error = %{
        "status" => "error",
        "kind" => "timeout",
        "reason" => "llm_request_timeout",
        "retryable?" => true,
        "model" => "chosen"
      }

      assert_provider_failure_outcome(outcome, "chosen", error)
      assert_llm_request_inspection(records, Map.delete(error, "model"))
      assert_authenticated_fail_fast(fail_fast, :timeout, true)
      assert usage.capability_calls.workflow["llm-request"] == 1

      assert Enum.any?(
               events,
               &(&1.type == "capability-stopped" and &1.data[:name] == "llm-request")
             )
    end

    test "kebab provider reasons stay recoverable without rewriting the envelope" do
      for reason <- @kebab_provider_reasons do
        error = classified_error("provider-error", reason)
        assert_lisp_provider_failure(error)
      end
    end

    test "kebab protocol reasons stay recoverable without rewriting the envelope" do
      for reason <- @kebab_protocol_reasons do
        error = classified_error("protocol-error", reason)
        assert_lisp_provider_failure(error)
      end
    end

    test "underscore protocol reasons stay recoverable without rewriting the envelope" do
      for reason <- @underscore_protocol_reasons do
        error = classified_error("protocol_error", reason)
        assert_lisp_provider_failure(error)
      end
    end

    test "kebab whole-request timeout reasons stay recoverable without rewriting the envelope" do
      for reason <- @kebab_timeout_reasons do
        error = classified_error("timeout", reason)
        assert_lisp_provider_failure(error)
      end
    end

    test "underscore whole-request timeout reasons stay recoverable without rewriting the envelope" do
      for reason <- @underscore_timeout_reasons do
        error = classified_error("timeout", reason)
        assert_lisp_provider_failure(error)
      end
    end
  end

  describe "correction then phase transition" do
    test "retained definitions, transcript correlation, budgets, and closing? survive together" do
      parent = self()

      define = %{
        content: "Define the helper before handing off.",
        tool_calls: [
          %{
            id: "define-helper",
            name: "run_ptc_lisp",
            args: %{"program" => "(defn helper [] 41)"}
          }
        ]
      }

      protocol = %{content: "I still need one more observation.", tool_calls: []}

      finish = %{
        content: "Use the retained helper.",
        tool_calls: [
          %{
            id: "use-helper",
            name: "run_ptc_lisp",
            args: %{"program" => "(return (helper))"}
          }
        ]
      }

      {:ok, commit} =
        Capability.new(
          name: "commit",
          effect: :write,
          input_schema: %{"type" => "object"},
          callback: fn _ ->
            send(parent, :commit_called)
            {:ok, 42}
          end
        )

      {:ok, mission} = MissionEnvironment.new(capabilities: [commit])

      {:ok, config} =
        agent_config([define, protocol, finish], missions: %{"default" => mission})

      source = ~S"""
      (agent.core/run-phased-result-value
        "Diagnose the incident."
        {"phases"
         [{"mission" "default" "max_turns" 2}
          {"mission" "default"
           "max_turns" 1
           "instruction" "synthesize from retained evidence."}]})
      """

      assert {:ok, %{value: 41, usage: usage}} = Kernel.run(source, config)
      assert usage.capability_calls.workflow["llm-request"] == 3
      assert usage.subordinate_evaluations == 2
      refute_receive :commit_called

      assert_receive {:agent_request, first}
      assert_receive {:agent_request, second}
      assert_receive {:agent_request, third}
      refute_receive {:agent_request, _fourth}

      assert first["system"] =~ "Available API"
      assert second["system"] == first["system"]

      assert Enum.any?(second["messages"], fn message ->
               message["role"] == "assistant" and
                 message["content"] == "Define the helper before handing off." and
                 get_in(message, ["tool_calls", Access.at(0), "id"]) == "define-helper"
             end)

      assert Enum.any?(second["messages"], fn message ->
               message["role"] == "tool" and message["tool_call_id"] == "define-helper"
             end)

      assert List.last(second["messages"])["content"] =~ "PHASE BUDGET: 1 turn remains"
      refute List.last(second["messages"])["content"] =~ "cannot be retried"

      assert Enum.any?(third["messages"], fn message ->
               message["role"] == "assistant" and
                 message["content"] == "I still need one more observation."
             end)

      assert List.last(third["messages"])["content"] =~ "PHASE TRANSITION"
      assert List.last(third["messages"])["content"] =~ "synthesize from retained evidence"
      # The final phase uses the turn-budget template, not PHASE BUDGET.
      assert List.last(third["messages"])["content"] =~ "TURN BUDGET: 1 turn remains"

      assert agent_actions(config) == [
               action(0, "tool-call", 0, 0, "default"),
               action(1, "protocol-error", 0, 1, "default"),
               action(2, "tool-call", 1, 0, "default")
             ]
    end
  end

  defp assert_kernel_provider_reason(kind) do
    details = "#{kind}-detail"
    error = ProviderError.new(kind, details, retryable?: true)
    {:ok, failing} = LLMCapability.new(requester: fn _ -> {:error, error} end)
    {:ok, unused} = LLMCapability.new(requester: fn _ -> flunk("wrong model alias invoked") end)
    {:ok, router} = replay_alias_router(failing, unused)

    {outcome, fail_fast, records, events, usage} = routed_pair(router, "chosen", kind)

    expected = %{
      "status" => "error",
      "kind" => "provider_error",
      "reason" => Atom.to_string(kind),
      "details" => details,
      "retryable?" => true,
      "model" => "chosen"
    }

    assert_provider_failure_outcome(outcome, "chosen", expected)
    assert_llm_request_inspection(records, Map.delete(expected, "model"))
    assert_authenticated_fail_fast(fail_fast, kind, true)
    assert usage.capability_calls.workflow["llm-request"] == 1

    assert Enum.any?(events, fn event ->
             event.type == "workflow-annotation" and
               event.data.data == %{"turn" => 0, "kind" => "provider-error"}
           end)
  end

  defp assert_provider_failure_outcome(outcome, model, error) do
    assert {:ok, %{value: value}} = outcome

    assert value == %{
             "status" => "provider-failure",
             "model" => model,
             "error" => error
           }
  end

  defp assert_llm_request_inspection({:ok, records}, error) do
    assert llm_request_output(records) == error
  end

  defp assert_llm_request_inspection(other, _error),
    do: flunk("inspection failed: #{inspect(other)}")

  defp llm_request_output({:ok, records}), do: llm_request_output(records)

  defp llm_request_output(records) when is_list(records) do
    output =
      Enum.find(records, fn record ->
        record["record_type"] == "capability-output" and
          record["payload"]["name"] == "llm-request"
      end)

    if output, do: output["payload"]["result"]
  end

  defp assert_authenticated_fail_fast(result, failure, retryable?) do
    assert {:error,
            %{
              kind: :workflow_failed,
              reason: :llm_provider_failed,
              details: details
            }} = result

    assert details.failure_kind == "llm-provider-error"
    assert details.llm_provider_failure == failure
    assert details.llm_provider_retryable? == retryable?

    assert Map.keys(details) -- [:failure_kind, :llm_provider_failure, :llm_provider_retryable?] ==
             []
  end

  defp fail_fast_unauthenticated?(result) do
    match?(
      {:error,
       %{
         kind: :workflow_failed,
         reason: :explicit_failure,
         details: %{failure_kind: "protocol-error"}
       }},
      result
    )
  end

  defp assert_lisp_provider_failure(error) do
    parent = self()
    {:ok, bundle} = compile_agent()

    tools =
      Map.merge(required_agent_tools(), %{
        "llm-request" => %TrustedTool{
          function: fn arguments ->
            send(parent, {:llm_request, arguments})
            error
          end
        },
        "workflow-annotate" => %TrustedTool{
          function: fn _ -> %{status: :ok, value: nil} end
        },
        "kernel-mission-model-context" => %TrustedTool{
          function: fn _ ->
            %{
              status: :ok,
              value:
                Jason.encode!(%{
                  "schema_version" => 2,
                  "namespaces" => [],
                  "entries" => []
                })
            }
          end
        },
        "kernel-llm-provider-failure" => %TrustedTool{
          function: fn arguments ->
            send(parent, {:llm_provider_failure, arguments})
            %{status: :error, kind: :protocol_error, reason: :invalid_llm_provider_failure}
          end
        }
      })

    assert {:ok, step} =
             Lisp.run_native(
               ~S|(return (agent.core/run-outcome "Classify" {"max_turns" 1}))|,
               prelude: bundle.prelude,
               tools: tools,
               filter_context: false,
               caller: :kernel
             )

    assert_receive {:llm_request, _request}
    refute_receive {:llm_provider_failure, _arguments}

    outcome = stringify_keys(unwrap_lisp_return(step.return))
    assert outcome["status"] == "provider-failure"
    assert stringify_keys(outcome["error"]) == stringify_keys(error)
  end

  defp classified_error(kind, reason) do
    %{
      status: :error,
      kind: String.to_atom(kind),
      reason: String.to_atom(reason),
      retryable?: true
    }
  end

  defp unwrap_lisp_return({:__ptc_return__, value}), do: value
  defp unwrap_lisp_return(value), do: value

  defp stringify_keys(%PtcRunner.Lisp.Keyword{name: name}), do: name

  defp stringify_keys(value) when is_map(value) and not is_struct(value) do
    Map.new(value, fn {key, item} -> {stringify_key(key), stringify_keys(item)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)

  defp stringify_keys(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp stringify_keys(value), do: value

  defp stringify_key(%PtcRunner.Lisp.Keyword{name: name}), do: name
  defp stringify_key(key) when is_atom(key), do: Atom.to_string(key)
  defp stringify_key(key) when is_binary(key), do: key
  defp stringify_key(key), do: to_string(key)

  defp routed_pair(router, model, label) do
    outcome_source =
      if is_binary(model) do
        ~s|(return (agent.core/run-outcome "Retry later" {"model" "#{model}" "max_turns" 1}))|
      else
        ~S|(return (agent.core/run-outcome "Retry later" {"max_turns" 1}))|
      end

    fail_source = String.replace(outcome_source, "run-outcome", "run-value")
    routed_pair(router, model, label, outcome_source, fail_source)
  end

  defp routed_pair(router, _model, label, outcome_source, fail_source) do
    {:ok, inspection_sink} =
      StreamingInspection.start(run_id: "char-#{label}", trace_id: "char-#{label}")

    {:ok, outcome_config} = agent_router_config(router, inspection_sink, "char-#{label}-outcome")
    outcome = Kernel.run(outcome_source, outcome_config)
    records = StreamingInspection.records(inspection_sink)
    events = EventSink.events(outcome_config.event_sink)
    usage = outcome_usage(outcome)

    {:ok, fail_config} = agent_router_config(router, nil, "char-#{label}-fail")
    fail_fast = Kernel.run(fail_source, fail_config)

    {outcome, fail_fast, records, events, usage}
  end

  defp outcome_usage({:ok, %{usage: usage}}), do: usage
  defp outcome_usage({:error, %{usage: usage}}), do: usage
  defp outcome_usage(_other), do: %{capability_calls: %{workflow: %{}}}

  defp agent_actions(config) do
    config.event_sink
    |> EventSink.events()
    |> Enum.filter(&(&1.type == "workflow-annotation"))
    |> Enum.map(& &1.data.data)
  end

  defp phased_source do
    ~S"""
    (agent.core/run-phased-result-value
      "Diagnose the incident."
      {"phases"
       [{"mission" "explore" "max_turns" 1}
        {"mission" "synthesize"
         "max_turns" 1
         "instruction" "synthesize from retained evidence."}]})
    """
  end

  defp action(turn, kind, phase, phase_turn, mission) do
    %{
      "turn" => turn,
      "kind" => kind,
      "phase" => phase,
      "phase_turn" => phase_turn,
      "mission" => mission
    }
  end

  defp tool_call(id, program) do
    %{
      content: nil,
      tool_calls: [%{id: id, name: "run_ptc_lisp", args: %{"program" => program}}]
    }
  end

  defp alias_router(capability) do
    LLMRouter.new([replay_alias_route("chosen", true, capability)])
  end

  defp agent_config(responses, opts \\ []) do
    parent = self()
    {:ok, queue} = Agent.start_link(fn -> responses end)

    requester = fn request ->
      send(parent, {:agent_request, request})

      Agent.get_and_update(queue, fn
        [{:error, _} = error | rest] -> {error, rest}
        [response | rest] -> {{:ok, response}, rest}
        [] -> {{:error, :script_exhausted}, []}
      end)
    end

    {:ok, llm} = LLMCapability.new(requester: requester)
    {:ok, bundle} = compile_agent()
    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle, capabilities: [llm])
    {:ok, default_mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(evaluation_timeout_ms: 5_000)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "agent-core-characterization")

    RunConfig.new(
      workflow_environment: workflow,
      missions: Keyword.get(opts, :missions, %{"default" => default_mission}),
      input: %{},
      limits: limits,
      event_sink: sink,
      inspection_sink: Keyword.get(opts, :inspection_sink)
    )
  end

  defp agent_router_config(router, inspection_sink, run_id) do
    {:ok, bundle} = compile_agent()
    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle, capabilities: [router])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(evaluation_timeout_ms: 5_000)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: run_id)

    RunConfig.new(
      workflow_environment: workflow,
      missions: %{"default" => mission},
      input: %{},
      limits: limits,
      event_sink: sink,
      inspection_sink: inspection_sink
    )
  end

  defp compile_agent do
    {:ok, components} =
      Library.components(
        ~w(agent.core agent.failure agent.feedback agent.native agent.prompt agent.retry kernel llm result workflow.event)
      )

    Kernel.compile_bundle(components)
  end

  defp required_agent_tools do
    Map.new(
      ~w(kernel-check-source kernel-eval kernel-agent-config-failure kernel-agent-protocol-error kernel-llm-provider-failure kernel-mission-inventory kernel-mission-model-context kernel-result-contract kernel-result-contract-failure kernel-runtime-limit-failure
         llm-request workflow-annotate),
      &{&1, %TrustedTool{function: fn _arguments -> %{status: :error} end}}
    )
  end
end
