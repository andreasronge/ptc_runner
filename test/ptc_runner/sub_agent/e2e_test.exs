defmodule PtcRunner.SubAgent.E2ETest do
  use ExUnit.Case, async: false

  @moduledoc """
  End-to-end tests for SubAgent using real LLM calls.

  Run with: mix test test/ptc_runner/sub_agent/e2e_test.exs --include e2e

  Requires OPENROUTER_API_KEY environment variable.
  Optionally set PTC_TEST_MODEL (defaults to gemini).
  """

  @moduletag :e2e

  alias PtcRunner.SubAgent
  alias PtcRunner.TestSupport.LispLLMClient

  @timeout 30_000

  setup_all do
    ensure_api_key!()
    IO.puts("\n=== SubAgent E2E Tests ===")
    IO.puts("Model: #{model()}\n")
    :ok
  end

  describe "single-shot mode" do
    test "simple arithmetic" do
      agent =
        SubAgent.new(
          prompt: "What is 2 + 2?",
          signature: "() -> :int",
          max_turns: 1
        )

      assert {:ok, step} = SubAgent.run(agent, llm: llm_callback())
      assert step.return == 4
    end

    test "string transformation" do
      agent =
        SubAgent.new(
          prompt: "Convert 'hello' to uppercase",
          signature: "() -> :string",
          max_turns: 1
        )

      assert {:ok, step} = SubAgent.run(agent, llm: llm_callback())
      assert step.return == "HELLO"
    end

    test "with context data" do
      agent =
        SubAgent.new(
          prompt: "Sum the numbers in ctx/numbers using reduce",
          signature: "(numbers [:int]) -> :int",
          max_turns: 1
        )

      context = %{"numbers" => [1, 2, 3, 4, 5]}

      assert {:ok, step} = SubAgent.run(agent, llm: llm_callback(), context: context)
      assert step.return == 15
    end
  end

  defp model, do: LispLLMClient.model()

  defp llm_callback do
    fn %{system: system, messages: messages} ->
      # Build messages with system prompt
      full_messages = [%{role: :system, content: system} | messages]

      case ReqLLM.generate_text(model(), full_messages, receive_timeout: @timeout) do
        {:ok, %ReqLLM.Response{} = response} ->
          text = ReqLLM.Response.text(response)
          {:ok, text}

        {:error, _} = error ->
          error
      end
    end
  end

  defp ensure_api_key! do
    LispLLMClient.model()

    unless System.get_env("OPENROUTER_API_KEY") do
      raise """
      OPENROUTER_API_KEY not set.

      Create .env file with:
        OPENROUTER_API_KEY=sk-or-...
        PTC_TEST_MODEL=haiku  # optional
      """
    end
  end
end
