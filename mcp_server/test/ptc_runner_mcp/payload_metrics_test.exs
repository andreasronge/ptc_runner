defmodule PtcRunnerMcp.PayloadMetricsTest do
  @moduledoc """
  Unit tests for the pure `ptc_metrics` builder.

  This is the explicit exception to the repo's "no low-value unit
  tests" rule (see `Plans/ptc-runner-mcp-payload-reduction.md` §10):
  `PayloadMetrics` is where the §7 honesty math lives, so it gets
  focused unit coverage of every invariant.
  """
  use ExUnit.Case, async: true

  alias PtcRunnerMcp.PayloadMetrics

  defp ok_entry(bytes),
    do: %{
      "server" => "s",
      "tool" => "t",
      "status" => "ok",
      "result_bytes" => bytes,
      "oversize" => false
    }

  defp error_entry(bytes \\ nil),
    do: %{
      "server" => "s",
      "tool" => "t",
      "status" => "error",
      "reason" => "timeout",
      "result_bytes" => bytes,
      "oversize" => false
    }

  defp oversize_entry(bytes \\ nil),
    do: %{
      "server" => "s",
      "tool" => "t",
      "status" => "error",
      "reason" => "response_too_large",
      "result_bytes" => bytes,
      "oversize" => true
    }

  describe "build/4 — basic shape (§4.2)" do
    test "schema_version, token method, and baseline blocks are always present" do
      m = PayloadMetrics.build(100, 0, [ok_entry(4000)])

      assert m["schema_version"] == 1
      assert m["token_estimate_method"] == "utf8_bytes_div_4"
      assert m["baseline"]["conservative"]["name"] == "successful_upstream_results_only"
      assert m["baseline"]["optimistic"]["name"] == "no_ptc_direct_llm_workflow"
      assert m["baseline"]["optimistic"]["available"] == false
      assert is_binary(m["baseline"]["optimistic"]["note"])
      # No server_side_llm / efficiency_note without the opt.
      refute Map.has_key?(m, "server_side_llm")
      refute Map.has_key?(m, "efficiency_note")
    end

    test "ratio = round(upstream_result_bytes / final_result_bytes, 2)" do
      m = PayloadMetrics.build(812, 0, [ok_entry(48_122)])
      # 48122 / 812 = 59.2635... → 59.26
      assert m["final_result_bytes"] == 812
      assert m["upstream_result_bytes"] == 48_122
      assert m["payload_reduction_ratio"] == 59.26
      assert m["baseline"]["conservative"]["bytes"] == 48_122
      assert m["baseline"]["conservative"]["ratio"] == 59.26
    end

    test "token estimates are ceil(bytes / 4)" do
      m = PayloadMetrics.build(10, 0, [ok_entry(9)])
      assert m["estimated_final_result_tokens"] == 3
      assert m["estimated_upstream_result_tokens"] == 3
    end

    test "counts split ok / error / oversize" do
      m =
        PayloadMetrics.build(50, 0, [
          ok_entry(100),
          ok_entry(200),
          error_entry(),
          oversize_entry(),
          oversize_entry(999)
        ])

      assert m["upstream_call_count"] == 5
      assert m["upstream_ok_count"] == 2
      assert m["upstream_error_count"] == 1
      assert m["upstream_oversize_count"] == 2
      assert m["upstream_result_bytes"] == 300
      assert m["upstream_error_bytes"] == 0
      assert m["upstream_oversize_bytes"] == 999
    end
  end

  describe "honesty invariants (§7)" do
    test "ratio is null when there are no successful upstream bytes (#2, #3)" do
      m = PayloadMetrics.build(120, 0, [error_entry(), oversize_entry()])
      assert m["upstream_result_bytes"] == 0
      assert m["payload_reduction_ratio"] == nil
      assert m["baseline"]["conservative"]["ratio"] == nil
    end

    test "ratio is null when final_result_bytes is 0 — the error-envelope case (#2, #9)" do
      m = PayloadMetrics.build(0, 0, [ok_entry(48_122)])
      assert m["final_result_bytes"] == 0
      assert m["upstream_result_bytes"] == 48_122
      assert m["payload_reduction_ratio"] == nil
    end

    test "ratio is null for a pure-compute window (no upstream calls)" do
      m = PayloadMetrics.build(500, 0, [])
      assert m["upstream_call_count"] == 0
      assert m["payload_reduction_ratio"] == nil
    end

    test "failed-call bytes never inflate upstream_result_bytes (#3)" do
      m = PayloadMetrics.build(10, 0, [ok_entry(40), error_entry(1_000_000)])
      assert m["upstream_result_bytes"] == 40
      assert m["upstream_error_bytes"] == 1_000_000
      assert m["payload_reduction_ratio"] == 4.0
    end

    test "oversize-call bytes never inflate upstream_result_bytes (#3)" do
      m = PayloadMetrics.build(10, 0, [ok_entry(40), oversize_entry(1_000_000)])
      assert m["upstream_result_bytes"] == 40
      assert m["upstream_oversize_bytes"] == 1_000_000
      assert m["payload_reduction_ratio"] == 4.0
    end

    test "result_bytes: null contributes 0 to its bucket" do
      m = PayloadMetrics.build(10, 0, [ok_entry(nil), ok_entry(100)])
      assert m["upstream_result_bytes"] == 100
      assert m["upstream_ok_count"] == 2
    end

    test "prints_bytes is reported separately and never affects the ratio" do
      with_prints = PayloadMetrics.build(100, 99_999, [ok_entry(400)])
      without_prints = PayloadMetrics.build(100, 0, [ok_entry(400)])
      assert with_prints["prints_bytes"] == 99_999
      assert with_prints["payload_reduction_ratio"] == without_prints["payload_reduction_ratio"]
    end
  end

  describe "reduction_ratio/2 + estimate_tokens/1" do
    test "reduction_ratio/2 mirrors the invariant" do
      assert PayloadMetrics.reduction_ratio(0, 100) == nil
      assert PayloadMetrics.reduction_ratio(100, 0) == nil
      assert PayloadMetrics.reduction_ratio(0, 0) == nil
      assert PayloadMetrics.reduction_ratio(100, 100) == 1.0
      assert PayloadMetrics.reduction_ratio(368_000, 200) == 1840.0
    end

    test "estimate_tokens/1 is ceil-division by 4" do
      assert PayloadMetrics.estimate_tokens(0) == 0
      assert PayloadMetrics.estimate_tokens(1) == 1
      assert PayloadMetrics.estimate_tokens(4) == 1
      assert PayloadMetrics.estimate_tokens(5) == 2
      assert PayloadMetrics.estimate_tokens(800) == 200
    end
  end

  describe "server_side_llm (§4.3)" do
    test "provider_reported: true threads the real token counts" do
      m =
        PayloadMetrics.build(1200, 0, [ok_entry(90_000)],
          server_side_llm: %{
            provider_reported: true,
            planner_calls: 2,
            prompt_tokens: 8412,
            completion_tokens: 901,
            total_tokens: 9313,
            prompt_bytes: 33_648,
            completion_bytes: 3604
          }
        )

      ssl = m["server_side_llm"]
      assert ssl["provider_reported"] == true
      assert ssl["planner_calls"] == 2
      assert ssl["prompt_tokens"] == 8412
      assert ssl["completion_tokens"] == 901
      assert ssl["total_tokens"] == 9313
      assert ssl["prompt_bytes"] == 33_648
      assert ssl["completion_bytes"] == 3604
      assert ssl["estimated_prompt_tokens"] == 8412
      assert ssl["estimated_completion_tokens"] == 901
      assert ssl["estimate_method"] == "utf8_bytes_div_4"
      # The efficiency_note appears verbatim and states the ratio
      # excludes server_side_llm (§7 #7).
      assert m["efficiency_note"] =~ "answer/result-payload reduction only"
      assert m["efficiency_note"] =~ "server_side_llm"
    end

    test "provider_reported: true derives total_tokens when not supplied" do
      m =
        PayloadMetrics.build(1, 0, [],
          server_side_llm: %{
            provider_reported: true,
            prompt_tokens: 10,
            completion_tokens: 3,
            prompt_bytes: 40,
            completion_bytes: 12
          }
        )

      assert m["server_side_llm"]["total_tokens"] == 13
    end

    test "provider_reported: false → token fields null, byte estimates present" do
      m =
        PayloadMetrics.build(1200, 0, [ok_entry(90_000)],
          server_side_llm: %{
            provider_reported: false,
            planner_calls: 1,
            prompt_bytes: 33_648,
            completion_bytes: 3604
          }
        )

      ssl = m["server_side_llm"]
      assert ssl["provider_reported"] == false
      assert ssl["prompt_tokens"] == nil
      assert ssl["completion_tokens"] == nil
      assert ssl["total_tokens"] == nil
      assert ssl["prompt_bytes"] == 33_648
      assert ssl["completion_bytes"] == 3604
      assert ssl["estimated_prompt_tokens"] == 8412
      assert ssl["estimated_completion_tokens"] == 901
    end

    test "server_side_llm with all-zero bytes still produces a well-formed block" do
      m = PayloadMetrics.build(0, 0, [], server_side_llm: %{provider_reported: false})
      ssl = m["server_side_llm"]
      assert ssl["planner_calls"] == 0
      assert ssl["prompt_bytes"] == 0
      assert ssl["completion_bytes"] == 0
      assert ssl["estimated_prompt_tokens"] == 0
      assert ssl["estimated_completion_tokens"] == 0
    end
  end

  test "the whole block round-trips through Jason" do
    m =
      PayloadMetrics.build(200, 10, [ok_entry(40_000), error_entry(), oversize_entry()],
        server_side_llm: %{
          provider_reported: true,
          planner_calls: 1,
          prompt_tokens: 5,
          completion_tokens: 2,
          prompt_bytes: 20,
          completion_bytes: 8
        }
      )

    assert {:ok, json} = Jason.encode(m)
    assert {:ok, decoded} = Jason.decode(json)
    assert decoded["payload_reduction_ratio"] == 200.0
  end
end
