defmodule PtcRunner.LLM.StreamingE2ETest do
  use ExUnit.Case, async: false

  @moduledoc """
  End-to-end streaming test for PtcRunner.LLM.stream/2.

  Run with: mix test test/ptc_runner/llm/streaming_e2e_test.exs --include e2e

  Requires OPENROUTER_API_KEY environment variable.
  Optionally set PTC_TEST_MODEL (defaults to gemini).
  """

  @moduletag :e2e

  alias PtcRunner.SubAgent
  alias PtcRunner.TestSupport.LLMSupport

  @timeout 30_000

  setup_all do
    LLMSupport.ensure_api_key!()
    IO.puts("\n=== LLM Streaming E2E Tests ===")
    IO.puts("Model: #{LLMSupport.model()}\n")
    :ok
  end

  describe "SubAgent streaming with on_chunk" do
    @tag timeout: @timeout
    test "streams chunks through SubAgent text-only mode" do
      agent =
        SubAgent.new(prompt: "Say 'hello world' in one short sentence.", output: :text)

      llm = PtcRunner.LLM.callback(LLMSupport.model())

      test_pid = self()
      on_chunk = fn %{delta: text} -> send(test_pid, {:chunk, text}) end

      {:ok, step} = SubAgent.Loop.run(agent, llm: llm, on_chunk: on_chunk)

      assert is_binary(step.return)
      assert String.length(step.return) > 0

      # Collect all chunks received
      chunks = collect_chunks()
      assert chunks != [], "Expected at least one chunk"

      # Concatenated chunks should equal the final response
      concatenated = Enum.join(chunks)
      assert concatenated == step.return
    end
  end

  defp collect_chunks(acc \\ []) do
    receive do
      {:chunk, text} -> collect_chunks(acc ++ [text])
    after
      0 -> acc
    end
  end

  describe "stream/2" do
    @tag timeout: @timeout
    test "streams text chunks from LLM" do
      request = %{
        system: "You are a helpful assistant. Reply in one short sentence.",
        messages: [%{role: :user, content: "What color is the sky on a clear day?"}]
      }

      assert {:ok, stream} = PtcRunner.LLM.stream(LLMSupport.model(), request)

      chunks = Enum.to_list(stream)

      # Should have at least one delta chunk and a done chunk
      delta_chunks = Enum.filter(chunks, &match?(%{delta: _}, &1))
      done_chunks = Enum.filter(chunks, &match?(%{done: true}, &1))

      assert delta_chunks != [], "Expected at least one delta chunk"
      assert length(done_chunks) == 1, "Expected exactly one done chunk"

      # Concatenated text should contain a meaningful response
      full_text = Enum.map_join(delta_chunks, & &1.delta)

      assert String.length(full_text) > 0, "Expected non-empty response text"

      # Done chunk should include token usage
      [done] = done_chunks
      assert is_map(done.tokens), "Expected tokens map in done chunk"
    end
  end
end
