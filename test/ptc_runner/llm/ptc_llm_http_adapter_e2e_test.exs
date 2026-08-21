defmodule PtcRunner.LLM.PtcLlmHttpAdapterE2ETest do
  use ExUnit.Case, async: false

  @moduletag :e2e
  @moduletag timeout: 120_000
  @external_resource Path.expand("../../../.env", __DIR__)

  alias PtcRunner.Kernel
  alias PtcRunner.Kernel.EventSink
  alias PtcRunner.Kernel.HostConfig
  alias PtcRunner.Kernel.HostInstallation
  alias PtcRunner.Kernel.Library
  alias PtcRunner.Kernel.Limits
  alias PtcRunner.Kernel.MissionEnvironment
  alias PtcRunner.Kernel.ProviderError
  alias PtcRunner.Kernel.ProviderRegistry
  alias PtcRunner.Kernel.RunConfig
  alias PtcRunner.Kernel.WorkflowEnvironment
  alias PtcRunner.LLM.PtcLlmHttpAdapter
  alias PtcRunner.TestSupport.LLMSupport

  @host Path.expand("../../../examples/kernel-tutorial/ptc-host.json", __DIR__)

  # ExUnit 1.20 only honors skip tags, not `{:skip, reason}` from setup.
  # Load `.env` before the tag so a checkout-local key is visible here.
  _ = LLMSupport.load_dotenv()

  if System.get_env("OPENROUTER_API_KEY") in [nil, ""] do
    @moduletag skip: "OPENROUTER_API_KEY is not configured"
  end

  setup_all do
    previous_adapter = Application.fetch_env(:ptc_runner, :llm_adapter)
    Application.put_env(:ptc_runner, :llm_adapter, PtcLlmHttpAdapter)

    on_exit(fn ->
      restore_env(:llm_adapter, previous_adapter)
    end)

    :ok
  end

  test "a live OpenRouter host installation completes through PtcLlmHttp" do
    key = System.fetch_env!("OPENROUTER_API_KEY")
    model = live_openrouter_model()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, limits} = Limits.new(run_duration_ms: 90_000, workflow_timeout_ms: 90_000)

        {:ok, %{capabilities: [capability], close: close}} = build_live_llm(limits, model)
        if close, do: on_exit(close)

        {:ok, component} = Library.component("llm")
        {:ok, bundle} = Kernel.compile_bundle([component])
        {:ok, workflow} = WorkflowEnvironment.new(bundle: bundle, capabilities: [capability])
        {:ok, mission} = MissionEnvironment.new([])
        {:ok, sink} = EventSink.start(:normal, limits, run_id: "ptc-llm-http-e2e")
        on_exit(fn -> EventSink.stop(sink) end)

        {:ok, config} =
          RunConfig.new(
            workflow_environment: workflow,
            missions: %{"default" => mission},
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

        assert {:ok, %{value: %{"content" => content} = value}} = Kernel.run(source, config)
        refute inspect(value) =~ key
        assert is_binary(content)
        assert String.trim(content) != ""

        case value do
          %{"tokens" => tokens} ->
            assert is_map(tokens)
            refute inspect(tokens) =~ key

          _without_tokens ->
            :ok
        end
      end)

    refute log =~ key
  end

  test "unsupported live selectors fail during preparation" do
    key = System.fetch_env!("OPENROUTER_API_KEY")

    assert {:error, %ProviderError{kind: :invalid_request, retryable?: false} = error} =
             PtcLlmHttpAdapter.prepare_model("ollama:local-model")

    refute inspect(error) =~ key
  end

  defp live_openrouter_model do
    model = LLMSupport.model()

    if String.starts_with?(model, "openrouter:") and model != "openrouter:" do
      model
    else
      "openrouter:deepseek/deepseek-v4-flash"
    end
  end

  defp build_live_llm(limits, model) do
    {:ok, host} = HostConfig.load(@host)

    host =
      update_in(host.install["deepseek"], fn installation ->
        %{
          installation
          | model: model,
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

  defp restore_env(key, {:ok, value}), do: Application.put_env(:ptc_runner, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:ptc_runner, key)
end
