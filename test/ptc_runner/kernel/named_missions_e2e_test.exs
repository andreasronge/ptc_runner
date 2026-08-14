defmodule PtcRunner.Kernel.NamedMissionsE2ETest do
  @moduledoc """
  e2e: two agents, two named missions, one live model.

  This is the question the spike exists to answer — whether a real model driven
  against a named space sees only that space's API and commits only into that
  space's continuation.
  """
  use ExUnit.Case, async: false

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
                    {"max_turns" 4 "mission" "review"})
          leaked (kernel/eval-source "review" "(return (res/record))")]
      (return
        {"fact" fact
         "verdict" verdict
         "cross-space-call" (get leaked :outcome)
         "research-api" (kernel/mission-model-context "research")
         "review-api" (kernel/mission-model-context "review")})))
  """

  setup context do
    if context[:e2e] do
      :ok = LLMSupport.load_dotenv()
      :ok = LLMSupport.admit_provider_application!()

      if System.get_env("OPENROUTER_API_KEY") do
        :ok
      else
        {:skip, "OPENROUTER_API_KEY is not configured"}
      end
    else
      :ok
    end
  end

  test "the shipped named-mission workflow bundle compiles without live credentials" do
    assert {:ok, _bundle} = shipped_loop_bundle()
  end

  @tag :e2e
  test "the shipped agent.core loop drives two isolated spaces via its cfg" do
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

    {:ok, bundle} = shipped_loop_bundle()

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

    # Each mission rendered its own API into its own agent's prompt.
    assert value["research-api"] =~ "res/record"
    refute value["research-api"] =~ "rev/numeric?"
    assert value["review-api"] =~ "rev/numeric?"
    refute value["review-api"] =~ "res/record"

    # The review space cannot call the research space's component at all.
    refute value["cross-space-call"] == :returned

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

  @tag :e2e
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

    mission_frequencies =
      events
      |> Enum.filter(&(&1.type == "evaluation-started" and &1.data.environment == :mission))
      |> Enum.map(& &1.data[:mission_name])
      |> Enum.frequencies()

    assert mission_frequencies |> Map.keys() |> Enum.sort() == ["research", "review"]

    # Each of the two agents per mission may complete on its first program or
    # use its second permitted turn to correct or finish the result.
    assert mission_frequencies["research"] in 2..4
    assert mission_frequencies["review"] in 2..4

    assert Enum.count(
             events,
             &(&1.type == "evaluation-started" and &1.data.environment == :workflow)
           ) == 1
  end

  defp mission_bundle(id, source) do
    {:ok, component} = Component.new(id: id, source: source)
    {:ok, bundle} = Kernel.compile_bundle([component])
    bundle
  end

  defp shipped_loop_bundle do
    with {:ok, shipped} <-
           Component.new(
             id: "spike.shipped",
             source: @shipped_loop_source,
             dependencies: ["agent.core", "kernel"]
           ),
         {:ok, components} <-
           Library.resolve_components([shipped, {:library, "agent.core"}]) do
      Kernel.compile_bundle(components)
    end
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
