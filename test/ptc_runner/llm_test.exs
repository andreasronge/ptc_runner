defmodule PtcRunner.LLMTest do
  # async: false because tests mutate `Application.put_env(:ptc_runner,
  # :llm_adapter, ...)` which is global. Under async: true a concurrent
  # test can clobber the adapter mid-run.
  use ExUnit.Case, async: false

  defmodule MockAdapter do
    @behaviour PtcRunner.LLM

    @impl true
    def call(_model, %{schema: _schema} = _req) do
      {:ok, %{content: Jason.encode!(%{answer: "structured"}), tokens: %{input: 5, output: 3}}}
    end

    def call(_model, req) do
      {:ok, %{content: "mock response for: #{req.system}", tokens: %{input: 10, output: 5}}}
    end

    @impl true
    def stream(_model, _req) do
      stream =
        Stream.concat(
          [%{delta: "hello "}, %{delta: "world"}],
          [%{done: true, tokens: %{input: 5, output: 2}}]
        )

      {:ok, stream}
    end
  end

  # Records whether its ensure_ready/0 warmup ran (build-time preload test).
  defmodule ReadyProbe do
    @behaviour PtcRunner.LLM

    @impl true
    def ensure_ready do
      Process.put({__MODULE__, :called}, true)
      :ok
    end

    @impl true
    def call(_model, _req), do: {:ok, %{content: "", tokens: %{}}}
  end

  defmodule PublicModelAdapter do
    @behaviour PtcRunner.LLM

    @impl true
    def call(_model, _request), do: {:ok, %{content: "", tokens: %{}}}

    @impl true
    def public_model(model), do: {:ok, model}
  end

  defmodule PreparingAdapter do
    @behaviour PtcRunner.LLM

    @impl true
    def prepare_model(model) do
      send(self(), {:prepared_model, model})
      {:ok, {:prepared, model}, :unavailable}
    end

    @impl true
    def call({:prepared, model}, request) do
      send(self(), {:called_prepared_model, model, request})
      {:ok, %{content: "prepared", tokens: %{}}}
    end

    @impl true
    def stream({:prepared, model}, request) do
      send(self(), {:streamed_prepared_model, model, request})
      {:error, :streaming_not_supported}
    end
  end

  defmodule FailingPreparationAdapter do
    @behaviour PtcRunner.LLM

    @impl true
    def prepare_model(_model), do: {:error, :model_unavailable}

    @impl true
    def call(_model, _request), do: raise("a failed preparation must not reach call/2")
  end

  defmodule UncatalogedPublicAdapter do
    @behaviour PtcRunner.LLM

    @impl true
    def prepare_model(model), do: {:ok, model, :uncataloged}

    @impl true
    def call(_model, _request), do: {:ok, %{content: "", tokens: %{}}}

    @impl true
    def public_model(model), do: {:ok, model}
  end

  defmodule UncatalogedPrivateAdapter do
    @behaviour PtcRunner.LLM

    @impl true
    def prepare_model(model), do: {:ok, model, :uncataloged}

    @impl true
    def call(_model, _request), do: {:ok, %{content: "", tokens: %{}}}
  end

  defmodule MismatchingPublicModelAdapter do
    @behaviour PtcRunner.LLM

    @impl true
    def call(_model, _request), do: {:ok, %{content: "", tokens: %{}}}

    @impl true
    def public_model(_model), do: {:ok, "provider:different"}
  end

  defmodule RaisingPublicModelAdapter do
    @behaviour PtcRunner.LLM

    @impl true
    def call(_model, _request), do: {:ok, %{content: "", tokens: %{}}}

    @impl true
    def public_model(_model), do: raise("private adapter detail")
  end

  setup do
    prev = Application.get_env(:ptc_runner, :llm_adapter)
    Application.put_env(:ptc_runner, :llm_adapter, MockAdapter)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:ptc_runner, :llm_adapter, prev),
        else: Application.delete_env(:ptc_runner, :llm_adapter)
    end)

    :ok
  end

  describe "callback/2 adapter warmup" do
    test "invokes the adapter's ensure_ready/0 at build time, before the request runs" do
      Process.delete({ReadyProbe, :called})
      {:ok, closure} = PtcRunner.LLM.callback("ollama:test-model", adapter: ReadyProbe)
      assert is_function(closure, 1)
      assert Process.get({ReadyProbe, :called}) == true
    end

    test "is a no-op for adapters that do not implement ensure_ready/0" do
      # MockAdapter (installed by setup) defines no ensure_ready/0.
      assert {:ok, callback} = PtcRunner.LLM.callback("ollama:test-model")
      assert is_function(callback, 1)
    end
  end

  describe "callback/2" do
    test "prepares a model once when the requester is constructed" do
      {:ok, callback} =
        PtcRunner.LLM.callback("provider:model",
          adapter: PreparingAdapter,
          temperature: 0.25
        )

      assert_receive {:prepared_model, "provider:model"}
      refute_receive {:prepared_model, _model}

      assert {:ok, %{content: "prepared"}} =
               callback.(%{system: "test", messages: []})

      assert_receive {:called_prepared_model, "provider:model",
                      %{system: "test", messages: [], temperature: 0.25}}

      assert {:ok, %{content: "prepared"}} =
               callback.(%{system: "again", messages: []})

      refute_receive {:prepared_model, _model}
      assert_receive {:called_prepared_model, "provider:model", %{system: "again"}}
    end

    test "uses the prepared target when streaming falls back to call/2" do
      {:ok, callback} = PtcRunner.LLM.callback("provider:model", adapter: PreparingAdapter)

      assert {:ok, %{content: "prepared"}} =
               callback.(%{system: "fallback", messages: [], stream: fn _chunk -> :ok end})

      assert_receive {:prepared_model, "provider:model"}
      assert_receive {:streamed_prepared_model, "provider:model", %{system: "fallback"}}
      assert_receive {:called_prepared_model, "provider:model", %{system: "fallback"}}
      refute_receive {:prepared_model, _model}
    end

    test "returns preparation failures before constructing a requester" do
      assert {:error, :model_unavailable} =
               PtcRunner.LLM.callback("provider:model", adapter: FailingPreparationAdapter)
    end

    test "emits an uncataloged warning once without publishing unattested selectors" do
      public_warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert {:ok, _requester} =
                   PtcRunner.LLM.callback("provider:public", adapter: UncatalogedPublicAdapter)
        end)

      private_warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert {:ok, _requester} =
                   PtcRunner.LLM.callback("provider:private", adapter: UncatalogedPrivateAdapter)
        end)

      assert public_warning =~ "model_uncataloged"
      assert public_warning =~ "provider:public"
      assert private_warning =~ "model_uncataloged"
      refute private_warning =~ "provider:private"
    end

    test "escapes control characters in an attested selector" do
      selector = "provider:public\nwarning: forged"

      warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert {:ok, _requester} =
                   PtcRunner.LLM.callback(selector, adapter: UncatalogedPublicAdapter)
        end)

      assert warning =~ inspect(selector)
      refute warning =~ "public\nwarning: forged"
    end

    test "returns a function that calls the adapter" do
      {:ok, callback} = PtcRunner.LLM.callback("ollama:test-model")
      assert is_function(callback, 1)

      {:ok, resp} = callback.(%{system: "test", messages: []})
      assert resp.content == "mock response for: test"
      assert resp.tokens.input == 10
    end

    test "merges opts into request" do
      {:ok, callback} = PtcRunner.LLM.callback("ollama:test-model", cache: true)
      assert is_function(callback, 1)

      {:ok, resp} = callback.(%{system: "with cache", messages: []})
      assert resp.content == "mock response for: with cache"
    end

    test "streams when request has :stream key and adapter supports streaming" do
      {:ok, callback} = PtcRunner.LLM.callback("ollama:test-model")
      chunks = :ets.new(:chunks, [:ordered_set, :public])

      on_chunk = fn %{delta: text} ->
        :ets.insert(chunks, {System.monotonic_time(), text})
      end

      {:ok, resp} = callback.(%{system: "test", messages: [], stream: on_chunk})

      assert resp.content == "hello world"
      assert resp.tokens == %{input: 5, output: 2}

      collected = :ets.tab2list(chunks) |> Enum.map(fn {_, text} -> text end)
      assert collected == ["hello ", "world"]
    end

    test "falls back to call/2 when adapter has no stream/2" do
      defmodule NoStreamAdapter2 do
        @behaviour PtcRunner.LLM

        @impl true
        def call(_model, _req), do: {:ok, %{content: "fallback", tokens: %{input: 1, output: 1}}}
      end

      Application.put_env(:ptc_runner, :llm_adapter, NoStreamAdapter2)

      {:ok, callback} = PtcRunner.LLM.callback("ollama:test-model")
      chunk_called = :atomics.new(1, [])

      on_chunk = fn _chunk ->
        :atomics.put(chunk_called, 1, 1)
      end

      {:ok, resp} = callback.(%{system: "test", messages: [], stream: on_chunk})

      assert resp.content == "fallback"
      # on_chunk should NOT have been called (adapter doesn't support streaming)
      assert :atomics.get(chunk_called, 1) == 0
    end

    test "stream key is stripped before passing to adapter" do
      {:ok, callback} = PtcRunner.LLM.callback("ollama:test-model")
      # Without stream key, it hits call/2 with system: "test"
      {:ok, resp} = callback.(%{system: "test", messages: [], stream: fn _ -> :ok end})
      # Stream was used, so we get the streamed content
      assert resp.content == "hello world"
    end
  end

  describe "attested_public_model/2" do
    test "accepts only the exact bounded model value" do
      model = "provider:public-model"

      assert PtcRunner.LLM.attested_public_model(PublicModelAdapter, model) == model
      assert PtcRunner.LLM.attested_public_model(MismatchingPublicModelAdapter, model) == nil
      assert PtcRunner.LLM.attested_public_model(MockAdapter, model) == nil
    end

    test "treats adapter failures and malformed values as private" do
      assert PtcRunner.LLM.attested_public_model(RaisingPublicModelAdapter, "provider:model") ==
               nil

      invalid_utf8 = <<"provider:", 255>>
      assert PtcRunner.LLM.attested_public_model(PublicModelAdapter, invalid_utf8) == nil

      oversized = "provider:" <> String.duplicate("m", 256)
      assert PtcRunner.LLM.attested_public_model(PublicModelAdapter, oversized) == nil
    end

    test "the built-in adapter publishes ReqLLM targets but not direct HTTP targets" do
      adapter = PtcRunner.LLM.ReqLLMAdapter
      model = "openrouter:deepseek/deepseek-v4-flash-0731"

      assert PtcRunner.LLM.attested_public_model(adapter, model) == model
      assert PtcRunner.LLM.attested_public_model(adapter, "ollama:local-model") == nil

      assert PtcRunner.LLM.attested_public_model(
               adapter,
               "openai-compat:https://private.example/v1|deployment"
             ) == nil
    end
  end

  describe "call/2" do
    test "delegates to adapter" do
      {:ok, resp} = PtcRunner.LLM.call("ollama:test-model", %{system: "hello", messages: []})
      assert resp.content == "mock response for: hello"
    end

    test "prepares before delegating" do
      Application.put_env(:ptc_runner, :llm_adapter, PreparingAdapter)

      assert {:ok, %{content: "prepared"}} =
               PtcRunner.LLM.call("provider:model", %{system: "hello", messages: []})

      assert_receive {:prepared_model, "provider:model"}
      assert_receive {:called_prepared_model, "provider:model", %{system: "hello"}}
      refute_receive {:prepared_model, _model}
    end
  end

  describe "adapter!/0" do
    test "returns configured adapter" do
      assert PtcRunner.LLM.adapter!() == MockAdapter
    end

    test "resolves to the packaged ReqLLMAdapter default" do
      # mix.exs ships :llm_adapter => ReqLLMAdapter; the setup overrides it with
      # MockAdapter, so restore the packaged default for this assertion.
      Application.put_env(:ptc_runner, :llm_adapter, PtcRunner.LLM.ReqLLMAdapter)
      # ReqLLM is available in test env (via optional req_llm dep)
      assert PtcRunner.LLM.adapter!() == PtcRunner.LLM.ReqLLMAdapter
    end

    test "raises when no adapter is configured" do
      Application.delete_env(:ptc_runner, :llm_adapter)

      assert_raise RuntimeError, ~r/No LLM adapter configured/, fn ->
        PtcRunner.LLM.adapter!()
      end
    end

    test "raises with actionable message when configured adapter cannot be loaded" do
      Application.put_env(:ptc_runner, :llm_adapter, NonExistent.Adapter)

      assert_raise RuntimeError, ~r/req_llm/, fn ->
        PtcRunner.LLM.adapter!()
      end
    end
  end
end
