defmodule PtcRunner.SubAgent.CompiledAgentTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.CompiledAgent
  alias PtcRunner.SubAgent.LLMTool

  doctest CompiledAgent

  describe "compile/2" do
    # Skipped due to #454 - loop mode not detecting return call during compilation
    @tag :skip
    test "compiles and executes agent" do
      tools = %{"double" => fn %{"n" => n} -> n * 2 end}
      agent = SubAgent.new(prompt: "Test {{n}}", tools: tools)
      llm = fn _input -> {:ok, ~S|```clojure
(call "return" {:result (call "double" {:n ctx/n})})
```|} end

      {:ok, compiled} = SubAgent.compile(agent, llm: llm, sample: %{n: 5})

      assert is_binary(compiled.source)
      assert is_function(compiled.execute, 1)

      {:ok, result} = compiled.execute.(%{n: 10})
      assert result.return.result == 20
    end

    test "raises for LLMTool" do
      tools = %{"test" => LLMTool.new(prompt: "Test {{x}}", signature: "(x :string) -> :string")}
      agent = SubAgent.new(prompt: "Test", tools: tools)

      assert_raise ArgumentError, ~r/LLM-dependent/, fn ->
        SubAgent.compile(agent, llm: fn _ -> {:ok, ""} end)
      end
    end
  end

  describe "as_tool/1" do
    test "wraps compiled agent as tool" do
      compiled = %CompiledAgent{
        source: "(call \"return\" {:result 42})",
        signature: "() -> {result :int}",
        execute: fn _ -> {:ok, %PtcRunner.Step{return: %{result: 42}}} end,
        metadata: %{compiled_at: DateTime.utc_now(), tokens_used: 100, turns: 1, llm_model: nil}
      }

      tool = CompiledAgent.as_tool(compiled)

      assert tool.type == :compiled
      assert is_function(tool.execute, 1)
      assert tool.signature == "() -> {result :int}"
    end
  end
end
