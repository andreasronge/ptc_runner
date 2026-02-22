defmodule PtcRunner.SubAgent.TextModeTextE2ETest do
  use ExUnit.Case, async: false

  @moduledoc """
  End-to-end tests for SubAgent plain text mode using real LLM calls.

  Run with: mix test test/ptc_runner/sub_agent/text_mode_text_e2e_test.exs --include e2e

  Requires OPENROUTER_API_KEY environment variable.
  Optionally set PTC_TEST_MODEL (defaults to gemini-2.5-flash).
  """

  @moduletag :e2e

  alias PtcRunner.SubAgent
  alias PtcRunner.TestSupport.LLMSupport

  @timeout 30_000

  setup_all do
    LLMSupport.ensure_api_key!()
    IO.puts("\n=== SubAgent Plain Text Mode E2E Tests ===")
    IO.puts("Model: #{LLMSupport.model()}\n")
    :ok
  end

  describe "plain text (no signature)" do
    test "returns raw text response" do
      agent =
        SubAgent.new(
          prompt: "What is the capital of France? Answer in one word.",
          output: :text,
          max_turns: 1
        )

      {:ok, step} = SubAgent.run(agent, llm: llm_callback())

      assert is_binary(step.return)
      assert step.return =~ ~r/paris/i
    end

    test "expands context into prompt" do
      agent =
        SubAgent.new(
          prompt: "Translate the following word to French: {{word}}",
          output: :text,
          max_turns: 1
        )

      {:ok, step} =
        SubAgent.run(agent,
          llm: llm_callback(),
          context: %{word: "hello"}
        )

      assert is_binary(step.return)
      assert step.return =~ ~r/bonjour/i
    end

    test "captures token usage" do
      agent =
        SubAgent.new(
          prompt: "Say hello.",
          output: :text,
          max_turns: 1
        )

      {:ok, step} = SubAgent.run(agent, llm: llm_callback())

      assert step.usage.turns == 1
      assert step.usage.input_tokens > 0
      assert step.usage.output_tokens > 0
    end
  end

  describe "plain text with :string signature" do
    test "returns raw text with string return type" do
      agent =
        SubAgent.new(
          prompt: "What color is the sky on a clear day? Answer in one word.",
          output: :text,
          signature: "() -> :string",
          max_turns: 1
        )

      {:ok, step} = SubAgent.run(agent, llm: llm_callback())

      assert is_binary(step.return)
      assert step.return =~ ~r/blue/i
    end
  end

  defp llm_callback do
    fn %{system: system, messages: messages} ->
      full_messages = [%{role: :system, content: system} | messages]
      model = LLMSupport.model()

      case LLMClient.generate_text(model, full_messages, receive_timeout: @timeout) do
        {:ok, %{content: text, tokens: tokens}} ->
          {:ok, %{content: text, tokens: tokens}}

        {:ok, %{content: text}} ->
          {:ok, text}

        {:error, _} = error ->
          error
      end
    end
  end
end
