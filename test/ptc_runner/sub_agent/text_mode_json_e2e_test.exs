defmodule PtcRunner.SubAgent.TextModeJsonE2ETest do
  use ExUnit.Case, async: false

  @moduledoc """
  End-to-end tests for SubAgent JSON mode using real LLM calls.

  Run with: mix test test/ptc_runner/sub_agent/json_mode_e2e_test.exs --include e2e

  Requires OPENROUTER_API_KEY environment variable.
  Optionally set PTC_TEST_MODEL (defaults to gemini-2.5-flash).
  """

  @moduletag :e2e

  alias PtcRunner.SubAgent
  alias PtcRunner.TestSupport.LLMSupport

  @timeout 30_000

  setup_all do
    LLMSupport.ensure_api_key!()
    IO.puts("\n=== SubAgent JSON Mode E2E Tests ===")
    IO.puts("Model: #{LLMSupport.model()}\n")
    :ok
  end

  describe "basic JSON mode" do
    test "simple classification" do
      agent =
        SubAgent.new(
          prompt: "Classify the sentiment of: '{{text}}'",
          output: :text,
          signature: "(text :string) -> {sentiment :string}",
          max_turns: 2
        )

      {:ok, step} =
        SubAgent.run(agent,
          llm: llm_callback(),
          context: %{text: "I love this product!"}
        )

      assert step.return["sentiment"] in ["positive", "Positive", "POSITIVE"]
    end

    test "extract structured data" do
      agent =
        SubAgent.new(
          prompt: "Extract the name and age from: '{{text}}'",
          output: :text,
          signature: "(text :string) -> {name :string, age :int}",
          max_turns: 2
        )

      {:ok, step} =
        SubAgent.run(agent,
          llm: llm_callback(),
          context: %{text: "John is 25 years old"}
        )

      assert step.return["name"] == "John"
      assert step.return["age"] == 25
    end

    test "simple arithmetic reasoning" do
      agent =
        SubAgent.new(
          prompt: "What is {{a}} + {{b}}?",
          output: :text,
          signature: "(a :int, b :int) -> {result :int}",
          max_turns: 2
        )

      {:ok, step} =
        SubAgent.run(agent,
          llm: llm_callback(),
          context: %{a: 17, b: 25}
        )

      assert step.return["result"] == 42
    end

    test "list extraction" do
      agent =
        SubAgent.new(
          prompt: "Extract all fruits mentioned in: '{{text}}'",
          output: :text,
          signature: "(text :string) -> {fruits [:string]}",
          max_turns: 2
        )

      {:ok, step} =
        SubAgent.run(agent,
          llm: llm_callback(),
          context: %{text: "I bought apples, bananas, and oranges at the store"}
        )

      fruits = step.return["fruits"] |> Enum.map(&String.downcase/1) |> Enum.sort()
      assert fruits == ["apples", "bananas", "oranges"]
    end
  end

  describe "with field descriptions" do
    test "uses field descriptions for better output" do
      agent =
        SubAgent.new(
          prompt: "Analyze the review: '{{review}}'",
          output: :text,
          signature: "(review :string) -> {sentiment :string, confidence :float}",
          field_descriptions: %{
            sentiment: "One of: positive, negative, neutral",
            confidence: "Confidence score between 0.0 and 1.0"
          },
          max_turns: 2
        )

      {:ok, step} =
        SubAgent.run(agent,
          llm: llm_callback(),
          context: %{review: "This is absolutely amazing!"}
        )

      assert step.return["sentiment"] in ["positive", "Positive"]
      assert step.return["confidence"] >= 0.0 and step.return["confidence"] <= 1.0
    end
  end

  # Build LLM callback that works with JSON mode
  defp llm_callback do
    fn %{system: system, messages: messages, output: _output, schema: schema} = _input ->
      # Build messages with system prompt
      full_messages = [%{role: :system, content: system} | messages]

      model = LLMSupport.model()

      # For JSON mode, we can optionally pass the schema to providers that support it
      opts = [receive_timeout: @timeout]

      opts =
        if schema do
          # Some providers support structured output
          Keyword.put(opts, :response_format, %{type: "json_object"})
        else
          opts
        end

      case LLMClient.generate_text(model, full_messages, opts) do
        {:ok, %{content: text}} ->
          {:ok, text}

        {:error, _} = error ->
          error
      end
    end
  end
end
