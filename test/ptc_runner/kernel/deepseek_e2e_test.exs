defmodule PtcRunner.Kernel.DeepSeekE2ETest do
  use ExUnit.Case, async: false

  @moduletag :e2e
  @moduletag timeout: 120_000

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.Component
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.InspectionSink
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.TestSupport.LLMSupport

  @host Path.expand("../../../examples/kernel-tutorial/ptc-host.json", __DIR__)

  setup_all do
    :ok = PtcRunner.Dotenv.load()

    # The core application no longer starts :req_llm implicitly; a run admits it
    # through ProviderApplicationGate. This test drives ProviderRegistry.build/4
    # directly, so it admits the provider application itself, disabling the
    # dependency's own dotenv reader exactly as the gate does.
    Application.put_env(:req_llm, :load_dotenv, false, persistent: true)
    {:ok, _started} = Application.ensure_all_started(:req_llm)

    if System.get_env("OPENROUTER_API_KEY") do
      :ok
    else
      {:skip, "OPENROUTER_API_KEY is not configured"}
    end
  end

  test "a live DeepSeek request crosses the bounded Kernel capability boundary" do
    {:ok, limits} = Limits.new(run_duration_ms: 90_000, workflow_timeout_ms: 90_000)

    {:ok, %{capabilities: [capability], close: close}} =
      build_live_llm(limits)

    if close, do: on_exit(close)

    {:ok, component} = Library.component("llm")
    {:ok, bundle} = Kernel.compile_bundle([component])
    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle, capabilities: [capability])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, sink} = EventSink.start(:normal, limits, run_id: "deepseek-e2e")

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{},
        limits: limits,
        event_sink: sink
      )

    source = """
    (return
      (llm/request
        {"system" "Follow the user's output constraint exactly."
         "messages" [{"role" "user"
                      "content" "Reply with exactly KERNEL_OK and nothing else."}]}))
    """

    assert {:ok, %{value: %{"content" => content}}} = Kernel.run(source, config)
    assert String.trim(content) == "KERNEL_OK"
  end

  @tag :tmp_dir
  test "DeepSeek writes parameterized source that is checked before mission execution", %{
    tmp_dir: dir
  } do
    {:ok, limits} =
      Limits.new(
        run_duration_ms: 120_000,
        workflow_timeout_ms: 120_000,
        evaluation_timeout_ms: 10_000,
        subordinate_evaluations: 1,
        subordinate_source_checks: 1
      )

    {:ok, %{capabilities: [capability], close: close}} =
      build_live_llm(limits)

    if close, do: on_exit(close)

    {:ok, workflow_components} =
      Library.resolve_components([
        {:library, "agent.native"},
        {:library, "agent.prompt"},
        {:library, "kernel"},
        {:library, "llm"}
      ])

    {:ok, workflow_bundle} = Kernel.compile_bundle(workflow_components)

    {:ok, mission_component} =
      Component.new(
        id: "e2e.task",
        source: ~S"""
        (ns e2e.task "Small parameterized task API." {:visibility :prompt})

        (defn combine
          "Append the incremented integer to the prefix."
          [prefix number]
          (str prefix ":" (inc number)))
        """
      )

    {:ok, mission_bundle} = Kernel.compile_bundle([mission_component])

    {:ok, workflow} =
      WorkflowEnvironment.new(bundle: workflow_bundle, capabilities: [capability])

    {:ok, mission} = MissionEnvironment.new(bundle: mission_bundle)

    run_id = "deepseek-generated-source-e2e"
    trace_id = "deepseek-generated-source-e2e-trace"
    {:ok, sink} = EventSink.start(:normal, limits, run_id: run_id, trace_id: trace_id)
    {:ok, inspection_sink} = InspectionSink.start(run_id: run_id, trace_id: trace_id)

    prefix = "runtime-" <> Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)
    <<random_number::unsigned-16>> = :crypto.strong_rand_bytes(2)
    number = rem(random_number, 10_000)

    {:ok, config} =
      RunConfig.new(
        workflow_environment: workflow,
        mission_environment: mission,
        input: %{"prefix" => prefix, "number" => number},
        limits: limits,
        event_sink: sink,
        inspection_sink: inspection_sink,
        inspection_path: Path.join(dir, "generated-source.inspection.jsonl")
      )

    source = ~S"""
    (let [prompt-state
          (agent.prompt/initial-state
            {"max_turns" 1
             "max_observation_chars" 2048
             "max_program_chars" 4096})
          response
          (llm/request
            {"system" (agent.prompt/render prompt-state)
             "messages"
             [{"role" "user"
               "content"
               (str "Generate this parameterized PTC-Lisp program exactly, including the "
                    "return form, and submit it through the provided tool:\n"
                    "(return (e2e.task/combine "
                    "(get data/params \"prefix\") "
                    "(get data/params \"number\")))\n"
                    "Do not replace either data/params access with a literal value.")}]
             "tools" [(agent.native/tool-schema)]})
          action (agent.native/normalize response 4096)]
      (if (= :tool-call (get action :kind))
        (let [generated-source (get action :program)
              check (kernel/check-source generated-source)]
          (if (= :valid (get check :outcome))
            (let [evaluation
                  (kernel/eval-source-with
                    generated-source
                    {"prefix" data/prefix "number" data/number})]
              (if (= :returned (get evaluation :outcome))
                (return (get evaluation :value))
                (fail evaluation)))
            (fail check)))
        (fail action)))
    """

    assert {:ok, result} = Kernel.run(source, config)
    {:ok, inspection_records} = InspectionSink.records(inspection_sink)

    assert result.value == "#{prefix}:#{number + 1}"
    assert result.usage.subordinate_source_checks == 1
    assert result.usage.subordinate_evaluations == 1
    assert result.usage.capability_calls.workflow["llm-request"] == 1
    assert result.usage.capability_calls.mission == %{}

    events = EventSink.events(sink)

    assert events
           |> Enum.filter(&(&1.type == "capability-started"))
           |> Enum.map(& &1.data.name) == [
             "kernel-mission-model-context",
             "llm-request",
             "kernel-check-source",
             "kernel-eval"
           ]

    assert events
           |> Enum.filter(&(&1.type == "evaluation-started"))
           |> Enum.map(& &1.data.environment) == [:workflow, :mission]

    assert [%{"payload" => %{"source" => generated_source}}] =
             Enum.filter(
               inspection_records,
               &(&1["record_type"] == "evaluation-source" and
                   &1["payload"]["environment"] == "mission")
             )

    assert generated_source =~ "data/params"
    refute generated_source =~ prefix

    refute events |> Jason.encode!() |> String.contains?(prefix)
  end

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
