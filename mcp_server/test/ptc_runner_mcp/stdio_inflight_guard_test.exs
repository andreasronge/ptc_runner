defmodule PtcRunnerMcp.StdioInflightGuardTest do
  @moduledoc """
  Coverage for `PtcRunnerMcp.Stdio`'s in-flight-id guard and the
  `PtcRunnerMcp.ConcurrencyGate` permit accounting that backs it.

  Companion to `PtcRunnerMcp.CancellationTest` — it reuses the same
  `JsonRpcHarness` + `WaitHelpers` plumbing and the Ackermann
  long-running program to keep a worker genuinely in flight while a
  second frame is dispatched.

  Branch under test: `Stdio.handle_async_call/4` rejects a `tools/call`
  whose JSON-RPC `id` is still in flight with a `-32600` Invalid
  Request error WITHOUT acquiring a second permit (codex review of
  0fe4c78). This protects against a permit + reply leak that an
  in-flight-id overwrite would otherwise cause.
  """
  use ExUnit.Case, async: false

  import PtcRunnerMcp.TestSupport.WaitHelpers

  alias PtcRunnerMcp.{ConcurrencyGate, Limits, Stdio}
  alias PtcRunnerMcp.Test.JsonRpcHarness

  setup do
    Limits.set(Limits.defaults())
    ConcurrencyGate.reset()

    {:ok, harness} = JsonRpcHarness.start()
    on_exit(fn -> JsonRpcHarness.stop(harness) end)
    {:ok, harness: harness}
  end

  # Ackermann(3, 8) reliably burns > 1s of CPU under the default heap,
  # so the worker stays in flight across the second `feed/2` call.
  # Same fixture as CancellationTest.
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
        "name" => "lisp_eval",
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

  defp drain_replies(io) do
    io
    |> StringIO.flush()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  describe "duplicate in-flight id (JSON-RPC § 4 / codex review of 0fe4c78)" do
    test "second tools/call with the same in-flight id returns -32600 and leaks no permit", %{
      harness: h
    } do
      _ = JsonRpcHarness.drain_replied_messages()

      # Frame 1: long-running call with id 42 — stays in flight.
      :ok = Stdio.feed(h.stdio, tools_call_frame(42, long_running_program()))
      wait_until(fn -> Stdio.in_flight_count(h.stdio) == 1 end, 1_000)

      # One permit is held by the in-flight worker.
      assert ConcurrencyGate.in_flight() == 1

      # Discard the first worker's notification, if any leaked early, and
      # clear the output buffer so we only read the duplicate's reply.
      _ = JsonRpcHarness.drain_replied_messages()
      _ = StringIO.flush(h.io)

      # Frame 2: SAME id 42 while the first is still running. Dispatched
      # synchronously inside `feed/2` (no worker is spawned), so the
      # -32600 reply is written before `feed/2` returns.
      :ok = Stdio.feed(h.stdio, tools_call_frame(42, "(+ 1 2)"))

      replies = drain_replies(h.io)
      dup = Enum.find(replies, fn r -> r["id"] == 42 end)

      assert dup != nil, "expected a reply for the duplicate id 42; got #{inspect(replies)}"
      assert dup["error"]["code"] == -32_600
      assert dup["error"]["message"] =~ "already in flight"
      # JSON-RPC error frames carry no result.
      refute Map.has_key?(dup, "result")

      # The guard rejected WITHOUT acquiring a second permit: still
      # exactly one in flight (the original worker), and the Stdio
      # in-flight table still has exactly one entry.
      assert ConcurrencyGate.in_flight() == 1
      assert Stdio.in_flight_count(h.stdio) == 1

      # Cancel the original so the test tears down promptly, and confirm
      # the single permit is released cleanly (no leak from the reject).
      :ok = Stdio.feed(h.stdio, cancelled_frame(42))
      wait_until(fn -> Stdio.in_flight_count(h.stdio) == 0 end, 1_500)
      assert ConcurrencyGate.in_flight() == 0
    end

    test "a duplicate id is rejected without evicting the in-flight original or leaking a permit",
         %{harness: h} do
      _ = JsonRpcHarness.drain_replied_messages()

      # Hold id 7 in flight with the long-running program so a duplicate
      # deterministically races against a live request.
      :ok = Stdio.feed(h.stdio, tools_call_frame(7, long_running_program()))
      wait_until(fn -> Stdio.in_flight_count(h.stdio) == 1 end, 1_000)

      _ = JsonRpcHarness.drain_replied_messages()
      _ = StringIO.flush(h.io)

      # Duplicate id 7 -> rejected -32600, and the original is left untouched:
      # still exactly one in-flight request and one permit, with NO spurious
      # result reply for id 7 (a regression that discarded the original would
      # drop the in-flight count or emit an extra reply here).
      :ok = Stdio.feed(h.stdio, tools_call_frame(7, "(+ 1 2)"))
      replies = drain_replies(h.io)
      assert Enum.find(replies, &(&1["id"] == 7))["error"]["code"] == -32_600
      refute Enum.any?(replies, &(&1["id"] == 7 and Map.has_key?(&1, "result")))
      assert Stdio.in_flight_count(h.stdio) == 1
      assert ConcurrencyGate.in_flight() == 1

      # Cancel the original; the gate returns to 0 (permit released, not leaked).
      :ok = Stdio.feed(h.stdio, cancelled_frame(7))
      wait_until(fn -> Stdio.in_flight_count(h.stdio) == 0 end, 1_500)
      assert ConcurrencyGate.in_flight() == 0

      # A brand-new short call with a fresh id must now succeed end to
      # end — proving the duplicate rejection released nothing it
      # shouldn't have and consumed nothing it shouldn't have.
      _ = JsonRpcHarness.drain_replied_messages()
      _ = StringIO.flush(h.io)

      :ok = Stdio.feed(h.stdio, tools_call_frame(8, "(+ 1 2)"))
      _ = JsonRpcHarness.wait_for_reply(1_000)
      wait_until(fn -> Stdio.in_flight_count(h.stdio) == 0 end, 1_500)

      fresh = Enum.find(drain_replies(h.io), &(&1["id"] == 8))
      assert fresh != nil, "expected a reply for the fresh id 8"
      assert fresh["result"]["isError"] == false
      assert fresh["result"]["structuredContent"]["result"] == "user=> 3"
      assert ConcurrencyGate.in_flight() == 0
    end
  end

  describe "ConcurrencyGate permit accounting (semaphore invariants)" do
    test "release after a duplicate-id reject keeps the gate exactly balanced", %{harness: h} do
      _ = JsonRpcHarness.drain_replied_messages()

      :ok = Stdio.feed(h.stdio, tools_call_frame(50, long_running_program()))
      wait_until(fn -> Stdio.in_flight_count(h.stdio) == 1 end, 1_000)

      # Three duplicate frames for id 50, all in-flight rejects. None may
      # acquire a permit; the gate stays pinned at 1.
      Enum.each(1..3, fn _ ->
        _ = StringIO.flush(h.io)
        :ok = Stdio.feed(h.stdio, tools_call_frame(50, "(+ 1 2)"))
        dup = Enum.find(drain_replies(h.io), &(&1["id"] == 50))
        assert dup["error"]["code"] == -32_600
        assert ConcurrencyGate.in_flight() == 1
      end)

      :ok = Stdio.feed(h.stdio, cancelled_frame(50))
      wait_until(fn -> Stdio.in_flight_count(h.stdio) == 0 end, 1_500)
      assert ConcurrencyGate.in_flight() == 0
    end

    test "release is clamped at 0 and never goes negative on over-release" do
      # Directly exercise ConcurrencyGate's defensive clamp (release/0
      # restores to 0 rather than going negative). This is the
      # permit-leak-guard counterpart used by Stdio's DOWN/cancel paths.
      ConcurrencyGate.reset()
      assert ConcurrencyGate.in_flight() == 0

      # Over-release with no outstanding permit must stay at 0.
      :ok = ConcurrencyGate.release()
      assert ConcurrencyGate.in_flight() == 0

      # A normal acquire/release round-trips back to 0.
      assert ConcurrencyGate.try_acquire(1) == :ok
      assert ConcurrencyGate.in_flight() == 1
      assert ConcurrencyGate.try_acquire(1) == :full
      assert ConcurrencyGate.in_flight() == 1
      :ok = ConcurrencyGate.release()
      assert ConcurrencyGate.in_flight() == 0

      # And a double over-release still clamps to 0.
      :ok = ConcurrencyGate.release()
      :ok = ConcurrencyGate.release()
      assert ConcurrencyGate.in_flight() == 0
    end
  end
end
