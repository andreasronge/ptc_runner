defmodule PtcRunner.Kernel.NamedMissionsE2ETest do
  @moduledoc """
  e2e: two agents, two named missions, two role prompts, one live model.

  This is the question the spike exists to answer — whether a real model driven
  against a named space sees only that space's API and commits only into that
  space's continuation.
  """
  use ExUnit.Case, async: false

  @moduletag :e2e
  @moduletag timeout: 180_000

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.TestSupport.LLMSupport

  @host Path.expand("../../../examples/kernel-tutorial/ptc-host.json", __DIR__)

  @research_source """
  (ns res "Read the stored research record." {:visibility :prompt})

  (defn record
    "Return the one stored research record."
    {:signature "() -> :string"}
    []
    "shipment 4021 left the depot at 06:15")
  """

  @review_source """
  (ns rev "Check a claim for a numeric identifier." {:visibility :prompt})

  (defn numeric?
    "Return whether the claim contains a digit."
    {:signature "(claim :string) -> :bool"}
    [claim]
    (some? (re-find #"[0-9]" claim)))
  """

  @shipped_loop_source """
  (ns spike.shipped "Two agent.core loops, one per named named mission.")

  (defn run [_input]
    (let [fact (agent.core/run-value
                 "Retrieve the stored record and return it as a string."
                 {"max_turns" 4 "mission" "research"})
          verdict (agent.core/run-value
                    (str "Does this claim contain a numeric identifier? Claim: " fact)
                    {"max_turns" 4 "mission" "review"})]
      (return {"fact" fact "verdict" verdict})))
  """

  @workflow_source """
  (ns spike.team "Two agents driven against two named named missions.")

  (defn- system-text [role space]
    (str role "\\n\\n"
         "You must answer only by calling the run_ptc_lisp tool exactly once per turn "
         "with one PTC-Lisp program string. Never answer in prose.\\n"
         "Call (return value) as soon as you have the answer.\\n"
         "Only the API below exists. Do not invent other functions.\\n"
         "Example turn: (return (some.ns/some-fn))\\n\\n"
         (kernel/mission-model-context space)))

  (defn- correlate [messages action content]
    (conj
      (conj messages {"role" "assistant"
                      "content" (get action :rationale)
                      "tool_calls" [(get action :public-tool-call)]})
      {"role" "tool"
       "tool_call_id" (get action :tool-call-id)
       "content" content}))

  (defn- run-role [space role task max-turns]
    (loop [turn 0
           messages [{"role" "user" "content" task}]]
      (if (>= turn max-turns)
        (fail {:kind :turn-limit})
        (let [response (llm/request {"system" (system-text role space)
                                     "messages" messages
                                     "tools" [(agent.native/tool-schema)]})
              action (agent.native/normalize response 64000)]
          (if (not= :tool-call (get action :kind))
            ;; agent.core corrects a protocol error rather than ending the run;
            ;; a loop that skips this is brittle against ordinary prose replies.
            (if (agent.retry/retry? turn max-turns)
              (recur (inc turn)
                     (conj messages
                           {"role" "user"
                            "content" (agent.feedback/protocol-error action)}))
              (fail {:kind :protocol-error}))
            (let [evaluation (kernel/eval-source space (get action :program))]
              (case (get evaluation :outcome)
                :returned (get evaluation :value)
                :continued (recur (inc turn)
                                  (correlate messages action
                                             (agent.feedback/success evaluation 2048)))
                (if (agent.retry/retry? turn max-turns)
                  (recur (inc turn)
                         (correlate messages action
                                    (agent.feedback/evaluation-error evaluation)))
                  (fail {:kind :agent-failed})))))))))

  (defn run [_input]
    (let [fact (run-role "research"
                         "You retrieve one stored record."
                         "Retrieve the stored record and return it as a string."
                         4)
          verdict (run-role "review"
                            "You verify one claim."
                            (str "Does this claim contain a numeric identifier? Claim: " fact)
                            4)
          leaked (kernel/eval-source "review" "(return (res/record))")]
      (return
        {"fact" fact
         "verdict" verdict
         "cross-space-call" (get leaked :outcome)
         "research-api" (kernel/mission-model-context "research")
         "review-api" (kernel/mission-model-context "review")})))
  """

  setup_all do
    :ok = PtcRunner.Dotenv.load()
    :ok = LLMSupport.admit_provider_application!()

    if System.get_env("OPENROUTER_API_KEY") do
      :ok
    else
      {:skip, "OPENROUTER_API_KEY is not configured"}
    end
  end

  test "two agents run in two named missions with two role prompts" do
    {:ok, limits} =
      Limits.new(
        run_duration_ms: 150_000,
        workflow_timeout_ms: 150_000,
        evaluation_timeout_ms: 10_000,
        subordinate_evaluations: 12,
        workflow_capability_calls: 64
      )

    {:ok, %{capabilities: [llm_capability], close: close}} = build_live_llm(limits)
    if close, do: on_exit(close)

    {:ok, workflow} =
      WorkflowEnvironment.new(
        bundle: workflow_bundle(),
        capabilities: [llm_capability]
      )

    {:ok, default_mission} = MissionEnvironment.new([])
    {:ok, research} = MissionEnvironment.new(bundle: mission_bundle("res", @research_source))
    {:ok, review} = MissionEnvironment.new(bundle: mission_bundle("rev", @review_source))

    {:ok, sink} = EventSink.start(:normal, limits, run_id: "named-missions-e2e")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => default_mission, "research" => research, "review" => review},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok, %{value: value}} = Kernel.run("(spike.team/run data/input)", config)

    # Each mission rendered its own API into its own agent's prompt.
    assert value["research-api"] =~ "res/record"
    refute value["research-api"] =~ "rev/numeric?"
    assert value["review-api"] =~ "rev/numeric?"
    refute value["review-api"] =~ "res/record"

    # The research agent reached its own space's capability.
    assert is_binary(value["fact"])
    assert value["fact"] =~ "4021"

    # The review agent answered from its own, different API.
    refute is_nil(value["verdict"])

    # The review space cannot call the research space's component at all.
    refute value["cross-space-call"] == :returned

    spaces =
      sink
      |> EventSink.events()
      |> Enum.filter(&(&1.type == "evaluation-started"))
      |> Enum.map(fn event -> event.data[:mission_name] end)
      |> Enum.uniq()
      |> Enum.sort()

    assert "research" in spaces
    assert "review" in spaces
  end

  test "the shipped agent.core loop drives two spaces via its cfg" do
    {:ok, limits} =
      Limits.new(
        run_duration_ms: 150_000,
        workflow_timeout_ms: 150_000,
        evaluation_timeout_ms: 10_000,
        subordinate_evaluations: 12,
        workflow_capability_calls: 64
      )

    {:ok, %{capabilities: [llm_capability], close: close}} = build_live_llm(limits)
    if close, do: on_exit(close)

    {:ok, shipped} =
      Component.new(
        id: "spike.shipped",
        source: @shipped_loop_source,
        dependencies: ["agent.core"]
      )

    {:ok, components} = Library.resolve_components([shipped, {:library, "agent.core"}])
    {:ok, bundle} = Kernel.compile_bundle(components)

    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle, capabilities: [llm_capability])
    {:ok, default_mission} = MissionEnvironment.new([])
    {:ok, research} = MissionEnvironment.new(bundle: mission_bundle("res", @research_source))
    {:ok, review} = MissionEnvironment.new(bundle: mission_bundle("rev", @review_source))
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "named-missions-shipped")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => default_mission, "research" => research, "review" => review},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok, %{value: value}} = Kernel.run("(spike.shipped/run data/input)", config)

    assert is_binary(value["fact"])
    assert value["fact"] =~ "4021"
    refute is_nil(value["verdict"])

    spaces =
      sink
      |> EventSink.events()
      |> Enum.filter(&(&1.type == "evaluation-started"))
      |> Enum.map(fn event -> event.data[:mission_name] end)
      |> Enum.uniq()

    assert "research" in spaces
    assert "review" in spaces
    refute "default" in spaces
  end

  test "live agents under pcalls: where the parallel boundary actually is" do
    {:ok, limits} =
      Limits.new(
        run_duration_ms: 150_000,
        workflow_timeout_ms: 150_000,
        evaluation_timeout_ms: 10_000,
        subordinate_evaluations: 12,
        workflow_capability_calls: 64
      )

    {:ok, %{capabilities: [llm_capability], close: close}} = build_live_llm(limits)
    if close, do: on_exit(close)

    source = """
    (ns spike.par "Two live agent.core loops under pcalls.")
    (defn run [_input]
      (return
        (pcalls
          #(agent.core/run-value "Retrieve the stored record." {"max_turns" 2 "mission" "research"})
          #(agent.core/run-value "Is 4021 numeric?" {"max_turns" 2 "mission" "review"})
          #(agent.core/run-value "Retrieve the stored record again." {"max_turns" 2 "mission" "research"})
          #(agent.core/run-value "Is 77 numeric?" {"max_turns" 2 "mission" "review"}))))
    """

    {:ok, par} = Component.new(id: "spike.par", source: source, dependencies: ["agent.core"])
    {:ok, components} = Library.resolve_components([par, {:library, "agent.core"}])
    {:ok, bundle} = Kernel.compile_bundle(components)

    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle, capabilities: [llm_capability])
    {:ok, default_mission} = MissionEnvironment.new([])
    {:ok, research} = MissionEnvironment.new(bundle: mission_bundle("res", @research_source))
    {:ok, review} = MissionEnvironment.new(bundle: mission_bundle("rev", @review_source))
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "named-missions-parallel")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        missions: %{"default" => default_mission, "research" => research, "review" => review},
        input: %{},
        limits: limits,
        event_sink: sink
      )

    assert {:ok, %{value: values}} = Kernel.run("(spike.par/run data/input)", config)
    assert length(values) == 4
    assert Enum.all?(values, &(not is_nil(&1)))

    events = EventSink.events(sink)

    assert events
           |> Enum.filter(&(&1.type == "evaluation-started" and &1.data.environment == :mission))
           |> Enum.map(& &1.data[:mission_name])
           |> Enum.frequencies() == %{"research" => 2, "review" => 2}

    assert Enum.count(
             events,
             &(&1.type == "evaluation-started" and &1.data.environment == :workflow)
           ) == 1
  end

  defp workflow_bundle do
    {:ok, team} =
      Component.new(
        id: "spike.team",
        source: @workflow_source,
        dependencies: ["agent.feedback", "agent.native", "agent.retry", "kernel", "llm"]
      )

    {:ok, components} =
      Library.resolve_components([
        team,
        {:library, "kernel"},
        {:library, "llm"},
        {:library, "agent.native"},
        {:library, "agent.feedback"},
        {:library, "agent.retry"}
      ])

    {:ok, bundle} = Kernel.compile_bundle(components)
    bundle
  end

  defp mission_bundle(id, source) do
    {:ok, component} = Component.new(id: id, source: source)
    {:ok, bundle} = Kernel.compile_bundle([component])
    bundle
  end

  # ex_dna:disable-for-next-line — mirrors the established live DeepSeek provider fixture
  defp build_live_llm(limits) do
    {:ok, host} = HostConfig.load(@host)

    host =
      update_in(host.install["deepseek"], fn installation ->
        %{
          installation
          | model: LLMSupport.model(),
            params: %{temperature: 0.0, seed: 1168, max_tokens: 1_024}
        }
      end)

    {:ok, catalog} = HostInstallation.catalog(host)
    {:ok, registry} = HostInstallation.runtime_registry(host, catalog)

    ProviderRegistry.build(registry, "deepseek", %{}, %{
      application_content_digest: String.duplicate("0", 64),
      destination: :workflow,
      owner: self(),
      limits: limits,
      installed_limits: host.limits
    })
  end
end
