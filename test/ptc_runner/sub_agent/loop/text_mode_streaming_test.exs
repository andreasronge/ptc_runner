defmodule PtcRunner.SubAgent.Loop.TextModeStreamingTest do
  @moduledoc """
  Integration tests for on_chunk streaming in text-only mode.
  """
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent

  defmodule StreamingMockAdapter do
    @behaviour PtcRunner.LLM

    @impl true
    def call(_model, _req) do
      {:ok, %{content: "full response", tokens: %{input: 10, output: 5}}}
    end

    @impl true
    def stream(_model, _req) do
      stream =
        Stream.concat(
          [%{delta: "hello "}, %{delta: "world"}],
          [%{done: true, tokens: %{input: 8, output: 3}}]
        )

      {:ok, stream}
    end
  end

  defmodule NonStreamingMockAdapter do
    @behaviour PtcRunner.LLM

    @impl true
    def call(_model, _req) do
      {:ok, %{content: "full response", tokens: %{input: 10, output: 5}}}
    end
  end

  describe "on_chunk with text-only SubAgent" do
    test "chunks are received during streaming" do
      prev = Application.get_env(:ptc_runner, :llm_adapter)
      Application.put_env(:ptc_runner, :llm_adapter, StreamingMockAdapter)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:ptc_runner, :llm_adapter, prev),
          else: Application.delete_env(:ptc_runner, :llm_adapter)
      end)

      agent = SubAgent.new(prompt: "Say hello", output: :text)
      llm = PtcRunner.LLM.callback("test:model")

      test_pid = self()
      on_chunk = fn %{delta: text} -> send(test_pid, {:chunk, text}) end

      {:ok, step} = SubAgent.Loop.run(agent, llm: llm, on_chunk: on_chunk)

      assert step.return == "hello world"
      assert_received {:chunk, "hello "}
      assert_received {:chunk, "world"}
    end

    test "graceful degradation: on_chunk fires once when adapter has no stream/2" do
      prev = Application.get_env(:ptc_runner, :llm_adapter)
      Application.put_env(:ptc_runner, :llm_adapter, NonStreamingMockAdapter)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:ptc_runner, :llm_adapter, prev),
          else: Application.delete_env(:ptc_runner, :llm_adapter)
      end)

      agent = SubAgent.new(prompt: "Say hello", output: :text)
      llm = PtcRunner.LLM.callback("test:model")

      test_pid = self()
      on_chunk = fn %{delta: text} -> send(test_pid, {:chunk, text}) end

      {:ok, step} = SubAgent.Loop.run(agent, llm: llm, on_chunk: on_chunk)

      assert step.return == "full response"
      # Should fire once with the full content
      assert_received {:chunk, "full response"}
    end

    test "on_chunk fires once with full content for tool-using agents" do
      agent =
        SubAgent.new(
          prompt: "Use the tool",
          output: :text,
          tools: %{"greet" => fn _args -> "hi" end}
        )

      # For tool mode, we need a function-based LLM that returns text (final answer)
      llm = fn _req ->
        {:ok, %{content: "final answer", tokens: %{input: 5, output: 3}}}
      end

      test_pid = self()
      on_chunk = fn %{delta: text} -> send(test_pid, {:chunk, text}) end

      {:ok, step} = SubAgent.Loop.run(agent, llm: llm, on_chunk: on_chunk)

      assert step.return == "final answer"
      # on_chunk fires once with full content on final answer
      assert_received {:chunk, "final answer"}
    end

    test "on_chunk exception in text-only mode does not crash the loop" do
      prev = Application.get_env(:ptc_runner, :llm_adapter)
      Application.put_env(:ptc_runner, :llm_adapter, NonStreamingMockAdapter)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:ptc_runner, :llm_adapter, prev),
          else: Application.delete_env(:ptc_runner, :llm_adapter)
      end)

      agent = SubAgent.new(prompt: "Say hello", output: :text)
      llm = PtcRunner.LLM.callback("test:model")

      on_chunk = fn _chunk -> raise "socket closed" end

      # Should succeed despite on_chunk raising — graceful degradation path
      {:ok, step} = SubAgent.Loop.run(agent, llm: llm, on_chunk: on_chunk)
      assert step.return == "full response"
    end

    test "on_chunk exception in tool-variant final answer does not crash the loop" do
      agent =
        SubAgent.new(
          prompt: "Use the tool",
          output: :text,
          tools: %{"greet" => fn _args -> "hi" end}
        )

      llm = fn _req ->
        {:ok, %{content: "final answer", tokens: %{input: 5, output: 3}}}
      end

      on_chunk = fn _chunk -> raise "LiveView crashed" end

      # Should succeed despite on_chunk raising
      {:ok, step} = SubAgent.Loop.run(agent, llm: llm, on_chunk: on_chunk)
      assert step.return == "final answer"
    end

    test "works without on_chunk (default behavior unchanged)" do
      prev = Application.get_env(:ptc_runner, :llm_adapter)
      Application.put_env(:ptc_runner, :llm_adapter, StreamingMockAdapter)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:ptc_runner, :llm_adapter, prev),
          else: Application.delete_env(:ptc_runner, :llm_adapter)
      end)

      agent = SubAgent.new(prompt: "Say hello", output: :text)
      llm = PtcRunner.LLM.callback("test:model")

      # No on_chunk — should work exactly as before (call/2 path)
      {:ok, step} = SubAgent.Loop.run(agent, llm: llm)
      assert step.return == "full response"
    end
  end
end
