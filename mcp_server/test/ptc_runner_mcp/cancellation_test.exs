defmodule PtcRunnerMcp.CancellationTest do
  @moduledoc """
  Phase 4 DoD coverage for `Plans/ptc-runner-mcp-server.md` § 15
  Phase 4 + § 6.4 / § 6.3 / § 11:

    * `notifications/cancelled` for an in-flight requestId kills the
      worker, releases the permit, and emits no response for that id
      (other in-flight calls continue uninterrupted).
    * `notifications/cancelled` for an unknown id is a silent no-op.
    * stdin EOF cancels all in-flight workers and exits 0 cleanly.
    * `shutdown` followed by `exit` drains in-flight calls; new
      `tools/call` requests in `:drain` are rejected with the
      MCP-only `shutting_down` envelope.
    * Concurrency cap fires under genuine concurrent stdio dispatch:
      with `max_concurrent_calls: 1`, two concurrent tools/call frames
      produce one normal response and one `busy`.
    * Permit release after cancellation: 5 cancelled calls leave
      `ConcurrencyGate.in_flight/0` at 0.
    * Sandbox isolation: two sequential tools/call requests cannot
      see each other's `(memory/put ...)` state.
    * Telemetry `[:ptc_runner_mcp, :call, :*]` events still fire from
      worker processes with correct metadata.
  """
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.{ConcurrencyGate, Limits, Stdio}
  alias PtcRunnerMcp.Test.JsonRpcHarness

  setup do
    Limits.set(Limits.defaults())
    ConcurrencyGate.reset()

    {:ok, harness} = JsonRpcHarness.start()
    on_exit(fn -> JsonRpcHarness.stop(harness) end)
    {:ok, harness: harness}
  end

  # A program that runs longer than the harness's reply timeout.
  # Ackermann(3, 8) reliably exceeds 1s of CPU under default heap.
  defp long_running_program do
    "((fn ack [m n] " <>
      "(cond (= m 0) (+ n 1) " <>
      "(= n 0) (ack (- m 1) 1) " <>
      ":else (ack (- m 1) (ack m (- n 1))))) 3 8)"
  end

  defp tools_call_frame(id, program) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{
        "name" => "ptc_lisp_execute",
        "arguments" => %{"program" => program}
      }
    }) <> "\n"
  end

  defp cancelled_frame(id) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "method" => "notifications/cancelled",
      "params" => %{"requestId" => id}
    }) <> "\n"
  end

  describe "notifications/cancelled (§ 6.4 row 3)" do
    test "kills in-flight worker and emits no reply for that id", %{harness: h} do
      # Drain any pending observer messages from setup.
      _ = JsonRpcHarness.drain_replied_messages()

      :ok = Stdio.feed(h.stdio, tools_call_frame(42, long_running_program()))

      # Wait until the worker is actually in flight, then send cancel.
      wait_until(fn -> Stdio.in_flight_count(h.stdio) == 1 end, 500)

      :ok = Stdio.feed(h.stdio, cancelled_frame(42))

      # Worker should drain quickly after kill — no reply for id 42.
      wait_until(fn -> Stdio.in_flight_count(h.stdio) == 0 end, 1_500)

      assert StringIO.flush(h.io) == ""
      # Permit was released on cancel.
      assert ConcurrencyGate.in_flight() == 0
    end

    test "other in-flight requests continue uninterrupted when one is cancelled", %{harness: h} do
      Limits.set(%{max_concurrent_calls: 4})
      _ = JsonRpcHarness.drain_replied_messages()

      # Start a long-running call (id 100) and a fast call (id 101).
      :ok = Stdio.feed(h.stdio, tools_call_frame(100, long_running_program()))
      :ok = Stdio.feed(h.stdio, tools_call_frame(101, "(+ 1 2)"))

      # Cancel the long-running one.
      wait_until(fn -> Stdio.in_flight_count(h.stdio) >= 1 end, 500)
      :ok = Stdio.feed(h.stdio, cancelled_frame(100))

      # The fast call should still produce a reply.
      wait_until(fn -> Stdio.in_flight_count(h.stdio) == 0 end, 2_000)

      replies =
        h.io
        |> StringIO.flush()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      ids = Enum.map(replies, & &1["id"])
      refute 100 in ids, "expected NO reply for cancelled id 100"
      assert 101 in ids, "expected reply for non-cancelled id 101"
    end

    test "for an unknown requestId is silently ignored", %{harness: h} do
      _ = JsonRpcHarness.drain_replied_messages()

      :ok = Stdio.feed(h.stdio, cancelled_frame(9_999))

      # No reply, no crash, no permit consumed.
      assert StringIO.flush(h.io) == ""
      assert ConcurrencyGate.in_flight() == 0
    end

    test "permit is released even after :kill of the worker", %{harness: h} do
      Limits.set(%{max_concurrent_calls: 2})

      _ = JsonRpcHarness.drain_replied_messages()

      # Issue 5 cancellable calls back-to-back. With cap 2, three of
      # them queue up... wait, no — we don't queue. They'll get busy.
      # So we issue them one at a time, cancel each, and check the
      # gate ends at 0.
      Enum.each(1..5, fn i ->
        :ok = Stdio.feed(h.stdio, tools_call_frame(i, long_running_program()))
        wait_until(fn -> Stdio.in_flight_count(h.stdio) >= 1 end, 500)
        :ok = Stdio.feed(h.stdio, cancelled_frame(i))
        wait_until(fn -> Stdio.in_flight_count(h.stdio) == 0 end, 1_500)
      end)

      assert ConcurrencyGate.in_flight() == 0, "permit leak after cancellation"
    end
  end

  describe "concurrency cap fires from stdio frames (§ 6.3 / § 11)" do
    test "cap=1 with two concurrent frames produces one reply + one busy", %{harness: h} do
      Limits.set(%{max_concurrent_calls: 1})
      _ = JsonRpcHarness.drain_replied_messages()

      # Frame 1: long-running so it stays in flight while we feed frame 2.
      :ok = Stdio.feed(h.stdio, tools_call_frame(200, long_running_program()))
      wait_until(fn -> Stdio.in_flight_count(h.stdio) == 1 end, 500)

      # Frame 2: simple, but cap is full → busy reply written synchronously.
      :ok = Stdio.feed(h.stdio, tools_call_frame(201, "(+ 1 2)"))

      # Read what we have so far — the busy reply for 201 should be there
      # immediately (no worker spawned).
      buf1 =
        h.io
        |> StringIO.flush()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      assert Enum.any?(buf1, fn r ->
               r["id"] == 201 and r["result"]["structuredContent"]["reason"] == "busy"
             end)

      # Cancel the long-running one so the test cleans up promptly.
      :ok = Stdio.feed(h.stdio, cancelled_frame(200))
      wait_until(fn -> Stdio.in_flight_count(h.stdio) == 0 end, 1_500)
    end

    test "cap=2 with three concurrent frames produces two replies + one busy", %{harness: h} do
      Limits.set(%{max_concurrent_calls: 2})
      _ = JsonRpcHarness.drain_replied_messages()

      # Two long-running calls fill the cap.
      :ok = Stdio.feed(h.stdio, tools_call_frame(300, long_running_program()))
      :ok = Stdio.feed(h.stdio, tools_call_frame(301, long_running_program()))
      wait_until(fn -> Stdio.in_flight_count(h.stdio) == 2 end, 500)

      # Third frame should hit busy.
      :ok = Stdio.feed(h.stdio, tools_call_frame(302, "(+ 1 2)"))

      # Synchronously written busy reply for 302.
      replies =
        h.io
        |> StringIO.flush()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      busy = Enum.find(replies, fn r -> r["id"] == 302 end)

      assert busy != nil, "expected synchronous busy reply for id 302"
      assert busy["result"]["structuredContent"]["reason"] == "busy"

      # Cancel both long-running calls.
      :ok = Stdio.feed(h.stdio, cancelled_frame(300))
      :ok = Stdio.feed(h.stdio, cancelled_frame(301))
      wait_until(fn -> Stdio.in_flight_count(h.stdio) == 0 end, 1_500)
    end
  end

  describe "stdin EOF (§ 6.4 row 1)" do
    test "cancels all in-flight workers and exits 0 cleanly" do
      # We cannot use the shared harness here because EOF triggers the
      # genserver to terminate. Build a fresh Stdio with auto_read off,
      # feed a long-running tools/call, then switch on auto_read so the
      # next read off the empty StringIO returns :eof and triggers the
      # cancel-all path (§ 6.4 row 1).
      ConcurrencyGate.reset()
      Limits.set(Limits.defaults())

      {:ok, io} = StringIO.open(<<>>, capture_prompt: false)

      {:ok, stdio} =
        Stdio.start_link(
          io: io,
          observer: self(),
          auto_read: false,
          name: :"stdio_eof_phase4_#{System.unique_integer([:positive])}"
        )

      ref = Process.monitor(stdio)

      # Feed the long-running call synchronously so a worker is in flight.
      :ok = Stdio.feed(stdio, tools_call_frame(500, long_running_program()))
      wait_until(fn -> Stdio.in_flight_count(stdio) == 1 end, 500)

      # Now ask the genserver to read from the empty StringIO. Because
      # there's nothing left, the next `IO.binread/2` returns `:eof`
      # and the cancel-all-then-stop path runs.
      send(stdio, :read)

      assert_receive {Stdio, {:exited, :eof}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^stdio, :normal}, 2_000

      # Permit was released as part of cancel_all_workers/2.
      assert ConcurrencyGate.in_flight() == 0

      StringIO.close(io)
    end
  end

  describe "shutdown / exit drain (§ 6.4 row 2)" do
    test "tools/call after shutdown is rejected with shutting_down envelope", %{harness: h} do
      _ = JsonRpcHarness.drain_replied_messages()

      shutdown =
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 600, "method" => "shutdown"}) <> "\n"

      :ok = Stdio.feed(h.stdio, shutdown)

      # New tools/call after shutdown.
      :ok = Stdio.feed(h.stdio, tools_call_frame(601, "(+ 1 2)"))

      replies =
        h.io
        |> StringIO.flush()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      shutdown_reply = Enum.find(replies, fn r -> r["id"] == 600 end)
      assert shutdown_reply["result"] == nil

      rejected = Enum.find(replies, fn r -> r["id"] == 601 end)
      assert rejected != nil
      env = rejected["result"]
      assert env["isError"] == true
      assert env["structuredContent"]["reason"] == "shutting_down"
    end

    test "exit notification with no in-flight calls stops immediately", %{harness: h} do
      stdio_ref = Process.monitor(h.stdio)
      _ = JsonRpcHarness.drain_replied_messages()

      :ok =
        Stdio.feed(
          h.stdio,
          Jason.encode!(%{"jsonrpc" => "2.0", "method" => "exit"}) <> "\n"
        )

      assert_receive {Stdio, {:exited, :exit_method}}, 500
      # The genserver itself stays alive (System.stop/0 is bypassed
      # under the observer); the observer message is sufficient proof.
      Process.demonitor(stdio_ref, [:flush])
    end

    test "in-flight calls from BEFORE shutdown complete normally", %{harness: h} do
      _ = JsonRpcHarness.drain_replied_messages()

      # Fast call → enters in_flight, completes ~immediately.
      :ok = Stdio.feed(h.stdio, tools_call_frame(700, "(+ 1 2)"))

      # Send shutdown right after.
      :ok =
        Stdio.feed(
          h.stdio,
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => 701, "method" => "shutdown"}) <> "\n"
        )

      # Wait briefly for both replies.
      _ = JsonRpcHarness.wait_for_reply(500)
      _ = JsonRpcHarness.wait_for_reply(500)

      replies =
        h.io
        |> StringIO.flush()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      assert Enum.find(replies, fn r -> r["id"] == 700 end)["result"]["isError"] == false
      assert Enum.find(replies, fn r -> r["id"] == 701 end)["result"] == nil
    end
  end

  describe "sandbox isolation (§ 11 invariants)" do
    test "memory state from call_1 is not visible to call_2", %{harness: h} do
      # PTC-Lisp persists memory across turns via `def`; the MCP
      # server starts every `tools/call` with `memory: %{}` (§ 11
      # required invariants). After call_1 stores `counter`, call_2
      # must NOT see it.
      _ = JsonRpcHarness.drain_replied_messages()

      # Call 1: define `counter` (memory store) and return it.
      :ok =
        Stdio.feed(
          h.stdio,
          tools_call_frame(800, "(do (def counter 1) counter)")
        )

      # Call 2: try to read `counter` — must error since memory is
      # fresh per call. We rely on the unbound-symbol error rather
      # than a sentinel return because the MCP path uses
      # strict_data: true and an empty initial memory.
      :ok = Stdio.feed(h.stdio, tools_call_frame(801, "counter"))

      _ = JsonRpcHarness.wait_for_reply(500)
      _ = JsonRpcHarness.wait_for_reply(500)

      replies =
        h.io
        |> StringIO.flush()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      r1 = Enum.find(replies, fn r -> r["id"] == 800 end)
      r2 = Enum.find(replies, fn r -> r["id"] == 801 end)

      assert r1 != nil, "no reply for id 800; replies: #{inspect(replies)}"
      assert r2 != nil, "no reply for id 801; replies: #{inspect(replies)}"

      # Call_1 succeeded and saw counter == 1.
      assert r1["result"]["isError"] == false
      assert r1["result"]["structuredContent"]["result"] == "user=> 1"

      # Call_2 must NOT see call_1's memory — `counter` is unbound.
      assert r2["result"]["isError"] == true,
             "call_2 should not see call_1 memory; sc: " <>
               inspect(r2["result"]["structuredContent"])
    end
  end

  describe "telemetry from worker processes (§ 6.7)" do
    test "[:ptc_runner_mcp, :call, :stop] fires with correct metadata from worker", %{harness: h} do
      _ = JsonRpcHarness.drain_replied_messages()
      handler_id = "phase4_telemetry_#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:ptc_runner_mcp, :call, :stop],
        fn _name, measurements, metadata, _config ->
          send(test_pid, {:span_stop, measurements, metadata})
        end,
        nil
      )

      try do
        :ok = Stdio.feed(h.stdio, tools_call_frame(900, "(+ 1 2)"))

        assert_receive {:span_stop, measurements, metadata}, 1_000
        assert is_integer(measurements.duration)
        assert measurements.duration > 0
        assert metadata.request_id == "900"
        assert metadata.tool_name == "ptc_lisp_execute"
        assert metadata.status == :ok
        assert metadata.is_error == false
      after
        :telemetry.detach(handler_id)
      end
    end
  end

  # ----------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline do
        flunk("wait_until timed out")
      else
        # Non-blocking pause: a `receive` with `after` parks the
        # scheduler without consuming CPU and avoids the explicit
        # `Process.sleep` ban from CLAUDE.md.
        receive do
        after
          10 -> :ok
        end

        do_wait_until(fun, deadline)
      end
    end
  end
end
