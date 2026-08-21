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
  alias PtcRunner.LLM
  alias PtcRunner.LLM.PtcLlmHttpAdapter
  alias PtcRunner.LLM.ReqLLMAdapter
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

  test "a live OpenRouter non-streaming host installation completes through PtcLlmHttp" do
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
        refute inspect(EventSink.events(sink)) =~ key
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

  test "a live OpenRouter stream delivers ordered deltas, content, and usage" do
    key = System.fetch_env!("OPENROUTER_API_KEY")
    model = live_openrouter_model()
    request = live_stream_request()

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        :ok = LLMSupport.admit_provider_application!()

        {:ok, ptc_requester} =
          LLM.callback(model, adapter: PtcLlmHttpAdapter, api_key: key)

        {:ok, req_requester} =
          LLM.callback(model, adapter: ReqLLMAdapter, api_key: key)

        received = :ets.new(__MODULE__.LiveStream, [:public, :ordered_set])

        ptc_result =
          ptc_requester.(
            Map.put(request, :stream, fn %{delta: text} ->
              :ets.insert(received, {:erlang.unique_integer([:monotonic]), text})
            end)
          )

        deltas =
          received
          |> :ets.tab2list()
          |> Enum.sort()
          |> Enum.map(&elem(&1, 1))

        assert_live_stream_success(ptc_result, deltas, key)

        assert {:ok, req_result} = req_requester.(request)
        assert_stable_control_shape(req_result, ptc_result, key)
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

  defp live_stream_request do
    %{
      system: "Follow the user's output constraint exactly.",
      messages: [
        %{role: :user, content: "Reply with exactly KERNEL_OK and nothing else."}
      ],
      temperature: 0.0,
      seed: 1168,
      max_tokens: 64
    }
  end

  defp assert_live_stream_success(result, deltas, key) do
    assert deltas != []
    assert Enum.all?(deltas, &is_binary/1)
    version = Application.spec(:ptc_llm_http, :vsn)

    case {version, result} do
      {_, {:ok, %{content: content} = value}} ->
        refute inspect(value) =~ key
        assert Enum.join(deltas) == content
        assert is_binary(content)
        assert String.trim(content) != ""
        assert_usage_shape(value, key)

      {~c"0.1.0", {:error, %ProviderError{kind: :invalid_result, retryable?: false} = error}} ->
        # Published 0.1.0 rejects OpenRouter's repeated-finish usage event after
        # the deltas have already been delivered (ptc_llm_http#15).
        assert error.dispatch_provenance == :possibly_dispatched
        refute inspect(error) =~ key

      other ->
        flunk("unexpected live OpenRouter stream result: #{inspect(other)}")
    end
  end

  defp assert_stable_control_shape(req_result, ptc_result, key) do
    assert %{content: req_content} = req_result
    refute inspect(req_result) =~ key
    assert is_binary(req_content)
    assert String.trim(req_content) != ""
    assert_usage_shape(req_result, key)

    case ptc_result do
      {:ok, %{content: ptc_content} = ptc_value} ->
        assert is_binary(ptc_content)
        assert_usage_shape(ptc_value, key)

      {:error, %ProviderError{}} ->
        :ok
    end
  end

  defp assert_usage_shape(%{tokens: tokens}, key) when is_map(tokens) do
    refute inspect(tokens) =~ key

    if map_size(tokens) > 0 do
      assert is_integer(tokens[:input]) or is_integer(tokens[:output])
    end
  end

  defp assert_usage_shape(_without_tokens, _key), do: :ok

  defp restore_env(key, {:ok, value}), do: Application.put_env(:ptc_runner, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:ptc_runner, key)
end
