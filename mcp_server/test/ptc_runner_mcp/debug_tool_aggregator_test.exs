defmodule PtcRunnerMcp.DebugToolAggregatorTest do
  @moduledoc """
  `lisp_debug` integration with aggregator mode (`upstream_calls`
  aggregation) and agentic mode (`agentic` block in `stats`).

  See `Plans/ptc-runner-mcp-debug-tool.md` § 10. `async: false`
  because the upstream registry + planner config are process-global.
  """
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.{
    AgenticConfig,
    AggregatorConfig,
    DebugBuffer,
    DebugConfig,
    JsonRpc,
    Limits,
    TraceConfig
  }

  alias PtcRunnerMcp.Upstream.Catalog
  alias PtcRunnerMcp.Upstream.Registry

  @registry_name PtcRunnerMcp.Upstream.Registry

  defmodule StubPlanner do
    @moduledoc false
    def call(_model, _prompt, _opts) do
      {:ok, ~S|(return "{\"items\":[{\"id\":1}]}")|,
       %{"model" => "stub:model", "duration_ms" => 1}}
    end
  end

  setup do
    stop_registry()
    {:ok, _pid} = Registry.start_link(name: @registry_name)
    Limits.set(Limits.defaults())
    AggregatorConfig.set(AggregatorConfig.defaults())
    AgenticConfig.set(AgenticConfig.defaults())
    TraceConfig.set(%{trace_dir: nil, trace_payloads: :summary, trace_max_files: 1000})
    original_debug = DebugConfig.get()

    on_exit(fn ->
      stop_registry()
      Limits.set(Limits.defaults())
      AggregatorConfig.set(AggregatorConfig.defaults())
      AgenticConfig.set(AgenticConfig.defaults())
      DebugConfig.set(original_debug)
      stop_buffer()
      Elixir.Application.delete_env(:ptc_runner_mcp, :agentic_planner)
    end)

    :ok
  end

  defp stop_registry do
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

  defp stop_buffer do
    case Process.whereis(DebugBuffer) do
      nil -> :ok
      pid -> if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  defp enable_debug do
    DebugConfig.set(%{enabled: true, ring_size: 500, max_response_bytes: 65_536})
    {:ok, _pid} = DebugBuffer.start_link(ring_size: 500, name: DebugBuffer)
    :ok
  end

  defp put_fake(name, tools_map) do
    tools = Map.new(tools_map, fn {n, fun} -> {n, {%{name: n, input_schema: %{}}, fun}} end)
    :ok = Registry.put_fake(name, %{tools: tools}, @registry_name)
  end

  defp call_execute(id, program) do
    frame = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => "lisp_eval", "arguments" => %{"program" => program}}
    }

    {:async_call, ^id, work_fn, _on_busy, _on_discard, _} = JsonRpc.dispatch({:ok, frame})
    work_fn.()
  end

  defp call_task(id, task) do
    frame = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => "lisp_task", "arguments" => %{"task" => task}}
    }

    {:async_call, ^id, work_fn, _on_busy, _on_discard, _} = JsonRpc.dispatch({:ok, frame})
    work_fn.()
  end

  defp call_debug(id, args) do
    frame = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => "lisp_debug", "arguments" => args}
    }

    {:reply, %{"result" => env}, _} = JsonRpc.dispatch({:ok, frame})
    env["structuredContent"]
  end

  defp flush_ring, do: DebugBuffer.count()

  # ----------------------------------------------------------------

  test "aggregator mode: upstream_calls aggregation matches the envelope decorations" do
    :ok = Catalog.freeze("test catalog")
    :ok = enable_debug()

    put_fake("alpha", %{
      "ok" => fn args, _ -> {:ok, %{"echo" => args["msg"]}} end,
      "boom" => fn _, _ -> {:error, :upstream_error, "404 not found"} end
    })

    # Two ok calls + one error call against "alpha".
    env1 =
      call_execute(1, ~S|(do
        (tool/call {:server "alpha" :tool "ok" :args {:msg "a"}})
        (tool/call {:server "alpha" :tool "ok" :args {:msg "b"}}))|)

    env2 = call_execute(2, ~S|(tool/call {:server "alpha" :tool "boom" :args {}})|)

    # Sum the per-envelope `upstream_calls` decorations as the oracle.
    decorations =
      (env1["structuredContent"]["upstream_calls"] || []) ++
        (env2["structuredContent"]["upstream_calls"] || [])

    total = length(decorations)
    ok = Enum.count(decorations, &(&1["status"] == "ok"))

    _ = flush_ring()
    s = call_debug(10, %{"op" => "stats"})

    uc = s["upstream_calls"]
    assert uc["total"] == total
    assert uc["ok"] == ok
    assert uc["by_reason"]["upstream_error"] == 1
    assert uc["by_server"]["alpha"]["total"] == total
    assert uc["by_server"]["alpha"]["ok"] == ok
    assert uc["by_server"]["alpha"]["by_reason"]["upstream_error"] == 1

    # The error envelope itself surfaced as `ok` overall (world-fault nil),
    # so the call's `status` in the ring is "ok" — only the upstream
    # entry is an error. by_tool counts the *call*, not the upstream.
    assert s["by_tool"]["lisp_eval"]["calls"] == 2

    # `get` (ring fallback, no --trace-dir) returns the FULL record:
    # `upstream_calls` is the per-call entry list, not just a count.
    g = call_debug(11, %{"op" => "get", "request_id" => "2"})
    assert g["source"] == "ring_buffer"
    assert is_list(g["record"]["upstream_calls"])
    [entry] = g["record"]["upstream_calls"]
    assert entry["server"] == "alpha"
    assert entry["tool"] == "boom"
    assert entry["status"] == "error"
    assert entry["reason"] == "upstream_error"
    # `recent` still collapses it to a count.
    r = call_debug(12, %{"op" => "recent"})
    rec2 = Enum.find(r["calls"], &(&1["request_id"] == "2"))
    assert rec2["upstream_calls"] == 1
  end

  test "agentic mode: agentic block appears in stats; lisp_debug not counted in by_tool" do
    :ok = Registry.put_fake("alpha", %{tools: %{}}, @registry_name)
    :ok = Catalog.freeze("alpha:\n  (none)")
    :ok = AgenticConfig.set(%{enabled: true, model: "stub:model"})
    Elixir.Application.put_env(:ptc_runner_mcp, :agentic_planner, StubPlanner)
    :ok = enable_debug()

    env = call_task(1, "return the items")
    assert env["isError"] == false
    assert env["structuredContent"]["status"] == "ok"

    # A plain lisp_debug call must not pollute by_tool.
    _ = call_debug(2, %{"op" => "stats"})
    _ = flush_ring()

    s = call_debug(10, %{"op" => "stats"})
    assert Map.has_key?(s["by_tool"], "lisp_task")
    refute Map.has_key?(s["by_tool"], "lisp_debug")

    a = s["agentic"]
    assert a["tasks"] == 1
    assert a["planner_calls"] == 1
    assert is_integer(a["planner_errors"])
    assert is_integer(a["planner_rejects"])
    assert is_integer(a["retries"])

    # The per-call record carries the agentic sub-map.
    {:ok, rec} = DebugBuffer.get("1")
    assert rec.tool == "lisp_task"
    assert is_map(rec.agentic)
    assert rec.agentic.planner_status in [:ok, :error]

    g = call_debug(11, %{"op" => "get", "request_id" => "1"})
    assert g["record"]["agentic"]["planner_status"] in ["ok", "error"]
  end

  test "agentic mode: multiple lisp_task calls aggregate in by_tool + agentic" do
    :ok = Registry.put_fake("alpha", %{tools: %{}}, @registry_name)
    :ok = Catalog.freeze("alpha:\n  (none)")
    :ok = AgenticConfig.set(%{enabled: true, model: "stub:model"})
    Elixir.Application.put_env(:ptc_runner_mcp, :agentic_planner, StubPlanner)
    :ok = enable_debug()

    _ = call_task(1, "first")
    _ = call_task(2, "second")
    _ = flush_ring()

    s = call_debug(10, %{"op" => "stats"})
    assert s["by_tool"]["lisp_task"]["calls"] == 2
    assert s["agentic"]["tasks"] == 2
  end

  # ----------------------------------------------------------------
  # Phase C — payload_reduction aggregate
  # (Plans/ptc-runner-mcp-payload-reduction.md §4.4 / §4.5)
  # ----------------------------------------------------------------

  test "payload_reduction stats totals/ratios match the per-call ptc_metrics" do
    :ok = Catalog.freeze("test catalog")
    :ok = enable_debug()

    big = %{"rows" => Enum.map(1..120, fn i -> %{"id" => i, "label" => "r-#{i}"} end)}
    small = %{"v" => Enum.to_list(1..20)}

    put_fake("alpha", %{
      "big" => fn _, _ -> {:ok, big} end,
      "small" => fn _, _ -> {:ok, small} end
    })

    env1 =
      call_execute(
        1,
        ~S|(count (get (tool/call {:server "alpha" :tool "big" :args {}}) "rows"))|
      )

    env2 =
      call_execute(
        2,
        ~S|(count (get (tool/call {:server "alpha" :tool "small" :args {}}) "v"))|
      )

    # A pure-compute aggregator program: 0 upstream calls → no ptc_metrics.
    env3 = call_execute(3, ~S|(+ 1 2 3)|)

    m1 = env1["structuredContent"]["ptc_metrics"]
    m2 = env2["structuredContent"]["ptc_metrics"]
    assert is_map(m1) and is_map(m2)
    assert env3["structuredContent"]["ptc_metrics"] == nil

    _ = flush_ring()
    s = call_debug(10, %{"op" => "stats"})
    pr = s["payload_reduction"]

    assert pr["schema_version"] == 1
    # Only the two calls that carried ptc_metrics count.
    assert pr["calls_with_metrics"] == 2
    assert pr["total_final_result_bytes"] == m1["final_result_bytes"] + m2["final_result_bytes"]

    assert pr["total_upstream_result_bytes"] ==
             m1["upstream_result_bytes"] + m2["upstream_result_bytes"]

    assert pr["total_upstream_calls"] == m1["upstream_call_count"] + m2["upstream_call_count"]

    # weighted = Σupstream / max(Σfinal, 1).
    assert pr["reduction_ratio"]["weighted"] ==
             Float.round(
               pr["total_upstream_result_bytes"] / max(pr["total_final_result_bytes"], 1),
               2
             )

    # top_reducers ordered by per-call ratio, highest first; the big
    # fetch reduces more than the small one.
    assert [first | _] = pr["top_reducers"]
    assert first["request_id"] == "1"
    assert first["ratio"] == m1["payload_reduction_ratio"]
    assert length(pr["top_reducers"]) == 2

    # estimated tokens are ceil(bytes/4).
    assert pr["estimated_tokens"]["final_result"] == div(pr["total_final_result_bytes"] + 3, 4)
    assert pr["estimated_tokens"]["method"] == "utf8_bytes_div_4"

    assert pr["estimated_tokens"]["upstream_result"] ==
             div(pr["total_upstream_result_bytes"] + 3, 4)

    # No lisp_task calls in this window → no agentic_planner sub-block.
    refute Map.has_key?(pr, "agentic_planner")

    # recent surfaces ptc_metrics on the per-call view; get keeps the
    # per-entry upstream_calls with result_bytes/oversize.
    r = call_debug(11, %{"op" => "recent"})
    rec1 = Enum.find(r["calls"], &(&1["request_id"] == "1"))
    assert rec1["ptc_metrics"]["payload_reduction_ratio"] == m1["payload_reduction_ratio"]
    # The pure-compute call has no ptc_metrics in its record.
    rec3 = Enum.find(r["calls"], &(&1["request_id"] == "3"))
    refute Map.has_key?(rec3, "ptc_metrics")

    g = call_debug(12, %{"op" => "get", "request_id" => "1"})
    assert g["record"]["ptc_metrics"]["upstream_result_bytes"] == m1["upstream_result_bytes"]
    [entry] = g["record"]["upstream_calls"]
    assert is_integer(entry["result_bytes"])
    assert entry["oversize"] == false
  end

  test "payload_reduction.agentic_planner appears when the window has lisp_task calls" do
    :ok = Registry.put_fake("alpha", %{tools: %{}}, @registry_name)
    :ok = Catalog.freeze("alpha:\n  (none)")
    :ok = AgenticConfig.set(%{enabled: true, model: "stub:model"})
    Elixir.Application.put_env(:ptc_runner_mcp, :agentic_planner, StubPlanner)
    :ok = enable_debug()

    env = call_task(1, "return the items")
    assert env["isError"] == false
    m = env["structuredContent"]["ptc_metrics"]
    assert is_map(m["server_side_llm"])

    _ = flush_ring()
    s = call_debug(10, %{"op" => "stats"})
    pr = s["payload_reduction"]
    ap = pr["agentic_planner"]

    assert ap["tasks"] == 1
    # StubPlanner's meta carries no provider tokens → not provider-reported.
    assert ap["provider_reported_tasks"] == 0
    assert ap["total_prompt_tokens"] == nil
    assert ap["total_completion_tokens"] == nil
    assert is_integer(ap["total_prompt_bytes"])
    assert is_integer(ap["total_completion_bytes"])

    assert ap["estimated_total_tokens"] ==
             div(ap["total_prompt_bytes"] + 3, 4) + div(ap["total_completion_bytes"] + 3, 4)
  end

  test "a :mcp_no_tools-only window has no payload_reduction block" do
    # No upstreams configured → :mcp_no_tools profile, no ptc_metrics.
    :ok = enable_debug()
    _ = call_execute(1, ~S|(+ 1 2)|)
    _ = flush_ring()

    s = call_debug(10, %{"op" => "stats"})
    refute Map.has_key?(s, "payload_reduction")
  end

  test "stats shrink drops payload_reduction.top_reducers first, then the block, before by_server" do
    :ok = Catalog.freeze("test catalog")
    # A tiny response cap forces the shrink ladder.
    DebugConfig.set(%{enabled: true, ring_size: 500, max_response_bytes: 1_400})
    {:ok, _pid} = DebugBuffer.start_link(ring_size: 500, name: DebugBuffer)

    big = %{
      "rows" => Enum.map(1..200, fn i -> %{"id" => i, "txt" => String.duplicate("q", 20)} end)
    }

    put_fake("alpha", %{"big" => fn _, _ -> {:ok, big} end})

    Enum.each(1..5, fn id ->
      _ =
        call_execute(
          id,
          ~S|(count (get (tool/call {:server "alpha" :tool "big" :args {}}) "rows"))|
        )
    end)

    _ = flush_ring()
    s = call_debug(10, %{"op" => "stats"})

    assert s["truncated"] == true
    # top_reducers is the first thing dropped; either the whole
    # payload_reduction block is gone, or it survives without
    # top_reducers — never with top_reducers while truncated.
    case s["payload_reduction"] do
      nil -> :ok
      pr when is_map(pr) -> refute Map.has_key?(pr, "top_reducers")
    end
  end
end
