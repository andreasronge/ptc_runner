defmodule PtcRunner.SubAgent.E2ETest do
  use ExUnit.Case, async: false

  @moduledoc """
  End-to-end tests for SubAgent using real LLM calls.

  Run with: mix test test/ptc_runner/sub_agent/e2e_test.exs --include e2e

  Requires OPENROUTER_API_KEY environment variable.
  Optionally set PTC_TEST_MODEL (defaults to gemini).
  """

  @moduletag :e2e

  alias PtcRunner.Lisp.LanguageSpec
  alias PtcRunner.SubAgent
  alias PtcRunner.TestSupport.LispLLMClient
  alias PtcRunner.TestSupport.LLM

  @timeout 30_000
  # Use single-shot prompt - no return/fail tools, expression value is the result
  @prompt_profile :single_shot

  setup_all do
    ensure_api_key!()
    IO.puts("\n=== SubAgent E2E Tests ===")
    IO.puts("Model: #{model()}")
    IO.puts("Prompt: #{@prompt_profile}\n")
    :ok
  end

  describe "single-shot mode" do
    test "simple arithmetic" do
      agent =
        SubAgent.new(
          prompt: "What is 2 + 2?",
          signature: "() -> :int",
          max_turns: 1,
          # String override completely replaces generated prompt (no return/fail tools)
          system_prompt: LanguageSpec.get(@prompt_profile)
        )

      assert {:ok, step} = SubAgent.run(agent, llm: llm_callback())
      assert step.return == 4
    end

    test "count items in context" do
      agent =
        SubAgent.new(
          prompt: "How many items are in data/items?",
          signature: "(items [:any]) -> :int",
          max_turns: 1,
          system_prompt: LanguageSpec.get(@prompt_profile)
        )

      context = %{"items" => [1, 2, 3, 4, 5]}

      assert {:ok, step} = SubAgent.run(agent, llm: llm_callback(), context: context)
      assert step.return == 5
    end

    test "sum field in context" do
      agent =
        SubAgent.new(
          prompt: "What is the total of all :amount values in data/orders?",
          signature: "(orders [{amount :int}]) -> :int",
          max_turns: 1,
          system_prompt: LanguageSpec.get(@prompt_profile)
        )

      context = %{"orders" => [%{"amount" => 10}, %{"amount" => 20}, %{"amount" => 30}]}

      assert {:ok, step} = SubAgent.run(agent, llm: llm_callback(), context: context)
      assert step.return == 60
    end
  end

  describe "compile" do
    test "count r's in word - compiled agent works on multiple inputs" do
      agent =
        SubAgent.new(
          prompt: "How many r's are in {{word}}?",
          signature: "(word :string) -> :int",
          max_turns: 1
        )

      # Compile the agent - LLM derives the logic once
      assert {:ok, compiled} = SubAgent.compile(agent, llm: llm_callback())

      # Compiled source should reference data/word, not hardcode a value
      assert compiled.source =~ "data/word"

      # Execute on multiple inputs without further LLM calls
      step1 = compiled.execute.(%{"word" => "strawberry"})
      assert step1.return == 3

      step2 = compiled.execute.(%{"word" => "program"})
      assert step2.return == 2

      step3 = compiled.execute.(%{"word" => "hello"})
      assert step3.return == 0
    end
  end

  defp model, do: LispLLMClient.model()

  defp llm_callback do
    fn %{system: system, messages: messages} ->
      # Build messages with system prompt
      full_messages = [%{role: :system, content: system} | messages]

      # Use TestSupport.LLM which handles both local and cloud providers
      case LLM.generate_text(model(), full_messages, receive_timeout: @timeout) do
        {:ok, text} ->
          {:ok, text}

        {:error, _} = error ->
          error
      end
    end
  end

  defp ensure_api_key! do
    model = LispLLMClient.model()

    # Skip API key check for local providers
    unless local_provider?(model) or System.get_env("OPENROUTER_API_KEY") do
      raise """
      OPENROUTER_API_KEY not set.

      Create .env file with:
        OPENROUTER_API_KEY=sk-or-...
        PTC_TEST_MODEL=haiku  # optional

      Or use a local model (no API key required):
        PTC_TEST_MODEL=deepseek-local
      """
    end
  end

  defp local_provider?(model) do
    String.starts_with?(model, "ollama:") or
      String.starts_with?(model, "openai-compat:")
  end
end
