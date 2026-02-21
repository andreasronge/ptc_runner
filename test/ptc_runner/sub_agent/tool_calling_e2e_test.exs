defmodule PtcRunner.SubAgent.ToolCallingE2ETest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent

  @moduletag :e2e

  defp get_llm do
    LLMClient.callback("haiku")
  end

  describe "tool calling e2e" do
    test "simple tool call scenario with real LLM" do
      tools = %{
        "add" =>
          {fn args -> args["a"] + args["b"] end,
           signature: "(a :int, b :int) -> :int", description: "Add two numbers together"}
      }

      agent =
        SubAgent.new(
          prompt: "What is 17 + 25? Use the add tool to compute the answer.",
          signature: "() -> {result :int}",
          output: :tool_calling,
          tools: tools,
          max_turns: 5
        )

      {:ok, step} = SubAgent.run(agent, llm: get_llm())

      assert step.return["result"] == 42
    end

    test "multi-tool scenario with real LLM" do
      tools = %{
        "multiply" =>
          {fn args -> args["a"] * args["b"] end,
           signature: "(a :int, b :int) -> :int", description: "Multiply two numbers"},
        "subtract" =>
          {fn args -> args["a"] - args["b"] end,
           signature: "(a :int, b :int) -> :int", description: "Subtract b from a"}
      }

      agent =
        SubAgent.new(
          prompt:
            "Calculate (6 * 7) - 10. First multiply 6 and 7, then subtract 10 from the result.",
          signature: "() -> {result :int}",
          output: :tool_calling,
          tools: tools,
          max_turns: 5
        )

      {:ok, step} = SubAgent.run(agent, llm: get_llm())

      assert step.return["result"] == 32
    end
  end
end
