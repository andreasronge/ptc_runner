defmodule PtcRunner.Kernel.DeepSeekE2ETest do
  use ExUnit.Case, async: false

  @moduletag :e2e
  @moduletag timeout: 120_000

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.WorkflowEnvironment

  setup_all do
    :ok = PtcRunner.Dotenv.load()

    if System.get_env("OPENROUTER_API_KEY") do
      :ok
    else
      {:skip, "OPENROUTER_API_KEY is not configured"}
    end
  end

  test "a live DeepSeek request crosses the bounded Kernel capability boundary" do
    model = System.get_env("PTC_TEST_MODEL", "deepseek")
    {:ok, registry} = ProviderRegistry.new()

    {:ok, %{capabilities: [capability], close: close}} =
      ProviderRegistry.build(
        registry,
        "llm",
        %{"model" => model},
        %{directory: File.cwd!(), destination: :workflow}
      )

    if close, do: on_exit(close)

    {:ok, component} = Library.component("llm")
    {:ok, bundle} = Kernel.compile_bundle([component])
    {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle, capabilities: [capability])
    {:ok, mission} = MissionEnvironment.new([])
    {:ok, limits} = Limits.new(run_duration_ms: 90_000, workflow_timeout_ms: 90_000)
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
end
