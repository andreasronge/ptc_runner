defmodule PtcRunnerMcp.PayloadReductionTest do
  @moduledoc """
  Phase A + Phase B integration: `result_bytes` / `oversize` on
  `upstream_calls[]` and the `ptc_metrics` envelope decoration for
  `ptc_lisp_execute` (aggregator mode).

  See `Plans/ptc-runner-mcp-payload-reduction.md` §4.1 / §4.2 / §7.
  Reuses the fake-upstream harness from `AggregatorPhase1aTest`.
  """
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.{AggregatorConfig, Limits, Tools}
  alias PtcRunnerMcp.Upstream.Registry

  @registry_name PtcRunnerMcp.Upstream.Registry

  setup do
    stop_existing_registry()
    {:ok, _pid} = Registry.start_link(name: @registry_name)
    Limits.set(Limits.defaults())
    AggregatorConfig.set(AggregatorConfig.defaults())

    on_exit(fn ->
      stop_existing_registry()
      Limits.set(Limits.defaults())
      AggregatorConfig.set(AggregatorConfig.defaults())
    end)

    :ok
  end

  defp stop_existing_registry do
    case Process.whereis(@registry_name) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          1_000 -> :ok
        end
    end
  end

  defp tools_config(tools) do
    %{tools: Map.new(tools, fn {n, fun} -> {n, {%{name: n, input_schema: %{}}, fun}} end)}
  end

  defp put_fake(name, tools) when is_map(tools) do
    :ok = Registry.put_fake(name, tools_config(tools), @registry_name)
  end

  defp call(program), do: Tools.call_with_gate(%{"program" => program})

  defp structured(env), do: env["structuredContent"]
  defp upstream_calls(env), do: structured(env)["upstream_calls"] || []
  defp metrics(env), do: structured(env)["ptc_metrics"]

  # ============================================================
  # Phase A — result_bytes / oversize on upstream_calls[]
  # ============================================================

  describe "upstream_calls[] byte accounting (§4.1)" do
    test "a successful upstream call records result_bytes and oversize: false" do
      payload = %{"items" => Enum.to_list(1..50)}
      encoded_size = byte_size(Jason.encode!(payload))
      put_fake("alpha", %{"fetch" => fn _args, _ -> {:ok, payload} end})

      env = call(~S|(get (tool/mcp-call {:server "alpha" :tool "fetch" :args {}}) "items")|)

      assert env["isError"] == false
      [entry] = upstream_calls(env)
      assert entry["status"] == "ok"
      assert entry["result_bytes"] == encoded_size
      assert entry["oversize"] == false
    end

    test "a response_too_large call records oversize: true and result_bytes: null" do
      Limits.set(Map.put(Limits.defaults(), :max_upstream_response_bytes, 100))
      put_fake("alpha", %{"big" => fn _args, _ -> {:ok, String.duplicate("x", 5_000)} end})

      env = call(~S|(tool/mcp-call {:server "alpha" :tool "big" :args {}})|)

      [entry] = upstream_calls(env)
      assert entry["status"] == "error"
      assert entry["reason"] == "response_too_large"
      assert entry["oversize"] == true
      assert entry["result_bytes"] == nil
    end

    test "a failed upstream call records oversize: false and result_bytes: null" do
      put_fake("alpha", %{"boom" => fn _args, _ -> {:error, :upstream_error, "kaboom"} end})

      env = call(~S|(tool/mcp-call {:server "alpha" :tool "boom" :args {}})|)

      [entry] = upstream_calls(env)
      assert entry["status"] == "error"
      assert entry["oversize"] == false
      assert entry["result_bytes"] == nil
    end

    test "cap_exhausted entries carry oversize: false / result_bytes: null" do
      Limits.set(Map.put(Limits.defaults(), :max_upstream_calls_per_program, 1))
      put_fake("alpha", %{"echo" => fn args, _ -> {:ok, args} end})

      env =
        call(~S|
          (do
            (tool/mcp-call {:server "alpha" :tool "echo" :args {:n 1}})
            (tool/mcp-call {:server "alpha" :tool "echo" :args {:n 2}}))
        |)

      [_first, capped] = upstream_calls(env)
      assert capped["reason"] == "cap_exhausted"
      assert capped["oversize"] == false
      assert capped["result_bytes"] == nil
    end
  end

  # ============================================================
  # Phase B — ptc_metrics envelope decoration (§4.2)
  # ============================================================

  describe "ptc_metrics on the ptc_lisp_execute aggregator envelope (§4.2)" do
    test "a program collapsing a large upstream result has a sane ratio" do
      big = %{"rows" => Enum.map(1..200, fn i -> %{"id" => i, "label" => "row-#{i}"} end)}
      upstream_size = byte_size(Jason.encode!(big))
      put_fake("alpha", %{"all" => fn _args, _ -> {:ok, big} end})

      env = call(~S|(count (get (tool/mcp-call {:server "alpha" :tool "all" :args {}}) "rows"))|)

      assert env["isError"] == false
      m = metrics(env)
      assert m["schema_version"] == 1
      assert m["upstream_call_count"] == 1
      assert m["upstream_ok_count"] == 1
      assert m["upstream_result_bytes"] == upstream_size
      # The result is a tiny number-as-string; ratio should be large.
      assert m["final_result_bytes"] > 0
      assert is_number(m["payload_reduction_ratio"])
      assert m["payload_reduction_ratio"] > 1.0
      # No server_side_llm for ptc_lisp_execute.
      refute Map.has_key?(m, "server_side_llm")
      assert m["baseline"]["optimistic"]["available"] == false
    end

    test "the error envelope carries ptc_metrics with final_result_bytes: 0 and ratio: null" do
      big = %{"data" => String.duplicate("y", 4_000)}
      put_fake("alpha", %{"get" => fn _args, _ -> {:ok, big} end})

      # Fetch from the upstream, then deliberately raise a runtime
      # error so the envelope is an error envelope.
      env =
        call(~S|
          (do
            (tool/mcp-call {:server "alpha" :tool "get" :args {}})
            (.substring "ab" 5 9))
        |)

      assert env["isError"] == true
      assert structured(env)["status"] == "error"
      m = metrics(env)
      assert m["final_result_bytes"] == 0
      assert m["payload_reduction_ratio"] == nil
      # The bytes fetched before the failure are still reported.
      assert m["upstream_result_bytes"] == byte_size(Jason.encode!(big))
    end

    # Regression for codex review round 2 [P2]: a `(fail ...)` error
    # payload carries a `result` *preview* of the failed value; that
    # preview must NOT count as `final_result_bytes` — the contract is
    # `final_result_bytes: 0` / `payload_reduction_ratio: null` on every
    # error envelope (§7 #9), not just runtime-error ones.
    test "a (fail ...) error envelope after upstream calls still reports final_result_bytes: 0" do
      big = %{"items" => Enum.map(1..100, fn i -> %{"id" => i} end)}
      put_fake("alpha", %{"get" => fn _args, _ -> {:ok, big} end})

      env =
        call(~S|
          (do
            (tool/mcp-call {:server "alpha" :tool "get" :args {}})
            (fail {:reason :on-purpose :detail "a long-ish failure preview here"}))
        |)

      assert env["isError"] == true
      sc = structured(env)
      assert sc["status"] == "error"
      assert sc["reason"] == "fail"
      # The error payload DOES carry a `result` preview...
      assert is_binary(sc["result"])
      # ...but `ptc_metrics` ignores it: error → 0, ratio → null.
      m = metrics(env)
      assert m["final_result_bytes"] == 0
      assert m["payload_reduction_ratio"] == nil
      assert m["upstream_result_bytes"] == byte_size(Jason.encode!(big))
    end

    test "a pure-compute program with 0 upstream calls has NO ptc_metrics" do
      put_fake("alpha", %{"noop" => fn _args, _ -> {:ok, %{}} end})
      env = call(~S|(+ 1 2 3)|)

      assert env["isError"] == false
      assert upstream_calls(env) == []
      assert metrics(env) == nil
    end

    test "the decorated envelope still validates against the aggregator outputSchema" do
      big = %{"v" => Enum.to_list(1..30)}
      put_fake("alpha", %{"f" => fn _args, _ -> {:ok, big} end})
      env = call(~S|(count (get (tool/mcp-call {:server "alpha" :tool "f" :args {}}) "v"))|)

      schema = Tools.output_schema_for(:mcp_aggregator)
      sc = structured(env)
      assert is_map(sc["ptc_metrics"])
      assert match?(%{"oneOf" => _}, schema)
      # The ptc_metrics + upstream_calls keys are advertised; spot-check
      # both branches list them.
      Enum.each(schema["oneOf"], fn branch ->
        assert Map.has_key?(branch["properties"], "ptc_metrics")
        assert Map.has_key?(branch["properties"], "upstream_calls")
      end)
    end
  end
end
