defmodule PtcRunnerMcp.DebugToolTest do
  @moduledoc """
  Integration tests for the opt-in `ptc_debug` diagnostics tool.

  Covers `Plans/ptc-runner-mcp-debug-tool.md` § 10: `stats` over a mix
  of ok / timeout / runtime-error calls; validation-error and `busy`
  rejections are recorded; `ptc_debug`'s own calls are not; `recent`
  ordering / filters; `get` ring vs trace-file source + glob
  miss/collision fallback; ring eviction; the disabled-server case;
  redaction at `--trace-payloads none`; aggregator-mode `upstream_calls`
  aggregation; `record/1` fault isolation.
  """
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.{
    ConcurrencyGate,
    DebugBuffer,
    DebugConfig,
    JsonRpc,
    Limits,
    TraceConfig,
    TraceHandler
  }

  alias PtcRunnerMcp.Test.JsonRpcHarness

  setup do
    original_debug = DebugConfig.get()
    original_trace = TraceConfig.get()
    original_limits = Limits.get()
    Limits.set(Limits.defaults())
    ConcurrencyGate.reset()

    on_exit(fn ->
      DebugConfig.set(original_debug)
      TraceConfig.set(original_trace)
      Limits.set(original_limits)
      TraceHandler.detach()
      stop_buffer()
      ConcurrencyGate.reset()
    end)

    :ok
  end

  # ----------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------

  defp enable_debug(opts \\ []) do
    ring_size = Keyword.get(opts, :ring_size, 500)
    max_bytes = Keyword.get(opts, :max_response_bytes, 65_536)
    DebugConfig.set(%{enabled: true, ring_size: ring_size, max_response_bytes: max_bytes})
    {:ok, _pid} = DebugBuffer.start_link(ring_size: ring_size, name: DebugBuffer)
    :ok
  end

  defp disable_debug do
    DebugConfig.set(%{enabled: false, ring_size: 500, max_response_bytes: 65_536})
  end

  defp stop_buffer do
    case Process.whereis(DebugBuffer) do
      nil -> :ok
      pid -> if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  # Dispatch `tools/call ptc_lisp_execute/ptc_task` via JsonRpc, running
  # the per-call work_fn inline (which also records into the ring).
  defp call_tool(id, name, args) do
    frame = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => args}
    }

    case JsonRpc.dispatch({:ok, frame}) do
      {:async_call, ^id, work_fn, _on_busy, _} -> work_fn.()
      {:reply, %{"result" => env}, _} -> env
    end
  end

  defp call_execute(id, args), do: call_tool(id, "ptc_lisp_execute", args)

  # Dispatch `tools/call ptc_debug` via JsonRpc (synchronous path).
  defp call_debug(id, args) do
    frame = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => "ptc_debug", "arguments" => args}
    }

    {:reply, %{"result" => env}, _} = JsonRpc.dispatch({:ok, frame})
    env
  end

  defp sc(env), do: env["structuredContent"]

  defp flush_ring, do: DebugBuffer.count()

  # ----------------------------------------------------------------
  # stats over a mix of ok / timeout / runtime-error calls
  # ----------------------------------------------------------------

  test "stats reflects a mix of ok / timeout / runtime-error calls" do
    Limits.set(Map.put(Limits.defaults(), :program_timeout_ms, 50))
    :ok = enable_debug()

    assert sc(call_execute(1, %{"program" => "(+ 1 2)"}))["status"] == "ok"
    assert sc(call_execute(2, %{"program" => "(+ 3 4)"}))["status"] == "ok"
    assert sc(call_execute(3, %{"program" => slow_program()}))["reason"] == "timeout"
    assert sc(call_execute(4, %{"program" => "(this-undefined-symbol)"}))["status"] == "error"
    _ = flush_ring()

    s = sc(call_debug(10, %{"op" => "stats"}))
    assert s["op"] == "stats"
    assert s["payload_policy"] == "summary"
    assert s["redaction_applied"] == true
    assert s["debug_source"] == "ring_buffer"
    assert s["ring_size"] == 500
    assert s["ring_count"] == 4
    assert s["window"]["calls"] == 4
    assert is_binary(s["window"]["from"])
    assert is_binary(s["window"]["to"])

    le = s["by_tool"]["ptc_lisp_execute"]
    assert le["calls"] == 4
    assert le["ok"] == 2
    assert le["error"] == 2
    assert_in_delta le["error_rate"], 0.5, 0.001
    assert is_integer(le["duration_ms"]["max"])

    assert s["errors"]["by_reason"]["timeout"] == 1
    # the undefined-symbol call is a runtime_error
    assert Map.has_key?(s["errors"]["by_reason"], "runtime_error")
  end

  # ----------------------------------------------------------------
  # validation-error (args_error) and busy are recorded
  # ----------------------------------------------------------------

  test "args_error (malformed signature) is recorded and shows in stats + recent" do
    :ok = enable_debug()

    env = call_execute(1, %{"program" => "(+ 1 2)", "signature" => "() -> {{{bad"})
    assert env["isError"] == true
    assert sc(env)["reason"] == "args_error"
    _ = flush_ring()

    s = sc(call_debug(10, %{"op" => "stats"}))
    assert s["errors"]["by_reason"]["args_error"] == 1

    r = sc(call_debug(11, %{"op" => "recent"}))
    assert r["count"] == 1
    [call] = r["calls"]
    assert call["request_id"] == "1"
    assert call["status"] == "error"
    assert call["reason"] == "args_error"
    assert call["result_bytes"] == nil
  end

  test "args_error: a rejected, oversized program/context is NOT stored in the ring" do
    # `--trace-payloads full` would otherwise store the raw program/context
    # verbatim — but a rejected request never passed the tool limits, so it
    # must not be allowed to fill the count-bounded ring.
    TraceConfig.set(%{trace_dir: nil, trace_payloads: :full, trace_max_files: 1000})
    :ok = enable_debug()

    huge_ctx = %{"blob" => String.duplicate("y", 100_000)}
    # `program` is not a string → fails validation → args_error, no execution.
    env = call_execute(1, %{"program" => 12_345, "context" => huge_ctx})
    assert env["isError"] == true
    assert sc(env)["reason"] == "args_error"
    _ = flush_ring()

    recent_reply = call_debug(10, %{"op" => "recent"})
    r = sc(recent_reply)
    assert r["count"] == 1
    [call] = r["calls"]
    assert call["reason"] == "args_error"
    assert call["program"] == nil
    assert call["context"] == nil
    # The 100 KB blob never made it anywhere near the response.
    assert byte_size(Jason.encode!(recent_reply)) < 2_000
  end

  test "busy rejection is recorded and shows in stats.errors.by_reason and recent" do
    :ok = enable_debug()
    Limits.set(Map.put(Limits.defaults(), :max_concurrent_calls, 1))
    ConcurrencyGate.reset()

    {:ok, h} = JsonRpcHarness.start()
    on_exit(fn -> JsonRpcHarness.stop(h) end)
    _ = JsonRpcHarness.drain_replied_messages()

    long =
      "((fn ack [m n] (cond (= m 0) (+ n 1) (= n 0) (ack (- m 1) 1) :else (ack (- m 1) (ack m (- n 1))))) 3 8)"

    :ok =
      PtcRunnerMcp.Stdio.feed(
        h.stdio,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 200,
          "method" => "tools/call",
          "params" => %{"name" => "ptc_lisp_execute", "arguments" => %{"program" => long}}
        }) <> "\n"
      )

    wait_until(fn -> PtcRunnerMcp.Stdio.in_flight_count(h.stdio) == 1 end, 1_000)

    :ok =
      PtcRunnerMcp.Stdio.feed(
        h.stdio,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 201,
          "method" => "tools/call",
          "params" => %{"name" => "ptc_lisp_execute", "arguments" => %{"program" => "(+ 1 2)"}}
        }) <> "\n"
      )

    # Let the busy reply + record cast settle.
    wait_until(fn -> DebugBuffer.get("201") != :not_found end, 1_000)

    # Cancel the long one to clean up.
    :ok =
      PtcRunnerMcp.Stdio.feed(
        h.stdio,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "method" => "notifications/cancelled",
          "params" => %{"requestId" => 200}
        }) <> "\n"
      )

    wait_until(fn -> PtcRunnerMcp.Stdio.in_flight_count(h.stdio) == 0 end, 2_000)
    _ = flush_ring()

    s = sc(call_debug(10, %{"op" => "stats"}))
    assert s["errors"]["by_reason"]["busy"] == 1

    {:ok, busy_rec} = DebugBuffer.get("201")
    assert busy_rec.reason == "busy"
    assert busy_rec.status == :error
    assert busy_rec.agentic == nil
  end

  test "ptc_debug's own calls are NOT recorded" do
    :ok = enable_debug()

    _ = call_execute(1, %{"program" => "(+ 1 2)"})
    _ = call_debug(2, %{"op" => "stats"})
    _ = call_debug(3, %{"op" => "recent"})
    _ = flush_ring()

    s = sc(call_debug(10, %{"op" => "stats"}))
    assert s["ring_count"] == 1
    assert Map.keys(s["by_tool"]) == ["ptc_lisp_execute"]
    refute Map.has_key?(s["by_tool"], "ptc_debug")

    r = sc(call_debug(11, %{"op" => "recent", "limit" => 50}))
    request_ids = Enum.map(r["calls"], & &1["request_id"])
    assert request_ids == ["1"]
  end

  test "unknown-tool requests (disabled ptc_task) are NOT recorded" do
    :ok = enable_debug()

    # Without aggregator + --agentic, `ptc_task` is not advertised: a
    # `tools/call ptc_task` returns `unknown_tool` and must not enter
    # the ring (§ 5.1: unknown-tool requests are not recorded).
    env = call_tool(1, "ptc_task", %{"task" => "do stuff"})
    assert env["isError"] == true
    assert sc(env)["reason"] == "unknown_tool"

    _ = call_execute(2, %{"program" => "(+ 1 2)"})
    _ = flush_ring()

    s = sc(call_debug(10, %{"op" => "stats"}))
    assert s["ring_count"] == 1
    refute Map.has_key?(s["by_tool"], "ptc_task")
    assert DebugBuffer.get("1") == :not_found
  end

  # ----------------------------------------------------------------
  # recent ordering / filters
  # ----------------------------------------------------------------

  test "recent: newest-first, errors_only, limit" do
    Limits.set(Map.put(Limits.defaults(), :program_timeout_ms, 50))
    :ok = enable_debug()

    _ = call_execute(1, %{"program" => "(+ 1 2)"})
    _ = call_execute(2, %{"program" => "(this-undefined-symbol)"})
    _ = call_execute(3, %{"program" => "(+ 5 6)"})
    _ = flush_ring()

    r = sc(call_debug(10, %{"op" => "recent"}))
    assert Enum.map(r["calls"], & &1["request_id"]) == ["3", "2", "1"]

    only_err = sc(call_debug(11, %{"op" => "recent", "errors_only" => true}))
    assert Enum.map(only_err["calls"], & &1["request_id"]) == ["2"]
    assert hd(only_err["calls"])["status"] == "error"

    limited = sc(call_debug(12, %{"op" => "recent", "limit" => 1}))
    assert length(limited["calls"]) == 1
    assert hd(limited["calls"])["request_id"] == "3"
  end

  # ----------------------------------------------------------------
  # get: ring source, trace_file source, glob miss/collision, not found
  # ----------------------------------------------------------------

  test "get: ring_buffer source without --trace-dir; found=false for unknown" do
    :ok = enable_debug()
    _ = call_execute(7, %{"program" => "(+ 1 2)"})
    _ = flush_ring()

    g = sc(call_debug(10, %{"op" => "get", "request_id" => "7"}))
    assert g["found"] == true
    assert g["source"] == "ring_buffer"
    assert g["record"]["request_id"] == "7"

    miss = sc(call_debug(11, %{"op" => "get", "request_id" => "nope"}))
    assert miss["found"] == false
    assert miss["source"] == "ring_buffer"
  end

  test "get: trace_file source when --trace-dir set; glob miss falls back to ring" do
    dir = Path.join(System.tmp_dir!(), "ptc_dbg_trace_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    TraceConfig.set(%{trace_dir: dir, trace_payloads: :full, trace_max_files: 1000})
    :ok = TraceHandler.attach()
    :ok = enable_debug()

    _ = call_execute("trace-me", %{"program" => "(+ 1 2)"})
    _ = flush_ring()

    g = sc(call_debug(10, %{"op" => "get", "request_id" => "trace-me"}))
    assert g["found"] == true
    assert g["source"] == "trace_file"
    assert is_list(g["record"])
    assert g["record"] != []

    # An id with a ring record but no matching trace file → ring fallback.
    # (Stop the trace handler so the next call leaves no file, but the
    # ring still records it.)
    TraceConfig.set(%{trace_dir: dir, trace_payloads: :full, trace_max_files: 1000})
    _ = call_execute("no-file-here", %{"program" => "(+ 9 9)"})
    # Manually remove any file that may have been written for it.
    hash8 = PtcRunnerMcp.TraceFile.request_id_hash8("no-file-here")
    Enum.each(Path.wildcard(Path.join(dir, "*-#{hash8}-*.jsonl")), &File.rm/1)
    _ = flush_ring()

    fb = sc(call_debug(11, %{"op" => "get", "request_id" => "no-file-here"}))
    assert fb["found"] == true
    assert fb["source"] == "ring_buffer"
  end

  test "get: same-hash collision picks newest by mtime" do
    dir = Path.join(System.tmp_dir!(), "ptc_dbg_collision_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    TraceConfig.set(%{trace_dir: dir, trace_payloads: :full, trace_max_files: 1000})
    :ok = enable_debug()

    hash8 = PtcRunnerMcp.TraceFile.request_id_hash8("colliding")
    older = Path.join(dir, "2026-05-11T00-00-00.000Z-#{hash8}-ok.jsonl")
    newer = Path.join(dir, "2026-05-11T00-00-01.000Z-#{hash8}-error.jsonl")
    File.write!(older, Jason.encode!(%{"which" => "older"}) <> "\n")
    File.write!(newer, Jason.encode!(%{"which" => "newer"}) <> "\n")
    # Force mtimes so "newer" is genuinely newer.
    now = System.os_time(:second)
    File.touch!(older, now - 10)
    File.touch!(newer, now)

    # Also seed a ring record so we can confirm trace_file wins.
    DebugBuffer.record(%{
      request_id: "colliding",
      ts: DateTime.utc_now(),
      tool: "ptc_lisp_execute",
      status: :ok,
      is_error: false,
      reason: nil,
      duration_ms: 1,
      program: nil,
      context: nil,
      result_bytes: nil,
      prints_count: nil,
      signature_present?: false,
      protocol_version: "x",
      upstream_calls: [],
      agentic: nil
    })

    _ = flush_ring()

    g = sc(call_debug(10, %{"op" => "get", "request_id" => "colliding"}))
    assert g["source"] == "trace_file"
    assert g["record"] == [%{"which" => "newer"}]
  end

  test "get: a trace file larger than --max-debug-response-bytes is not read; returns a pointer" do
    dir = Path.join(System.tmp_dir!(), "ptc_dbg_big_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    TraceConfig.set(%{trace_dir: dir, trace_payloads: :full, trace_max_files: 1000})
    :ok = enable_debug(max_response_bytes: 4_096)

    hash8 = PtcRunnerMcp.TraceFile.request_id_hash8("huge-trace")
    big = Path.join(dir, "2026-05-11T00-00-00.000Z-#{hash8}-ok.jsonl")
    File.write!(big, String.duplicate("x", 50_000) <> "\n")

    env = call_debug(10, %{"op" => "get", "request_id" => "huge-trace"})
    g = sc(env)
    assert g["found"] == true
    assert g["source"] == "trace_file"
    assert g["truncated"] == true
    refute Map.has_key?(g, "record")
    assert g["note"] =~ "exceeds --max-debug-response-bytes"
    # The whole JSON-RPC result must stay under the configured cap.
    assert byte_size(Jason.encode!(env)) < 4_096
  end

  test "get: a --trace-dir containing glob metacharacters still resolves trace files" do
    dir = Path.join(System.tmp_dir!(), "ptc_dbg[meta]?_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    TraceConfig.set(%{trace_dir: dir, trace_payloads: :full, trace_max_files: 1000})
    :ok = enable_debug()

    hash8 = PtcRunnerMcp.TraceFile.request_id_hash8("meta-id")

    File.write!(
      Path.join(dir, "2026-05-11T00-00-00.000Z-#{hash8}-ok.jsonl"),
      Jason.encode!(%{"ok" => true}) <> "\n"
    )

    g = sc(call_debug(10, %{"op" => "get", "request_id" => "meta-id"}))
    assert g["found"] == true
    assert g["source"] == "trace_file"
    assert g["record"] == [%{"ok" => true}]
  end

  test "get: a trace from an earlier run is NOT inlined under a stricter --trace-payloads" do
    dir = Path.join(System.tmp_dir!(), "ptc_dbg_stale_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    # Simulate a trace written by an earlier run at `--trace-payloads full`,
    # carrying data a `none` server would never emit.
    secret = "PRIOR_RUN_SECRET_xyz789"
    hash8 = PtcRunnerMcp.TraceFile.request_id_hash8("stale-id")

    File.write!(
      Path.join(dir, "2026-05-11T00-00-00.000Z-#{hash8}-ok.jsonl"),
      Jason.encode!(%{"program" => "(do #{secret})", "context" => %{"token" => secret}}) <> "\n"
    )

    # This run is at the strictest policy.
    TraceConfig.set(%{trace_dir: dir, trace_payloads: :none, trace_max_files: 1000})
    :ok = enable_debug()

    env = call_debug(10, %{"op" => "get", "request_id" => "stale-id"})
    g = sc(env)
    assert g["found"] == true
    assert g["source"] == "trace_file"
    refute Map.has_key?(g, "record")
    assert g["note"] =~ "not inlined"
    # The prior-run payload is never read, so it cannot leak through ptc_debug.
    refute Jason.encode!(env) =~ secret
  end

  test "the response cap accounts for the JSON-RPC frame (large request id)" do
    :ok = enable_debug(max_response_bytes: 8_192)

    # Enough recorded calls (with chunky program previews) that an uncapped
    # `recent` would blow well past the 8 KiB cap.
    Enum.each(1..40, fn i ->
      call_execute(i, %{"program" => "(str " <> String.duplicate("\"x\" ", 60) <> ")"})
    end)

    _ = flush_ring()

    big_id = String.duplicate("z", 1_000)

    frame = %{
      "jsonrpc" => "2.0",
      "id" => big_id,
      "method" => "tools/call",
      "params" => %{"name" => "ptc_debug", "arguments" => %{"op" => "recent", "limit" => 200}}
    }

    {:reply, reply, _} = JsonRpc.dispatch({:ok, frame})

    # The whole serialized JSON-RPC reply — id included — stays within the cap,
    # and the payload was shrunk to make room for the id.
    assert byte_size(Jason.encode!(reply)) <= 8_192
    assert sc(reply["result"])["truncated"] == true
  end

  # ----------------------------------------------------------------
  # ring eviction + clamping
  # ----------------------------------------------------------------

  test "ring eviction with small --debug-ring-size; ring_count never exceeds size" do
    :ok = enable_debug(ring_size: 3)

    Enum.each(1..5, fn i -> call_execute(i, %{"program" => "(+ #{i} 0)"}) end)
    _ = flush_ring()

    s = sc(call_debug(10, %{"op" => "stats"}))
    assert s["ring_size"] == 3
    assert s["ring_count"] == 3

    r = sc(call_debug(11, %{"op" => "recent", "limit" => 10}))
    assert Enum.map(r["calls"], & &1["request_id"]) == ["5", "4", "3"]

    miss = sc(call_debug(12, %{"op" => "get", "request_id" => "1"}))
    assert miss["found"] == false
  end

  test "ring-size clamping (low) yields ring_size 10" do
    DebugConfig.set(%{enabled: true, ring_size: 1, max_response_bytes: 65_536})
    {clamped, true} = DebugConfig.clamp_ring_size(1)
    assert clamped == 10
    {:ok, _pid} = DebugBuffer.start_link(ring_size: clamped, name: DebugBuffer)

    _ = call_execute(1, %{"program" => "(+ 1 2)"})
    _ = flush_ring()
    s = sc(call_debug(10, %{"op" => "stats"}))
    assert s["ring_size"] == 10
  end

  # ----------------------------------------------------------------
  # disabled server
  # ----------------------------------------------------------------

  test "without --debug-tool: ptc_debug absent from tools/list, unknown_tool on call, no DebugBuffer" do
    disable_debug()

    list = PtcRunnerMcp.Tools.list()
    names = Enum.map(list["tools"], & &1["name"])
    refute "ptc_debug" in names

    env = call_debug(1, %{"op" => "stats"})
    assert env["isError"] == true
    assert sc(env)["reason"] == "unknown_tool"

    assert Process.whereis(DebugBuffer) == nil
  end

  test "with --debug-tool: ptc_debug present in tools/list with read-only annotations" do
    :ok = enable_debug()
    list = PtcRunnerMcp.Tools.list()
    entry = Enum.find(list["tools"], &(&1["name"] == "ptc_debug"))
    assert entry

    assert entry["annotations"] == %{
             "readOnlyHint" => true,
             "destructiveHint" => false,
             "idempotentHint" => true,
             "openWorldHint" => false
           }

    assert entry["inputSchema"]["required"] == ["op"]
    assert entry["inputSchema"]["additionalProperties"] == false
    # `ptc_debug` is listed after `ptc_lisp_execute`.
    assert List.last(Enum.map(list["tools"], & &1["name"])) == "ptc_debug"

    # outputSchema must also cover the standard `args_error` payload so strict
    # clients validating `structuredContent` don't reject the server's own
    # validation-error replies.
    branches = entry["outputSchema"]["oneOf"]
    assert is_list(branches) and length(branches) == 4

    err = Enum.find(branches, &(get_in(&1, ["properties", "status", "const"]) == "error"))
    assert err
    assert "args_error" in err["properties"]["reason"]["enum"]

    # And the actual envelope a failed `ptc_debug` call returns matches it.
    bad = sc(call_debug(99, %{}))
    assert bad["status"] == "error"
    assert bad["reason"] == "args_error"
    assert Map.has_key?(bad, "message")
    assert Map.has_key?(bad, "feedback")
  end

  # ----------------------------------------------------------------
  # validation
  # ----------------------------------------------------------------

  test "ptc_debug arg validation: unknown op, missing request_id, bad types → args_error" do
    :ok = enable_debug()

    bad_op = call_debug(1, %{"op" => "nope"})
    assert sc(bad_op)["reason"] == "args_error"

    missing_op = call_debug(2, %{})
    assert sc(missing_op)["reason"] == "args_error"

    missing_id = call_debug(3, %{"op" => "get"})
    assert sc(missing_id)["reason"] == "args_error"

    bad_limit = call_debug(4, %{"op" => "recent", "limit" => "ten"})
    assert sc(bad_limit)["reason"] == "args_error"

    out_of_range = call_debug(5, %{"op" => "recent", "limit" => 9999})
    assert sc(out_of_range)["reason"] == "args_error"
  end

  test "validation errors are bounded — a huge `op` cannot exceed --max-debug-response-bytes" do
    :ok = enable_debug(max_response_bytes: 4_096)

    huge = String.duplicate("x", 200_000)
    env = call_debug(1, %{"op" => huge})
    assert sc(env)["reason"] == "args_error"
    # The args_error text echoes the offending value, but it is bounded
    # (`show/1`), so the whole JSON-RPC result stays well under the cap.
    assert byte_size(Jason.encode!(env)) < 4_096
  end

  # ----------------------------------------------------------------
  # redaction at --trace-payloads none
  # ----------------------------------------------------------------

  test "redaction: at --trace-payloads none, program is byte counts only; planted secret absent" do
    TraceConfig.set(%{trace_dir: nil, trace_payloads: :none, trace_max_files: 1000})
    :ok = enable_debug()

    secret = "SUPER_SECRET_TOKEN_abcdef123456"
    program = "(get data/blob :x)"
    _ = call_execute(1, %{"program" => program, "context" => %{"blob" => %{"x" => secret}}})
    _ = flush_ring()

    r = sc(call_debug(10, %{"op" => "recent"}))
    assert r["payload_policy"] == "none"
    [call] = r["calls"]
    # `:none` program redaction → sha256 + bytes only, no preview/source.
    assert call["program"]["bytes"] == byte_size(program)
    assert Map.has_key?(call["program"], "sha256")
    refute Map.has_key?(call["program"], "preview")

    g = sc(call_debug(11, %{"op" => "get", "request_id" => "1"}))
    # The secret must not appear anywhere in any ptc_debug output.
    refute String.contains?(Jason.encode!(r), secret)
    refute String.contains?(Jason.encode!(g), secret)
  end

  # ----------------------------------------------------------------
  # record/1 fault isolation
  # ----------------------------------------------------------------

  test "record/1 fault isolation: a killed DebugBuffer does not break a concurrent tools/call" do
    :ok = enable_debug()
    _ = call_execute(1, %{"program" => "(+ 1 2)"})

    pid = Process.whereis(DebugBuffer)
    # `start_link` linked the buffer to this test process — unlink
    # before killing so the `:kill` doesn't take the test down.
    Process.unlink(pid)
    Process.exit(pid, :kill)
    wait_until(fn -> Process.whereis(DebugBuffer) == nil end, 1_000)

    # A subsequent tools/call must still succeed even though the ring
    # recorder's cast goes nowhere.
    env = call_execute(2, %{"program" => "(+ 10 20)"})
    assert env["isError"] == false
    assert sc(env)["result"] == "user=> 30"
  end

  # ----------------------------------------------------------------
  # size cap
  # ----------------------------------------------------------------

  test "size cap: small --max-debug-response-bytes truncates recent; wire response stays under cap" do
    cap = 1_500
    :ok = enable_debug(max_response_bytes: cap)

    Enum.each(1..20, fn i -> call_execute(i, %{"program" => "(+ #{i} 0)"}) end)
    _ = flush_ring()

    env = call_debug(10, %{"op" => "recent", "limit" => 200})
    r = sc(env)
    assert r["truncated"] == true
    # Fewer than all 20 records survive.
    assert length(r["calls"]) < 20
    # The full wire envelope (structuredContent duplicated into content[]
    # plus JSON-RPC wrapper) must stay under the configured cap.
    assert byte_size(Jason.encode!(env)) <= cap
  end

  # ----------------------------------------------------------------
  # helper
  # ----------------------------------------------------------------

  # CPU-bound program that reliably exceeds a small `--program-timeout-ms`.
  defp slow_program do
    "((fn ack [m n] " <>
      "(cond (= m 0) (+ n 1) " <>
      "(= n 0) (ack (- m 1) 1) " <>
      ":else (ack (- m 1) (ack m (- n 1))))) 3 9)"
  end

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("wait_until timed out")

      true ->
        receive do
        after
          10 -> :ok
        end

        do_wait(fun, deadline)
    end
  end
end
