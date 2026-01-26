defmodule PtcRunner.SubAgent.BudgetCallbackTest do
  @moduledoc """
  Tests for budget callback functionality in SubAgent.

  Budget callbacks allow operators to set hard limits with configurable behavior
  when those limits are exceeded.
  """

  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent

  # Helper to create a mock LLM that returns valid code
  defp make_llm(responses) when is_list(responses) do
    agent = Agent.start_link(fn -> responses end) |> elem(1)

    fn _input ->
      response = Agent.get_and_update(agent, fn [h | t] -> {h, t ++ [h]} end)

      {:ok,
       %{
         content: response,
         tokens: %{input: 1000, output: 500}
       }}
    end
  end

  defp make_llm(response) when is_binary(response) do
    fn _input ->
      {:ok,
       %{
         content: response,
         tokens: %{input: 1000, output: 500}
       }}
    end
  end

  describe "token_limit option" do
    test "loop continues when under token limit" do
      agent = SubAgent.new(prompt: "Test", max_turns: 2)

      llm =
        make_llm([
          "(+ 1 1)",
          "(return 42)"
        ])

      # High token limit should not trigger
      {:ok, step} = SubAgent.run(agent, llm: llm, token_limit: 100_000)

      assert step.return == 42
    end

    test "loop stops when token limit exceeded with on_budget_exceeded: :fail" do
      agent = SubAgent.new(prompt: "Test", max_turns: 5)

      # This LLM returns 1500 tokens per call (1000 input + 500 output)
      # After 1 call: 1500 tokens total
      llm =
        make_llm([
          "(+ 1 1)",
          "(+ 2 2)",
          "(return 42)"
        ])

      # Very low token limit - should trigger after first call
      {:error, step} = SubAgent.run(agent, llm: llm, token_limit: 1000, on_budget_exceeded: :fail)

      assert step.fail.reason == :budget_callback_exceeded
      assert step.fail.message =~ "Budget exceeded"
    end

    test "loop stops with :return_partial and uses last successful expression" do
      agent = SubAgent.new(prompt: "Test", max_turns: 5)

      llm =
        make_llm([
          # First turn returns a valid value but doesn't call (return)
          # Code must start with ( or be in a code block
          "(identity {:computed 42})",
          # Second turn - budget exceeded after this
          "(identity {:computed 100})",
          # Won't reach this
          "(return 200)"
        ])

      # Token limit will trigger after second call (each call is 1500 tokens)
      # After 2 calls: 3000 tokens total, which exceeds 2500 limit
      {:ok, step} =
        SubAgent.run(agent, llm: llm, token_limit: 2500, on_budget_exceeded: :return_partial)

      # Should return the last successful expression result from turn 1
      # (turn 2 result hasn't been recorded when budget check triggers)
      assert step.return == %{"computed" => 42}
      assert step.usage.fallback_used == true
    end

    test "returns error when :return_partial has no valid fallback" do
      # Budget exceeded on first call means no previous result to fall back to
      agent = SubAgent.new(prompt: "Test", max_turns: 3, tools: %{"noop" => fn _ -> :ok end})

      llm =
        make_llm([
          "(+ 1 1)",
          "(+ 2 2)"
        ])

      {:error, step} =
        SubAgent.run(agent,
          llm: llm,
          token_limit: 100,
          on_budget_exceeded: :return_partial
        )

      # Budget exceeded before any turn completed, so no fallback available
      assert step.fail.reason == :budget_callback_exceeded
    end
  end

  describe "budget callback function" do
    test "callback receives usage map with token counts" do
      agent = SubAgent.new(prompt: "Test", max_turns: 2)

      received_usage = Agent.start_link(fn -> nil end) |> elem(1)

      callback = fn usage ->
        Agent.update(received_usage, fn _ -> usage end)
        :continue
      end

      llm = make_llm("(return 42)")

      {:ok, _step} = SubAgent.run(agent, llm: llm, budget: callback)

      usage = Agent.get(received_usage, & &1)

      assert is_map(usage)
      assert Map.has_key?(usage, :total_tokens)
      assert Map.has_key?(usage, :input_tokens)
      assert Map.has_key?(usage, :output_tokens)
      assert Map.has_key?(usage, :llm_requests)
    end

    test "callback returning :stop terminates loop" do
      agent = SubAgent.new(prompt: "Test", max_turns: 5)

      # Stop after first call
      call_count = Agent.start_link(fn -> 0 end) |> elem(1)

      callback = fn _usage ->
        count = Agent.get_and_update(call_count, fn c -> {c, c + 1} end)
        if count >= 1, do: :stop, else: :continue
      end

      llm =
        make_llm([
          "(+ 1 1)",
          "(+ 2 2)",
          "(return 42)"
        ])

      {:error, step} = SubAgent.run(agent, llm: llm, budget: callback)

      # Should have stopped due to callback
      assert step.fail.reason == :budget_callback_exceeded
    end

    test "callback returning :continue allows loop to proceed" do
      agent = SubAgent.new(prompt: "Test", max_turns: 3)

      callback = fn _usage -> :continue end

      llm =
        make_llm([
          "(+ 1 1)",
          "(return 42)"
        ])

      {:ok, step} = SubAgent.run(agent, llm: llm, budget: callback)

      assert step.return == 42
    end

    test "callback takes precedence over token_limit" do
      agent = SubAgent.new(prompt: "Test", max_turns: 5)

      # Callback always continues, even with low token limit
      callback = fn _usage -> :continue end

      llm =
        make_llm([
          "(+ 1 1)",
          "(return 42)"
        ])

      # Would normally trigger due to low limit
      {:ok, step} = SubAgent.run(agent, llm: llm, token_limit: 100, budget: callback)

      # But callback says continue, so it succeeds
      assert step.return == 42
    end

    test "callback can use llm_requests to limit API calls" do
      agent = SubAgent.new(prompt: "Test", max_turns: 10)

      # Stop after 2 LLM requests
      callback = fn usage ->
        if usage.llm_requests >= 2, do: :stop, else: :continue
      end

      llm =
        make_llm([
          "(+ 1 1)",
          "(+ 2 2)",
          "(+ 3 3)",
          "(return 42)"
        ])

      {:error, step} = SubAgent.run(agent, llm: llm, budget: callback)

      assert step.fail.reason == :budget_callback_exceeded
      # Should have stopped after 2 requests
      assert step.usage.llm_requests == 2
    end
  end

  describe "on_budget_exceeded option" do
    test "defaults to :fail" do
      agent = SubAgent.new(prompt: "Test", max_turns: 5)

      llm =
        make_llm([
          "(+ 1 1)",
          "(+ 2 2)"
        ])

      # Should fail by default
      {:error, step} = SubAgent.run(agent, llm: llm, token_limit: 1000)

      assert step.fail.reason == :budget_callback_exceeded
    end

    test ":fail returns error step" do
      agent = SubAgent.new(prompt: "Test", max_turns: 5)

      llm =
        make_llm([
          "(+ 1 1)",
          "(+ 2 2)"
        ])

      {:error, step} = SubAgent.run(agent, llm: llm, token_limit: 1000, on_budget_exceeded: :fail)

      assert step.fail.reason == :budget_callback_exceeded
      assert step.fail.message =~ "Budget exceeded"
    end
  end
end
