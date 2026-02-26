defmodule PtcRunner.LLMTest do
  use ExUnit.Case, async: true

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

  describe "callback/2" do
    test "returns a function that calls the adapter" do
      callback = PtcRunner.LLM.callback("test:model")
      assert is_function(callback, 1)

      {:ok, resp} = callback.(%{system: "test", messages: []})
      assert resp.content == "mock response for: test"
      assert resp.tokens.input == 10
    end

    test "merges opts into request" do
      callback = PtcRunner.LLM.callback("test:model", cache: true)
      assert is_function(callback, 1)

      {:ok, resp} = callback.(%{system: "with cache", messages: []})
      assert resp.content == "mock response for: with cache"
    end

    test "streams when request has :stream key and adapter supports streaming" do
      callback = PtcRunner.LLM.callback("test:model")
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

      callback = PtcRunner.LLM.callback("test:model")
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
      callback = PtcRunner.LLM.callback("test:model")
      # Without stream key, it hits call/2 with system: "test"
      {:ok, resp} = callback.(%{system: "test", messages: [], stream: fn _ -> :ok end})
      # Stream was used, so we get the streamed content
      assert resp.content == "hello world"
    end
  end

  describe "call/2" do
    test "delegates to adapter" do
      {:ok, resp} = PtcRunner.LLM.call("test:model", %{system: "hello", messages: []})
      assert resp.content == "mock response for: hello"
    end
  end

  describe "stream/2" do
    test "returns a stream of chunks" do
      {:ok, stream} = PtcRunner.LLM.stream("test:model", %{system: "hi", messages: []})

      chunks = Enum.to_list(stream)
      assert [%{delta: "hello "}, %{delta: "world"}, %{done: true, tokens: _}] = chunks
    end

    test "returns error when adapter doesn't support streaming" do
      defmodule NoStreamAdapter do
        @behaviour PtcRunner.LLM

        @impl true
        def call(_model, _req), do: {:ok, %{content: "ok", tokens: %{}}}
      end

      Application.put_env(:ptc_runner, :llm_adapter, NoStreamAdapter)

      assert {:error, :streaming_not_supported} =
               PtcRunner.LLM.stream("test:model", %{system: "hi", messages: []})
    end
  end

  describe "consume_stream/2" do
    test "returns error tuple on exception in stream" do
      bad_stream = Stream.map([1], fn _ -> raise "boom" end)

      assert {:error, {:stream_error, %RuntimeError{message: "boom"}}} =
               PtcRunner.LLM.consume_stream(bad_stream, fn _ -> :ok end)
    end

    test "returns error tuple on exception in on_chunk callback" do
      stream = [%{delta: "hi"}]

      assert {:error, {:stream_error, %RuntimeError{message: "chunk error"}}} =
               PtcRunner.LLM.consume_stream(stream, fn _ -> raise "chunk error" end)
    end
  end

  describe "adapter!/0" do
    test "returns configured adapter" do
      assert PtcRunner.LLM.adapter!() == MockAdapter
    end

    test "falls back to ReqLLMAdapter when no config" do
      Application.delete_env(:ptc_runner, :llm_adapter)
      # ReqLLM is available in test env (via llm_client dep)
      assert PtcRunner.LLM.adapter!() == PtcRunner.LLM.ReqLLMAdapter
    end
  end
end
