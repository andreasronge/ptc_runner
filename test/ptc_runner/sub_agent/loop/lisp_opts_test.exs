defmodule PtcRunner.SubAgent.Loop.LispOptsTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent.Loop.LispOpts
  alias PtcRunner.SubAgent.Loop.State

  defp agent_fixture(overrides \\ %{}) do
    Map.merge(
      %{
        float_precision: 4,
        format_options: [],
        timeout: 1_000,
        pmap_timeout: 5_000,
        pmap_max_concurrency: 4,
        max_tool_calls: nil,
        max_turns: 6,
        max_depth: 3
      },
      overrides
    )
  end

  defp state_fixture(overrides \\ %{}) do
    base = %State{
      llm: fn _ -> {:error, :stub} end,
      context: %{},
      turn: 1,
      messages: [],
      start_time: 0,
      work_turns_remaining: 5
    }

    Map.merge(base, overrides)
  end

  describe "build/4" do
    test "emits the canonical 14 keys in stable order" do
      agent = agent_fixture()
      state = state_fixture()
      opts = LispOpts.build(agent, state, %{user: "u1"}, %{})

      assert Keyword.keys(opts) == [
               :context,
               :memory,
               :tools,
               :turn_history,
               :float_precision,
               :max_print_length,
               :timeout,
               :pmap_timeout,
               :pmap_max_concurrency,
               :budget,
               :trace_context,
               :journal,
               :tool_cache
             ]

      assert opts[:context] == %{user: "u1"}
      assert opts[:tools] == %{}
      assert opts[:float_precision] == 4
    end

    test "appends :max_heap when state.max_heap is set, omits when nil" do
      agent = agent_fixture()
      assert Keyword.get(LispOpts.build(agent, state_fixture(), %{}, %{}), :max_heap) == nil

      with_heap = state_fixture(%{max_heap: 1_000_000})
      assert LispOpts.build(agent, with_heap, %{}, %{})[:max_heap] == 1_000_000
    end

    test "appends :max_tool_calls when agent.max_tool_calls is set, omits when nil" do
      assert Keyword.get(
               LispOpts.build(agent_fixture(), state_fixture(), %{}, %{}),
               :max_tool_calls
             ) == nil

      bounded = agent_fixture(%{max_tool_calls: 3})
      assert LispOpts.build(bounded, state_fixture(), %{}, %{})[:max_tool_calls] == 3
    end

    test "passes memory and tool_cache through raw (no defaulting in shared builder)" do
      # Per the @moduledoc: per-transport defaults belong at the call site,
      # not in this builder. Pin nil pass-through so combined-mode-style
      # `|| %{}` defaults stay caller-local.
      opts = LispOpts.build(agent_fixture(), state_fixture(), %{}, %{})
      assert opts[:memory] == nil
      assert opts[:tool_cache] == nil
    end

    test "max_print_length pulled from agent.format_options" do
      agent = agent_fixture(%{format_options: [max_print_length: 80]})
      assert LispOpts.build(agent, state_fixture(), %{}, %{})[:max_print_length] == 80
    end
  end
end
