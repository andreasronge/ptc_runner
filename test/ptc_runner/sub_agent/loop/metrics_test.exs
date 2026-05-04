defmodule PtcRunner.SubAgent.Loop.MetricsTest do
  use ExUnit.Case, async: true

  alias PtcRunner.SubAgent.Loop.Metrics

  defp base_state(overrides \\ %{}) do
    Map.merge(
      %{
        turn: 1,
        compression_stats: nil,
        compaction_stats: nil,
        total_input_tokens: 0,
        total_output_tokens: 0,
        total_cache_creation_tokens: 0,
        total_cache_read_tokens: 0,
        llm_requests: 0,
        system_prompt_tokens: 0
      },
      overrides
    )
  end

  describe "build_final_usage/4 — compaction stats surfacing" do
    test "includes :compaction key when state.compaction_stats is set" do
      stats = %{
        enabled: true,
        triggered: true,
        strategy: "trim",
        reason: :turn_pressure,
        messages_before: 12,
        messages_after: 7,
        kept_initial_user?: true,
        kept_recent_turns: 3,
        over_budget?: false
      }

      usage = Metrics.build_final_usage(base_state(%{compaction_stats: stats}), 100, 2_048)

      assert usage.compaction == stats
    end

    test "omits :compaction key when state.compaction_stats is nil" do
      usage = Metrics.build_final_usage(base_state(), 100, 2_048)

      refute Map.has_key?(usage, :compaction)
    end

    test "compaction and compression coexist independently" do
      compression = %{enabled: true, strategy: "single_user_coalesced"}
      compaction = %{enabled: true, triggered: false, strategy: "trim"}

      state =
        base_state(%{
          compression_stats: compression,
          compaction_stats: compaction
        })

      usage = Metrics.build_final_usage(state, 100, 2_048)

      assert usage.compression == compression
      assert usage.compaction == compaction
    end
  end
end
