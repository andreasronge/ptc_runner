defmodule PtcRunnerMcp.CancellationPhase1aTest do
  @moduledoc """
  Phase 1a tests for `notifications/cancelled` against in-flight
  `(tool/mcp-call ...)` invocations.

  Per `Plans/ptc-runner-mcp-aggregator.md` §6.4 last paragraphs +
  §12.2:

    * Cancellation kills the worker before its mailbox is drained;
      no envelope is sent (matches MCP semantics).
    * No `upstream_calls` entry is recorded for a cancelled request.
    * The unique `collector_ref` check (`UpstreamCalls.drain/1`)
      ensures any late-arriving messages from a cancelled request
      cannot pollute a subsequent (fresh-ref) request's drain.
    * For `Upstream.Fake`, "detach-equivalent" semantics are
      sufficient: the spawned task running the fake `call/4` may
      complete after the worker dies — the task's late reply is
      sent to a now-dead pid and silently dropped. **Phase 1a does
      NOT require killing the fake function itself** (§12.2).

  The integration test goes through the full Stdio
  `notifications/cancelled` path (`PtcRunnerMcp.CancellationTest`).
  Here we focus on the Phase 1a-specific invariants — the unique-ref
  isolation and the drain-skipped-on-crash semantics — at the unit
  level so failures are diagnosable in isolation.
  """
  use ExUnit.Case, async: false

  alias PtcRunnerMcp.UpstreamCalls

  describe "unique collector_ref isolates requests" do
    test "drain/1 ignores messages tagged with a different ref" do
      ref_a = make_ref()
      ref_b = make_ref()

      ctx_a = %{collector_pid: self(), collector_ref: ref_a}
      ctx_b = %{collector_pid: self(), collector_ref: ref_b}

      :ok = UpstreamCalls.record(ctx_a, UpstreamCalls.success_entry("a", "x", 1))
      :ok = UpstreamCalls.record(ctx_b, UpstreamCalls.success_entry("b", "y", 2))
      :ok = UpstreamCalls.record(ctx_a, UpstreamCalls.success_entry("a", "z", 3))

      # Drain ref_a only: the ref_b message is left in the mailbox.
      assert [%{"server" => "a", "tool" => "x"}, %{"server" => "a", "tool" => "z"}] =
               UpstreamCalls.drain(ref_a)

      # Now ref_b's message is the only one left.
      assert [%{"server" => "b", "tool" => "y"}] = UpstreamCalls.drain(ref_b)

      assert UpstreamCalls.drain(ref_a) == []
      assert UpstreamCalls.drain(ref_b) == []
    end
  end

  describe "drain only happens on normal completion (§6.4)" do
    test "a worker process killed before draining records nothing" do
      # Spawn a "worker" that records 2 entries, then exits abnormally
      # before draining. The drain helper is only called on normal
      # completion / caught error — `Process.exit(:kill)` skips it.
      ref = make_ref()
      parent = self()

      worker =
        spawn(fn ->
          ctx = %{collector_pid: parent, collector_ref: ref}
          :ok = UpstreamCalls.record(ctx, UpstreamCalls.success_entry("a", "x", 1))
          :ok = UpstreamCalls.record(ctx, UpstreamCalls.success_entry("a", "y", 2))
          # Simulate a forced kill — the worker NEVER reaches the
          # drain step.
          Process.exit(self(), :kill)
        end)

      worker_ref = Process.monitor(worker)
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}, 1_000

      # The parent (collector) DOES still have those messages in
      # its mailbox — the spec invariant is "no envelope is sent
      # for a cancelled request, so the absence of any
      # `upstream_calls` reporting is correct" (§6.4 last
      # paragraph). In production this is realized by the worker
      # dying before it constructs / sends the envelope; the
      # mailbox messages here are inert because there is no
      # subsequent drain step that would surface them.
      #
      # Subsequent fresh requests use a NEW unique ref — proven
      # in the test below — so these stale messages cannot leak.
      assert {:messages, msgs} = Process.info(self(), :messages)

      stale =
        Enum.filter(msgs, fn
          {:upstream_call_recorded, ^ref, _} -> true
          _ -> false
        end)

      assert length(stale) == 2

      # Clean up to avoid polluting the next test's mailbox.
      Enum.each(stale, fn _ ->
        receive do
          {:upstream_call_recorded, ^ref, _} -> :ok
        after
          0 -> :ok
        end
      end)
    end

    test "a fresh request's drain is unaffected by an abandoned ref's messages" do
      # Simulate the leak scenario: messages tagged with `old_ref`
      # are sitting in the mailbox from a cancelled request. A new
      # request uses `new_ref`. The new request's drain MUST NOT
      # pick up the old messages.
      old_ref = make_ref()
      new_ref = make_ref()

      send(self(), {:upstream_call_recorded, old_ref, %{"abandoned" => true}})

      ctx_new = %{collector_pid: self(), collector_ref: new_ref}
      :ok = UpstreamCalls.record(ctx_new, UpstreamCalls.success_entry("a", "x", 1))

      # New request's drain returns exactly its own entry; the
      # abandoned message is left untouched.
      assert [%{"server" => "a"}] = UpstreamCalls.drain(new_ref)

      # The abandoned message is still there, ready to be ignored
      # by any future drain that doesn't match its ref.
      assert_received {:upstream_call_recorded, ^old_ref, _}
    end
  end
end
