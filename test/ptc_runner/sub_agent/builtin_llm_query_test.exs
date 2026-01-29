defmodule PtcRunner.SubAgent.BuiltinLlmQueryTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent
  alias PtcRunner.SubAgent.Loop.ToolNormalizer

  describe "wrap_builtin_llm_query/2" do
    test "raises when :prompt is missing" do
      state = %{
        llm: fn _ -> {:ok, ~s|{"answer": "hello"}|} end,
        llm_registry: %{},
        nesting_depth: 0,
        remaining_turns: 10,
        mission_deadline: nil,
        trace_context: nil,
        max_heap: nil
      }

      func = ToolNormalizer.wrap_builtin_llm_query("llm-query", state)

      assert_raise PtcRunner.Lisp.ExecutionError, fn ->
        func.(%{})
      end
    end

    test "executes with map signature and returns result" do
      mock_llm = fn _ -> {:ok, ~s|{"answer": "test result"}|} end

      state = %{
        llm: mock_llm,
        llm_registry: %{},
        nesting_depth: 0,
        remaining_turns: 10,
        mission_deadline: nil,
        trace_context: nil,
        max_heap: nil
      }

      func = ToolNormalizer.wrap_builtin_llm_query("llm-query", state)

      result =
        func.(%{"prompt" => "Say hello", "signature" => "{answer :string}"})

      assert result == %{"answer" => "test result"}
    end

    test "splits control keys from template args" do
      captured_prompt = :ets.new(:captured, [:set, :public])

      mock_llm = fn %{messages: messages} ->
        user_msg = Enum.find(messages, &(&1.role == :user))
        :ets.insert(captured_prompt, {:prompt, user_msg.content})
        {:ok, ~s|{"urgent": true}|}
      end

      state = %{
        llm: mock_llm,
        llm_registry: %{},
        nesting_depth: 0,
        remaining_turns: 10,
        mission_deadline: nil,
        trace_context: nil,
        max_heap: nil
      }

      func = ToolNormalizer.wrap_builtin_llm_query("llm-query", state)

      func.(%{
        "prompt" => "Is {{text}} urgent?",
        "signature" => "{urgent :bool}",
        "text" => "Help me!"
      })

      [{:prompt, captured}] = :ets.lookup(captured_prompt, :prompt)
      assert captured =~ "Is Help me! urgent?"
      :ets.delete(captured_prompt)
    end
  end

  describe "SubAgent integration with llm_query: true" do
    test "llm-query tool appears in prompt" do
      agent =
        SubAgent.new(
          prompt: "Test task",
          tools: %{"other" => fn _ -> :ok end},
          llm_query: true
        )

      preview = SubAgent.preview_prompt(agent)
      assert preview.user =~ "llm-query"
      assert preview.user =~ "Ad-hoc LLM call"
    end

    test "llm-query instructions injected in context" do
      agent =
        SubAgent.new(
          prompt: "Test task",
          llm_query: true
        )

      preview = SubAgent.preview_prompt(agent)
      assert preview.user =~ "tool/llm-query"
      assert preview.user =~ "pmap"
    end

    test "llm-query NOT injected when llm_query: false" do
      agent = SubAgent.new(prompt: "Test task")
      preview = SubAgent.preview_prompt(agent)
      refute preview.user =~ "tool/llm-query"
    end

    test "executes llm-query tool in loop" do
      mock_llm = fn %{messages: messages} ->
        first_msg = hd(messages)

        if first_msg.content =~ "Mission" do
          # Outer loop call — return PTC-Lisp using map signature
          {:ok,
           ~s|```clojure\n(return (tool/llm-query {:prompt "Say hi" :signature "{greeting :string}"}))\n```|}
        else
          # Inner llm-query call (JSON mode) — return JSON object
          {:ok, ~s|{"greeting": "hello from llm"}|}
        end
      end

      agent =
        SubAgent.new(
          prompt: "Use llm-query to get a greeting",
          llm_query: true,
          max_turns: 3
        )

      {:ok, step} = SubAgent.run(agent, llm: mock_llm)
      assert step.return == %{"greeting" => "hello from llm"}
    end
  end
end
