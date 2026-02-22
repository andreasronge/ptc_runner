defmodule PtcRunner.SubAgent.TextModeTextTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Loop

  describe "text-only variant (no tools, string/no return type)" do
    test "returns raw text when no signature" do
      agent =
        SubAgent.new(
          prompt: "Summarize this",
          output: :text,
          max_turns: 1
        )

      llm = fn _input ->
        {:ok, "This is a summary of the content."}
      end

      {:ok, step} = Loop.run(agent, llm: llm)

      assert step.return == "This is a summary of the content."
      assert step.memory == %{}
      assert step.fail == nil
    end

    test "returns raw text when signature has :string return" do
      agent =
        SubAgent.new(
          prompt: "Translate {{text}}",
          output: :text,
          signature: "(text :string) -> :string",
          max_turns: 1
        )

      llm = fn _input ->
        {:ok, "Bonjour le monde"}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{text: "Hello world"})

      assert step.return == "Bonjour le monde"
    end

    test "expands mustache templates in prompt" do
      agent =
        SubAgent.new(
          prompt: "Tell me about {{topic}}",
          output: :text,
          max_turns: 1
        )

      llm = fn %{messages: [%{content: user_msg}]} ->
        assert user_msg =~ "Tell me about Elixir"
        {:ok, "Elixir is a functional language."}
      end

      {:ok, step} = Loop.run(agent, llm: llm, context: %{topic: "Elixir"})

      assert step.return == "Elixir is a functional language."
    end

    test "captures token counts in usage" do
      agent =
        SubAgent.new(
          prompt: "Hello",
          output: :text,
          max_turns: 1
        )

      llm = fn _input ->
        {:ok, %{content: "Hi there!", tokens: %{input: 10, output: 5}}}
      end

      {:ok, step} = Loop.run(agent, llm: llm)

      assert step.return == "Hi there!"
      assert step.usage.input_tokens == 10
      assert step.usage.output_tokens == 5
      assert step.usage.turns == 1
    end

    test "records exactly one turn" do
      agent =
        SubAgent.new(
          prompt: "Hello",
          output: :text,
          max_turns: 1
        )

      llm = fn _input ->
        {:ok, "Response"}
      end

      {:ok, step} = Loop.run(agent, llm: llm, trace: true)

      assert length(step.turns) == 1
      [turn] = step.turns
      assert turn.success?
    end

    test "returns empty string when LLM returns empty string" do
      agent =
        SubAgent.new(
          prompt: "Hello",
          output: :text,
          max_turns: 1
        )

      llm = fn _input ->
        {:ok, ""}
      end

      {:ok, step} = Loop.run(agent, llm: llm)

      assert step.return == ""
    end

    test "returns error on LLM failure" do
      agent =
        SubAgent.new(
          prompt: "Hello",
          output: :text,
          max_turns: 1
        )

      llm = fn _input ->
        {:error, "connection timeout"}
      end

      {:error, step} = Loop.run(agent, llm: llm)

      assert step.fail.reason == :llm_error
    end

    test "sends system prompt to LLM" do
      agent =
        SubAgent.new(
          prompt: "Hello",
          output: :text,
          max_turns: 1
        )

      llm = fn %{system: system} ->
        assert is_binary(system)
        assert String.length(system) > 0
        {:ok, "Response"}
      end

      {:ok, _step} = Loop.run(agent, llm: llm)
    end

    test "collects messages when collect_messages is true" do
      agent =
        SubAgent.new(
          prompt: "Hello",
          output: :text,
          max_turns: 1
        )

      llm = fn _input ->
        {:ok, "Response"}
      end

      {:ok, step} = Loop.run(agent, llm: llm, collect_messages: true)

      assert is_list(step.messages)
      assert step.messages != []
    end
  end

  describe "text_return? detection" do
    test "true when no signature" do
      agent = SubAgent.new(prompt: "Hello", output: :text)
      assert SubAgent.text_return?(agent)
    end

    test "true when signature returns :string" do
      agent =
        SubAgent.new(
          prompt: "Translate {{text}}",
          output: :text,
          signature: "(text :string) -> :string"
        )

      assert SubAgent.text_return?(agent)
    end

    test "false when signature returns complex type" do
      agent =
        SubAgent.new(
          prompt: "Classify",
          output: :text,
          signature: "() -> {sentiment :string}"
        )

      refute SubAgent.text_return?(agent)
    end

    test "false when signature returns :int" do
      agent =
        SubAgent.new(
          prompt: "Count",
          output: :text,
          signature: "() -> :int"
        )

      refute SubAgent.text_return?(agent)
    end

    test "false when signature returns list" do
      agent =
        SubAgent.new(
          prompt: "List items",
          output: :text,
          signature: "() -> [:string]"
        )

      refute SubAgent.text_return?(agent)
    end
  end
end
