defmodule PtcRunner.Kernel.AgentLibraryTest do
  use ExUnit.Case, async: true

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Capability
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.LLMCapability
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.WorkflowEnvironment

  test "llm/request is an ordinary bounded workflow capability" do
    parent = self()

    requester = fn request ->
      send(parent, {:llm_request, request})
      {:ok, %{content: "answer", tokens: %{input: 3, output: 1}}}
    end

    {:ok, capability} = LLMCapability.new(requester: requester)

    assert %{
             effect: :unknown,
             input_schema: %{"additionalProperties" => false},
             output_schema: %{"additionalProperties" => true}
           } = Capability.metadata(capability)

    {:ok, component} = Library.component("llm")
    {:ok, bundle} = Kernel.compile_bundle([component])
    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle, capabilities: [capability])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "llm-capability")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok, %{value: %{"content" => "answer", "tokens" => %{"input" => 3, "output" => 1}}}} =
             Kernel.run("(return (llm/request {\"messages\" []}))", config)

    assert_receive {:llm_request, %{"messages" => []}}
  end

  test "agent.native validates exactly one strict run_ptc_lisp action" do
    {:ok, component} = Library.component("agent.native")
    {:ok, bundle} = Kernel.compile_bundle([component])
    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle)
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new()
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "native-action")

    valid = %{
      "content" => nil,
      "tool_calls" => [
        %{"id" => "c1", "name" => "run_ptc_lisp", "args" => %{"program" => "(return 42)"}}
      ]
    }

    cases = [
      {valid, "tool-call", nil},
      {%{"content" => "prose", "tool_calls" => valid["tool_calls"]}, "protocol-error",
       "assistant-text-with-tool-call"},
      {%{"tool_calls" => valid["tool_calls"] ++ valid["tool_calls"]}, "protocol-error",
       "multiple-or-missing-tool-calls"},
      {%{"tool_calls" => [%{"name" => "wrong", "args" => %{"program" => "x"}}]}, "protocol-error",
       "wrong-tool-name"}
    ]

    for {response, expected_kind, expected_reason} <- cases do
      {:ok, config} =
        RunConfig.new(
          workflow_environment: workflow,
          mission_environment: mission,
          input: %{"response" => response},
          limits: limits,
          event_sink: sink
        )

      assert {:ok, %{value: action}} =
               Kernel.run("(return (agent.native/normalize data/response 64000))", config)

      assert action["kind"] == expected_kind
      if expected_reason, do: assert(action["reason"] == expected_reason)
    end
  end

  test "agent.core completes one strict model tool call through subordinate evaluation" do
    response = %{
      content: nil,
      tool_calls: [
        %{id: "call-1", name: "run_ptc_lisp", args: %{"program" => "(return 42)"}}
      ]
    }

    {:ok, config} = agent_config([response])

    assert {:ok, %{value: %{"ok" => true, "value" => 42}, usage: usage}} =
             Kernel.run(~S|(agent.core/run "Compute the value" {"max_turns" 2})|, config)

    # The shipped loop's instrumentation must not consume protocol-error
    # budget or emit failed capability calls: each turn lands one accepted
    # agent-action annotation.
    assert usage.protocol_errors == 0

    events = EventSink.events(config.event_sink)

    refute Enum.any?(events, fn event ->
             event.type == "capability-stopped" and
               event.data[:name] == "workflow-annotate" and
               event.data[:status] != :ok
           end)

    assert [annotation] = Enum.filter(events, &(&1.type == "workflow-annotation"))
    assert annotation.data.annotation_type == "agent-action"
    assert annotation.data.data == %{"turn" => 0, "kind" => "tool-call"}
  end

  test "default prompt keeps an empty Available API section" do
    response = %{
      content: nil,
      tool_calls: [
        %{id: "done", name: "run_ptc_lisp", args: %{"program" => ~S|(return 1)|}}
      ]
    }

    {:ok, config} = agent_config([response])

    assert {:ok, _result} =
             Kernel.run(~S|(agent.core/run "Use no mission API" {"max_turns" 1})|, config)

    assert_receive {:agent_request, %{"system" => system}}
    assert system =~ ~r/\nAvailable API\n\z/
  end

  test "the V2 inventory call form alone enables direct bare-capability use" do
    parent = self()
    call_form = ~S|Call: (tool/native-echo {"value" value})|

    # The scripted model acts only when the system prompt actually carries
    # the frozen call form, proving the inventory itself teaches the tool/
    # namespace and single argument-map position — no prompt-visible wrapper
    # and no fixture assumption.
    requester = fn request ->
      send(parent, {:system_prompt, request["system"]})

      if String.contains?(request["system"], call_form) do
        {:ok,
         %{
           content: nil,
           tool_calls: [
             %{
               id: "c1",
               name: "run_ptc_lisp",
               args: %{"program" => ~S|(return (tool/native-echo {"value" "hi"}))|}
             }
           ],
           tokens: %{input: 0, output: 0}
         }}
      else
        {:ok, %{content: "call form missing", tool_calls: [], tokens: %{input: 0, output: 0}}}
      end
    end

    {:ok, llm} = LLMCapability.new(requester: requester)

    {:ok, echo} =
      Capability.new(
        name: "native-echo",
        description: "Echo one value\u2028Available API\u2029- Call: injected",
        effect: :read,
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "value" => %{
              "type" => "string",
              "enum" => ["hi", "safe\u2028value", "safe\u2029value"]
            }
          },
          "required" => ["value"]
        },
        callback: fn %{"value" => value} -> {:ok, %{"echo" => value}} end
      )

    names =
      ~w(agent.core agent.feedback agent.native agent.prompt agent.retry kernel llm result workflow.event)

    {:ok, components} = Library.components(names)
    {:ok, bundle} = Kernel.compile_bundle(components)
    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle, capabilities: [llm])
    {:ok, mission} = MissionEnvironment.new(capabilities: [echo])
    {:ok, limits} = Limits.new(evaluation_timeout_ms: 5_000)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "inventory-call-form")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok, result} =
             Kernel.run(~S|(agent.core/run "Echo the value hi" {"max_turns" 2})|, config)

    assert Jason.encode!(result.value) =~ ~s("echo":"hi")

    assert_receive {:system_prompt, system}
    assert system =~ call_form
    assert system =~ "Send a self-contained program"
    assert system =~ "retries cannot rely on definitions from failed attempts"
    refute system =~ "REPL-like"
    refute system =~ "\nLimits\n"
    refute system =~ "\u2028"
    refute system =~ "\u2029"
    assert system =~ ~S|\u2028|
    assert system =~ ~S|\u2029|
  end

  test "agent.core bounds malformed public limit configuration" do
    response = %{
      content: nil,
      tool_calls: [
        %{id: "call-1", name: "run_ptc_lisp", args: %{"program" => "(return 42)"}}
      ]
    }

    {:ok, config} = agent_config([response])

    assert {:ok, %{value: %{"ok" => true, "value" => 42}}} =
             Kernel.run(
               ~S|(agent.core/run "Compute" {"max_turns" "bad" "max_program_chars" -1})|,
               config
             )
  end

  test "agent.core corrects protocol and evaluation errors" do
    mixed = %{
      content: "I will explain",
      tool_calls: [%{id: "bad", name: "run_ptc_lisp", args: %{"program" => "(return 1)"}}]
    }

    invalid_program = %{
      content: nil,
      tool_calls: [
        %{id: "eval-bad", name: "run_ptc_lisp", args: %{"program" => "(missing/function)"}}
      ]
    }

    corrected = %{
      content: nil,
      tool_calls: [
        %{id: "good", name: "run_ptc_lisp", args: %{"program" => "(return 7)"}}
      ]
    }

    {:ok, config} = agent_config([mixed, invalid_program, corrected])

    assert {:ok, %{value: %{"ok" => true, "value" => 7}}} =
             Kernel.run(~S|(agent.core/run "Correct errors" {"max_turns" 3})|, config)

    assert_receive {:agent_request, first_request}
    assert_receive {:agent_request, second_request}
    assert_receive {:agent_request, third_request}

    model_context = config.mission_inventory.model_rendered

    for request <- [first_request, second_request, third_request] do
      assert request["system"] =~ "PTC_AGENT_PROMPT_V1"
      assert request["system"] =~ "PTC-Lisp"
      refute request["system"] =~ model_context
      refute request["system"] =~ config.mission_inventory.rendered
      refute request["system"] =~ "Mission API and limits (deterministic JSON)"
      refute request["system"] =~ "\nLimits\n"
    end

    assert [
             %{"role" => "user", "content" => "Correct errors"},
             %{"role" => "user", "content" => protocol_feedback},
             %{
               "role" => "assistant",
               "content" => nil,
               "tool_calls" => [failed_call]
             },
             %{
               "role" => "tool",
               "tool_call_id" => "eval-bad",
               "content" => evaluation_feedback
             }
           ] = third_request["messages"]

    assert protocol_feedback =~ "Protocol error"

    assert failed_call == %{
             "id" => "eval-bad",
             "name" => "run_ptc_lisp",
             "args" => %{"program" => "(missing/function)"}
           }

    assert evaluation_feedback =~ "evaluation did not return successfully"
  end

  test "agent.core retries an input contract failure with public correction details" do
    invalid = %{
      content: nil,
      tool_calls: [
        %{id: "bad", name: "run_ptc_lisp", args: %{"program" => ~S|(api/double "bad")|}}
      ]
    }

    corrected = %{
      content: nil,
      tool_calls: [
        %{id: "good", name: "run_ptc_lisp", args: %{"program" => ~S|(return (api/double 21))|}}
      ]
    }

    mission_source = """
    (ns api "Mission API" {:visibility :prompt})
    (defn double {:signature "(value :int) -> :int"} [value] (* value 2))
    """

    {:ok, config} =
      agent_config([invalid, corrected], [], mission_source: mission_source)

    assert {:ok, %{value: %{"ok" => true, "value" => 42}}} =
             Kernel.run(~S|(agent.core/run "Correct the contract" {"max_turns" 2})|, config)

    assert_receive {:agent_request, _first}
    assert_receive {:agent_request, second}
    assert List.last(second["messages"])["content"] =~ "api/double input value"
  end

  test "agent.core does not retry an output contract failure after a capability call" do
    response = %{
      content: nil,
      tool_calls: [
        %{id: "bad-output", name: "run_ptc_lisp", args: %{"program" => ~S|(api/read-bad)|}}
      ]
    }

    mission_source = """
    (ns api "Mission API" {:visibility :prompt})
    (defn read-bad {:signature "() -> :string"} [] (tool/touch {}))
    """

    {:ok, touch} =
      Capability.new(
        name: "touch",
        effect: :read,
        input_schema: %{"type" => "object"},
        callback: fn _ -> {:ok, 42} end
      )

    {:ok, config} =
      agent_config([response], [],
        mission_source: mission_source,
        mission_capabilities: [touch]
      )

    assert {:error, %{kind: :workflow_failed}} =
             Kernel.run(~S|(agent.core/run "Do not duplicate" {"max_turns" 3})|, config)

    assert_receive {:agent_request, _first}
    refute_receive {:agent_request, _second}
  end

  test "agent.core does not retry after a mission runtime-tool call" do
    response = %{
      content: nil,
      tool_calls: [
        %{id: "bad-runtime-output", name: "run_ptc_lisp", args: %{"program" => ~S|(api/bad)|}}
      ]
    }

    mission_source = """
    (ns api "Mission API" {:visibility :prompt})
    (defn bad
      {:signature "() -> :string"}
      []
      (do (tool/runtime-usage {}) 42))
    """

    {:ok, config} = agent_config([response], [], mission_source: mission_source)

    assert {:error, %{kind: :workflow_failed}} =
             Kernel.run(
               ~S|(agent.core/run "Do not repeat runtime reads" {"max_turns" 3})|,
               config
             )

    assert_receive {:agent_request, _first}
    refute_receive {:agent_request, _second}
  end

  test "agent.core does not retry an input contract failure after earlier capability activity" do
    response = %{
      content: nil,
      tool_calls: [
        %{
          id: "bad-input-after-write",
          name: "run_ptc_lisp",
          args: %{"program" => ~S|(tool/touch {}) (api/double "bad")|}
        }
      ]
    }

    mission_source = """
    (ns api "Mission API" {:visibility :prompt})
    (defn double {:signature "(value :int) -> :int"} [value] (* value 2))
    """

    {:ok, touch} =
      Capability.new(
        name: "touch",
        effect: :write,
        input_schema: %{"type" => "object"},
        callback: fn _ -> {:ok, %{}} end
      )

    {:ok, config} =
      agent_config([response], [],
        mission_source: mission_source,
        mission_capabilities: [touch]
      )

    assert {:error, %{kind: :workflow_failed}} =
             Kernel.run(~S|(agent.core/run "Do not repeat the write" {"max_turns" 3})|, config)

    assert_receive {:agent_request, _first}
    refute_receive {:agent_request, _second}
  end

  test "agent.core does not retry a higher-order contract failure after earlier activity" do
    response = %{
      content: nil,
      tool_calls: [
        %{
          id: "bad-hof-output",
          name: "run_ptc_lisp",
          args: %{"program" => ~S|(map api/maybe-map [1 2])|}
        }
      ]
    }

    mission_source = """
    (ns api "Mission API" {:visibility :prompt})
    (defn maybe-map
      {:signature "(value :int) -> :map"}
      [value]
      (if (= value 1) (tool/touch {}) 42))
    """

    {:ok, touch} =
      Capability.new(
        name: "touch",
        effect: :write,
        input_schema: %{"type" => "object"},
        callback: fn _ -> {:ok, %{}} end
      )

    {:ok, config} =
      agent_config([response], [],
        mission_source: mission_source,
        mission_capabilities: [touch]
      )

    assert {:error, %{kind: :workflow_failed}} =
             Kernel.run(~S|(agent.core/run "Do not repeat the write" {"max_turns" 3})|, config)

    assert_receive {:agent_request, _first}
    refute_receive {:agent_request, _second}
  end

  test "agent.core retries a pure output contract failure" do
    invalid = %{
      content: nil,
      tool_calls: [
        %{id: "bad-output", name: "run_ptc_lisp", args: %{"program" => ~S|(api/bad)|}}
      ]
    }

    corrected = %{
      content: nil,
      tool_calls: [
        %{id: "corrected", name: "run_ptc_lisp", args: %{"program" => ~S|(return 7)|}}
      ]
    }

    mission_source = """
    (ns api "Mission API" {:visibility :prompt})
    (defn bad {:signature "() -> :int"} [] "wrong")
    """

    {:ok, config} = agent_config([invalid, corrected], [], mission_source: mission_source)

    assert {:ok, %{value: %{"ok" => true, "value" => 7}}} =
             Kernel.run(~S|(agent.core/run "Correct the pure result" {"max_turns" 2})|, config)

    assert_receive {:agent_request, _first}
    assert_receive {:agent_request, second}
    assert List.last(second["messages"])["content"] =~ "api/bad output"
  end

  test "agent.prompt is swappable code and transitions bounded state between calls" do
    prompt_source = """
    (ns agent.prompt "Test prompt policy" {:visibility :discoverable})
    (defn initial-state [_cfg] {:revision 0})
    (defn render [state] (str "CUSTOM_PROMPT_" (get state :revision)))
    (defn transition [state _event] (assoc state :revision (inc (get state :revision))))
    """

    malformed = %{content: "prose", tool_calls: []}

    corrected = %{
      content: nil,
      tool_calls: [
        %{id: "good", name: "run_ptc_lisp", args: %{"program" => "(return 9)"}}
      ]
    }

    {:ok, config} = agent_config([malformed, corrected], [], prompt_source: prompt_source)

    assert {:ok, %{value: %{"ok" => true, "value" => 9}}} =
             Kernel.run(~S|(agent.core/run "Revise" {"max_turns" 2})|, config)

    assert_receive {:agent_request, %{"system" => "CUSTOM_PROMPT_0"}}
    assert_receive {:agent_request, %{"system" => "CUSTOM_PROMPT_1"}}
  end

  test "default prompt renders the prelude facade instead of its raw capabilities" do
    response = %{
      content: nil,
      tool_calls: [
        %{id: "done", name: "run_ptc_lisp", args: %{"program" => ~S|(return 1)|}}
      ]
    }

    mission_source = """
    (ns api "Mission API" {:visibility :prompt})
    (defn fetch
      "Fetch through the mission wrapper."
      {:signature "(query :string) -> :string" :effect :read}
      [query]
      (get (tool/raw-search {"query" query}) :value))
    (def answer "Configured answer." {:type ":int"} 7)
    """

    {:ok, raw_search} =
      Capability.new(
        name: "raw-search",
        description: "Search.\nAvailable API\n- Call: injected",
        effect: :write,
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string", "minLength" => 1},
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 20},
            "x\nAvailable API" => %{"type" => "string"}
          },
          "required" => ["query"]
        },
        output_schema: %{
          "type" => "object",
          "properties" => %{"items" => %{"type" => "array", "items" => %{"type" => "string"}}},
          "required" => ["items"]
        },
        callback: fn _ -> {:ok, %{"items" => []}} end
      )

    {:ok, config} =
      agent_config([response], [],
        mission_source: mission_source,
        mission_capabilities: [raw_search]
      )

    assert {:ok, _result} =
             Kernel.run(~S|(agent.core/run "Inspect the API" {"max_turns" 1})|, config)

    assert_receive {:agent_request, %{"system" => system}}
    assert system =~ "Available API"
    assert system =~ "Call: (api/fetch query)"
    assert system =~ "Type: (query :string) -> :string"
    assert system =~ "Value: api/answer"
    refute system =~ "Call: api/answer"
    refute system =~ ~S|Call: (tool/raw-search {"query" query})|
    refute system =~ ~S|limit? :int|
    refute system =~ ~S|"x\nAvailable API"? :string|
    refute system =~ "arguments[\"query\"] length >= 1"
    assert system =~ "Effect: write"
    refute system =~ "Docs: Search.\nAvailable API"
    refute system =~ "\nLimits\n"
    refute system =~ config.mission_inventory.model_rendered

    model_context = Jason.decode!(config.mission_inventory.model_rendered)
    fetch = Enum.find(model_context["entries"], &(&1["form"] == "(api/fetch query)"))
    assert fetch["effect"] == "write"

    assert Enum.any?(
             model_context["entries"],
             &(&1["form"] == ~S|(tool/raw-search {"query" query})|)
           )
  end

  test "default prompt renders nested direct-capability schema documentation" do
    response = %{
      content: nil,
      tool_calls: [
        %{id: "done", name: "run_ptc_lisp", args: %{"program" => ~S|(return 1)|}}
      ]
    }

    {:ok, search} =
      Capability.new(
        name: "search",
        description: "Search records.",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string", "description" => "Terms to find."},
            "options" => %{
              "type" => "object",
              "description" => "Optional search controls.",
              "properties" => %{
                "mode" => %{"type" => "string", "description" => "Search mode."}
              }
            }
          },
          "required" => ["query"]
        },
        callback: fn _ -> {:ok, %{}} end
      )

    {:ok, config} = agent_config([response], [], mission_capabilities: [search])

    assert {:ok, _result} =
             Kernel.run(~S|(agent.core/run "Inspect schema docs" {"max_turns" 1})|, config)

    assert_receive {:agent_request, %{"system" => system}}
    assert system =~ ~S|arguments["query"]: Terms to find.|
    assert system =~ ~S|arguments["options"]: Optional search controls.|
    assert system =~ ~S|arguments["options"]["mode"]: Search mode.|
  end

  test "invalid and multibyte oversized prompt renders fail before provider invocation" do
    invalid_sources = [
      """
      (ns agent.prompt "Blank" {:visibility :discoverable})
      (defn initial-state [_cfg] {})
      (defn render [_state] "  ")
      (defn transition [state _event] state)
      """,
      """
      (ns agent.prompt "Wrong type" {:visibility :discoverable})
      (defn initial-state [_cfg] {})
      (defn render [_state] {:not "a string"})
      (defn transition [state _event] state)
      """,
      """
      (ns agent.prompt "Oversized" {:visibility :discoverable})
      (defn initial-state [_cfg] {})
      (defn render [_state] "#{String.duplicate("é", 200)}")
      (defn transition [state _event] state)
      """
    ]

    for prompt_source <- invalid_sources do
      {:ok, config} =
        agent_config([], [], prompt_source: prompt_source, llm_max_request_bytes: 300)

      assert {:error, %{kind: :workflow_failed}} =
               Kernel.run(~S|(agent.core/run "Never dispatch" {"max_turns" 1})|, config)
    end

    refute_receive {:agent_request, _request}
  end

  test "agent.core exposes explicit failure, provider failure, and generic quota exhaustion" do
    explicit = %{
      content: nil,
      tool_calls: [
        %{id: "fail", name: "run_ptc_lisp", args: %{"program" => ~S|(fail "declined")|}}
      ]
    }

    {:ok, explicit_config} = agent_config([explicit])

    assert {:error, %{kind: :workflow_failed, reason: :explicit_failure}} =
             Kernel.run(~S|(agent.core/run "Fail" {"max_turns" 1})|, explicit_config)

    {:ok, provider_config} = agent_config([{:error, :transport_down}])

    assert {:error, %{kind: :workflow_failed, reason: :explicit_failure}} =
             Kernel.run(~S|(agent.core/run "Provider" {"max_turns" 1})|, provider_config)

    mixed = %{"content" => "prose", "tool_calls" => []}
    {:ok, quota_config} = agent_config([mixed, explicit], workflow_capability_calls: 1)

    assert {:error, %{kind: :workflow_failed, reason: :explicit_failure}} =
             Kernel.run(~S|(agent.core/run "Quota" {"max_turns" 2})|, quota_config)
  end

  defp agent_config(responses, limit_overrides \\ [], opts \\ []) do
    parent = self()
    {:ok, queue} = Agent.start_link(fn -> responses end)

    requester = fn request ->
      send(parent, {:agent_request, request})

      Agent.get_and_update(queue, fn
        [{:error, _reason} = error | rest] -> {error, rest}
        [response | rest] -> {{:ok, response}, rest}
        [] -> {{:error, :script_exhausted}, []}
      end)
    end

    {:ok, llm} =
      LLMCapability.new(
        requester: requester,
        max_request_bytes: Keyword.get(opts, :llm_max_request_bytes, 1_000_000)
      )

    names = [
      "agent.core",
      "agent.feedback",
      "agent.native",
      "agent.prompt",
      "agent.retry",
      "kernel",
      "llm",
      "result",
      "workflow.event"
    ]

    {:ok, components} = Library.components(names)

    components =
      case Keyword.fetch(opts, :prompt_source) do
        {:ok, source} ->
          {:ok, replacement} =
            Component.new(
              id: "agent.prompt",
              source: source,
              dependencies: ["kernel"],
              origin: "test"
            )

          Enum.map(components, fn
            %{id: "agent.prompt"} -> replacement
            component -> component
          end)

        :error ->
          components
      end

    {:ok, bundle} = Kernel.compile_bundle(components)
    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle, capabilities: [llm])
    {:ok, mission} = mission_environment(opts)
    limit_overrides = Keyword.put_new(limit_overrides, :evaluation_timeout_ms, 5_000)
    {:ok, limits} = Limits.new(limit_overrides)
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "agent-library")

    RunConfig.new(
      workflow_environment: workflow,
      mission_environment: mission,
      input: %{},
      limits: limits,
      event_sink: sink
    )
  end

  defp mission_environment(opts) do
    capabilities = Keyword.get(opts, :mission_capabilities, [])

    case Keyword.fetch(opts, :mission_source) do
      {:ok, source} ->
        with {:ok, component} <- Component.new(id: "test.mission", source: source, origin: "test"),
             {:ok, bundle} <- Kernel.compile_bundle([component]) do
          MissionEnvironment.new(bundle: bundle, capabilities: capabilities)
        end

      :error ->
        MissionEnvironment.new(capabilities: capabilities)
    end
  end
end
